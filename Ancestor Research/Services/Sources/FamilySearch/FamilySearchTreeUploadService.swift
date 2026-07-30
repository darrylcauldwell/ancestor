import Foundation
import os
import AncestorKit

// FamilySearch User Tree upload orchestrator (WL4 —
// FAMILYSEARCH_TREES_WRITE_SPEC §2/§6). Executes the documented call sequence
// (group → tree → context → persons → relationships → sources → finalize →
// restore GLOBAL) over a WL2 plan, with D7 resume: every created entity is
// recorded in the v52 tables BEFORE the next call, and a re-run skips
// everything already linked. Per-entity failures are captured and the run
// continues (fail-soft); auth loss and throttle exhaustion abort with state
// saved. Finalize (the ONE-WAY hidden flip) is gated on a clean person +
// relationship upload.

nonisolated struct FSUploadFailure: Sendable, Equatable {
    let stage: String       // "person" | "couple" | "childAndParents" | "sourceDescription" | "sourceReference" | "finalize"
    let localKey: String
    let message: String
}

nonisolated struct FSUploadSummary: Sendable {
    let treeID: String
    let treeName: String
    let personsCreated: Int
    let personsSkipped: Int         // already linked — resume no-ops
    let relationshipsCreated: Int
    let relationshipsSkipped: Int
    let sourceDescriptionsCreated: Int
    let sourceReferencesAttached: Int
    let omitted: [String: String]   // profileID → exclusion reason (living, stub…)
    let failures: [FSUploadFailure]
    let finalized: Bool
    /// Human explanation when `finalized == false`.
    let finalizeNote: String?
}

actor FamilySearchTreeUploadService {
    private let client: FamilySearchClient
    private let database: ProjectDatabase
    private let environment: FamilySearchEnvironment
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FSTreeUpload")

    init(client: FamilySearchClient, database: ProjectDatabase, environment: FamilySearchEnvironment) {
        self.client = client
        self.database = database
        self.environment = environment
    }

    /// Run (or resume) an upload. `runID` pins the bookkeeping row; passing
    /// the id of an interrupted run continues it against the same FS tree.
    func upload(
        plan: FSUploadPlan,
        config: FamilySearchTreeEncoder.Config,
        runID: String,
        startingProfileID: String?,
        isPrivate: Bool,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> FSUploadSummary {
        var run = try database.latestFamilySearchUploadRun(environment: environment.rawValue)
            .flatMap { $0.id == runID ? $0 : nil }
            ?? FSTreeUploadRecord(
                id: runID, environment: environment.rawValue, fsGroupID: nil, fsTreeID: nil,
                treeName: config.treeName, treeDescription: config.treeDescription,
                startingProfileID: startingProfileID, isPrivate: nil, phase: "created",
                startedAt: Date(), finalizedAt: nil,
                personsUploaded: 0, relationshipsUploaded: 0, sourcesUploaded: 0)
        var failures: [FSUploadFailure] = []

        // -- 1+2. Group, then tree (skipped on resume when already minted).
        if run.fsGroupID == nil {
            progress("Creating access group…")
            run.fsGroupID = try await client.createGroup(body: plan.groupBody)
            try database.saveFamilySearchUploadRun(run)
        }
        if run.fsTreeID == nil {
            progress("Creating tree “\(config.treeName)”…")
            let body = try FamilySearchTreeEncoder.treeBody(groupID: run.fsGroupID!, config: config)
            run.fsTreeID = try await client.createTree(body: body)
            run.phase = "uploading"
            try database.saveFamilySearchUploadRun(run)
        }
        let treeID = run.fsTreeID!

        do {
            // -- 3+4. Persons, inside the user-tree context. The context is a
            // session setting with undocumented lifetime — re-asserted before
            // every batch, never assumed.
            var pids = try database.familySearchPersonLinks(fsTreeID: treeID)
            let personsToCreate = plan.persons.filter { pids[$0.profileID] == nil }
            let personsSkipped = plan.persons.count - personsToCreate.count
            var personsCreated = 0

            try await client.setCurrentTree(treeID: treeID)
            for (index, person) in personsToCreate.enumerated() {
                try Task.checkCancellation()
                progress("Person \(personsSkipped + index + 1)/\(plan.persons.count): \(person.displayName)")
                do {
                    let pid = try await client.createPerson(body: person.body)
                    try database.recordFamilySearchPersonLink(
                        profileID: person.profileID, fsTreeID: treeID, fsPID: pid)
                    pids[person.profileID] = pid
                    personsCreated += 1
                    if personsCreated % 25 == 0 {
                        run.personsUploaded = pids.count
                        try database.saveFamilySearchUploadRun(run)
                    }
                } catch let FamilySearchClientError.unexpectedStatus(status, body) {
                    failures.append(.init(stage: "person", localKey: person.profileID,
                                          message: "HTTP \(status): \(body)"))
                }
            }
            run.personsUploaded = pids.count
            try database.saveFamilySearchUploadRun(run)

            // -- 5. Relationships (couples first — the child-and-parents
            // pairing references couple membership only locally, but keeping
            // the documented order aids diagnosis).
            var relationshipsCreated = 0
            var relationshipsSkipped = 0
            var coupleIDs = try database.familySearchEntityLinks(fsTreeID: treeID, kind: "couple")
            try await client.setCurrentTree(treeID: treeID)

            for couple in plan.couples {
                try Task.checkCancellation()
                if coupleIDs[couple.localKey] != nil { relationshipsSkipped += 1; continue }
                guard let p1 = pids[couple.person1ProfileID], let p2 = pids[couple.person2ProfileID] else {
                    failures.append(.init(stage: "couple", localKey: couple.localKey,
                                          message: "endpoint person was not created"))
                    continue
                }
                do {
                    let body = try FamilySearchTreeEncoder.coupleBody(
                        couple, person1PID: p1, person2PID: p2, environment: environment)
                    let rid = try await client.createRelationship(body: body)
                    try database.recordFamilySearchEntityLink(
                        localKey: couple.localKey, fsTreeID: treeID, kind: "couple", fsID: rid)
                    coupleIDs[couple.localKey] = rid
                    relationshipsCreated += 1
                } catch let FamilySearchClientError.unexpectedStatus(status, body) {
                    failures.append(.init(stage: "couple", localKey: couple.localKey,
                                          message: "HTTP \(status): \(body)"))
                }
            }

            let capIDs = try database.familySearchEntityLinks(fsTreeID: treeID, kind: "childAndParents")
            for cap in plan.childAndParents {
                try Task.checkCancellation()
                if capIDs[cap.localKey] != nil { relationshipsSkipped += 1; continue }
                guard let childPID = pids[cap.childProfileID] else {
                    failures.append(.init(stage: "childAndParents", localKey: cap.localKey,
                                          message: "child person was not created"))
                    continue
                }
                let p1 = cap.parent1ProfileID.flatMap { pids[$0] }
                let p2 = cap.parent2ProfileID.flatMap { pids[$0] }
                if (cap.parent1ProfileID != nil && p1 == nil) || (cap.parent2ProfileID != nil && p2 == nil) {
                    failures.append(.init(stage: "childAndParents", localKey: cap.localKey,
                                          message: "parent person was not created"))
                    continue
                }
                do {
                    let body = try FamilySearchTreeEncoder.childAndParentsBody(
                        cap, childPID: childPID, parent1PID: p1, parent2PID: p2, environment: environment)
                    let rid = try await client.createRelationship(body: body)
                    try database.recordFamilySearchEntityLink(
                        localKey: cap.localKey, fsTreeID: treeID, kind: "childAndParents", fsID: rid)
                    relationshipsCreated += 1
                } catch let FamilySearchClientError.unexpectedStatus(status, body) {
                    failures.append(.init(stage: "childAndParents", localKey: cap.localKey,
                                          message: "HTTP \(status): \(body)"))
                }
            }
            run.relationshipsUploaded = relationshipsCreated + relationshipsSkipped
            try database.saveFamilySearchUploadRun(run)

            // -- 6. Source descriptions (tree-independent), then references.
            var descriptionIDs = try database.familySearchEntityLinks(fsTreeID: treeID, kind: "sourceDescription")
            var sourceDescriptionsCreated = 0
            for description in plan.sourceDescriptions {
                try Task.checkCancellation()
                guard descriptionIDs[description.key] == nil else { continue }
                do {
                    let id = try await client.createSourceDescription(body: description.body)
                    try database.recordFamilySearchEntityLink(
                        localKey: description.key, fsTreeID: treeID, kind: "sourceDescription", fsID: id)
                    descriptionIDs[description.key] = id
                    sourceDescriptionsCreated += 1
                } catch let FamilySearchClientError.unexpectedStatus(status, body) {
                    failures.append(.init(stage: "sourceDescription", localKey: description.key,
                                          message: "HTTP \(status): \(body)"))
                }
            }

            func descriptionURI(_ key: String) -> String? {
                descriptionIDs[key].map { "https://\(environment.apiHost)/platform/sources/descriptions/\($0)" }
            }

            var sourceReferencesAttached = 0
            let attachedRefs = try database.familySearchEntityLinks(fsTreeID: treeID, kind: "sourceReference")
            try await client.setCurrentTree(treeID: treeID)

            for ref in plan.personSourceRefs {
                try Task.checkCancellation()
                let localKey = "\(ref.profileID)|src"
                guard attachedRefs[localKey] == nil, let pid = pids[ref.profileID] else { continue }
                let uris = ref.citationKeys.compactMap(descriptionURI)
                guard !uris.isEmpty else { continue }
                do {
                    let body = try FamilySearchTreeEncoder.personSourcesBody(descriptionURIs: uris)
                    _ = try await client.attachPersonSources(pid: pid, body: body)
                    try database.recordFamilySearchEntityLink(
                        localKey: localKey, fsTreeID: treeID, kind: "sourceReference", fsID: "attached")
                    sourceReferencesAttached += 1
                } catch let FamilySearchClientError.unexpectedStatus(status, body) {
                    failures.append(.init(stage: "sourceReference", localKey: localKey,
                                          message: "HTTP \(status): \(body)"))
                }
            }
            for couple in plan.couples where !couple.citationKeys.isEmpty {
                try Task.checkCancellation()
                let localKey = "\(couple.localKey)|src"
                guard attachedRefs[localKey] == nil, let rid = coupleIDs[couple.localKey] else { continue }
                let uris = couple.citationKeys.compactMap(descriptionURI)
                guard !uris.isEmpty else { continue }
                do {
                    let body = try FamilySearchTreeEncoder.coupleSourcesBody(relationshipID: rid, descriptionURIs: uris)
                    _ = try await client.attachCoupleSources(relationshipID: rid, body: body)
                    try database.recordFamilySearchEntityLink(
                        localKey: localKey, fsTreeID: treeID, kind: "sourceReference", fsID: "attached")
                    sourceReferencesAttached += 1
                } catch let FamilySearchClientError.unexpectedStatus(status, body) {
                    failures.append(.init(stage: "sourceReference", localKey: localKey,
                                          message: "HTTP \(status): \(body)"))
                }
            }
            run.sourcesUploaded = descriptionIDs.count
            try database.saveFamilySearchUploadRun(run)

            // -- 7. Finalize — gated: the hidden flip is ONE-WAY, so it only
            // happens on a clean person + relationship upload.
            let blocking = failures.filter { $0.stage != "sourceDescription" && $0.stage != "sourceReference" }
            var finalized = false
            var finalizeNote: String?
            let startingPID = (startingProfileID ?? plan.persons.first?.profileID).flatMap { pids[$0] }
            if !blocking.isEmpty {
                finalizeNote = "\(blocking.count) person/relationship failure(s) — tree left hidden; fix and re-run to finalize."
            } else if let startingPID {
                do {
                    let body = try FamilySearchTreeEncoder.treeFinalizeBody(
                        startingPersonPID: startingPID, isPrivate: isPrivate)
                    do {
                        try await client.updateTree(treeID: treeID, body: body)
                    } catch let FamilySearchClientError.unexpectedStatus(status, _) where status == 400 || status == 415 {
                        // The docs are inconsistent about this endpoint's media
                        // type (gedcomx-v1 in the example, fs-v1 on create) —
                        // fall back once before surfacing.
                        try await client.updateTree(treeID: treeID, body: body, contentType: .fsV1)
                    }
                    finalized = true
                    run.phase = "finalized"
                    run.isPrivate = isPrivate
                    run.finalizedAt = Date()
                    progress("Tree finalized — visible on FamilySearch\(isPrivate ? " (private)" : "")")
                } catch let FamilySearchClientError.unexpectedStatus(status, body) {
                    failures.append(.init(stage: "finalize", localKey: treeID, message: "HTTP \(status): \(body)"))
                    finalizeNote = "Finalize rejected (HTTP \(status)) — tree uploaded but still hidden."
                }
            } else {
                finalizeNote = "No starting person available — tree uploaded but still hidden."
            }
            try database.saveFamilySearchUploadRun(run)

            // -- 8. Always restore the shared-tree context so read paths
            // (tree search, hints) are unaffected by the upload session.
            try? await client.setCurrentTree(treeID: "GLOBAL")

            return FSUploadSummary(
                treeID: treeID, treeName: config.treeName,
                personsCreated: personsCreated, personsSkipped: personsSkipped,
                relationshipsCreated: relationshipsCreated, relationshipsSkipped: relationshipsSkipped,
                sourceDescriptionsCreated: sourceDescriptionsCreated,
                sourceReferencesAttached: sourceReferencesAttached,
                omitted: plan.omitted, failures: failures,
                finalized: finalized, finalizeNote: finalizeNote)
        } catch {
            // Auth loss / throttle exhaustion / cancellation: state is already
            // saved incrementally — mark the run resumable and restore context.
            run.phase = "uploading"
            try? database.saveFamilySearchUploadRun(run)
            try? await client.setCurrentTree(treeID: "GLOBAL")
            logger.error("FS upload interrupted: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
