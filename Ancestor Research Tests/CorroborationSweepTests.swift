import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// #CPC-Change2 acceptance tests (`AncestorApp/CROSS_PROFILE_CORROBORATION_SPEC.md`
/// Change 2): the CorroborationSweep end-to-end on the demonstrator fixture —
/// Mary Ellen Thompson × William Holmes, FreeBMD Dec 1915 Bakewell 7b/2130a,
/// William d. 1919 — plus rejection memory, dispute refusal, edge-conflict
/// skip, withdrawal, the cross-edge key ledger, and the accept routing.
struct CorroborationSweepTests {

    // MARK: - Criterion 1: end-to-end emission, idempotent

    @Test func demonstratorEmitsTwoPendingFactsOnceUnderDeterministicOwner() throws {
        let db = try makeDemonstratorDB()
        let snapshot = try db.buildSnapshot()

        let report = try CorroborationSweep.run(db: db, snapshot: snapshot)
        #expect(report.findingsEmitted == 2, "marriageDate + marriageLocation")

        // Owner rule: lexicographically-first profile id.
        let ownerFacts = try db.loadPendingFacts(profileID: "@MARY@")
        let otherFacts = try db.loadPendingFacts(profileID: "@WILLIAM@")
        #expect(ownerFacts.count == 2)
        #expect(otherFacts.isEmpty)
        let fields = Set(ownerFacts.compactMap { $0["fact_kind"] as? String })
        #expect(fields == ["marriageDate", "marriageLocation"])
        let statuses = Set(ownerFacts.compactMap { $0["verification_status"] as? String })
        #expect(statuses == ["verified"], "derives from already-scored evidence — pre-verified")
        // The payload rides sources_json and decodes.
        let payloads = ownerFacts.compactMap { CorroborationPayload.decode($0["sources_json"] as? String) }
        #expect(payloads.count == 2)
        #expect(payloads.allSatisfy { $0.tier == "reciprocal" && $0.anchorKind == "weak" })

        // Re-run: idempotent, zero new rows.
        let second = try CorroborationSweep.run(db: db, snapshot: snapshot)
        #expect(second.findingsEmitted == 2, "same deterministic ids re-claimed")
        #expect(try db.loadPendingFacts(profileID: "@MARY@").count == 2)
    }

    // MARK: - Criterion 1 (render): processor shows the card without damage

    @MainActor
    @Test func corroborationFactsRenderReadyForReviewWithoutRescoring() async throws {
        let db = try makeDemonstratorDB()
        let snapshot = try db.buildSnapshot()
        _ = try CorroborationSweep.run(db: db, snapshot: snapshot)

        let processor = PendingFactsProcessor(db: db, snapshot: snapshot, sourceInfoMap: [:])
        let findings = await processor.process(profileID: "@MARY@")
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.status == .readyForReview },
                "the exemption must keep the tuple-stripped re-score and the live fetch out of the path")
        #expect(findings.allSatisfy { $0.scorerVerdict == nil })
        #expect(findings.allSatisfy { $0.finding.payloadJSON != nil },
                "the routing payload must survive the processor round-trip")
    }

    // MARK: - Criterion 2: accept writes the edge, resolves both leads, later sweep skips

    @Test func acceptRoutesToCorrectEdgeResolvesLeadsAndSuppressesResweep() throws {
        let db = try makeDemonstratorDB()
        // A second marriage of William (multi-spouse routing check): the
        // accept must write the Mary edge, not this one.
        _ = try db.addProfile(profile("@OTHERWIFE@", first: "Jane", last: "Clark"), source: .gedcom)
        _ = try db.addRelationship(spouseEdge("@WILLIAM@", "@OTHERWIFE@"))
        let snapshot = try db.buildSnapshot()

        _ = try CorroborationSweep.run(db: db, snapshot: snapshot)
        let facts = try db.loadPendingFacts(profileID: "@MARY@")
        let dateFact = try #require(facts.first { ($0["fact_kind"] as? String) == "marriageDate" })
        let payloadJSON = dateFact["sources_json"] as? String

        let applied = try db.applyCorroborationFact(field: "marriageDate", payloadJSON: payloadJSON)
        #expect(applied)

        let after = try db.buildSnapshot()
        let maryEdge = try #require(after.relationships.first {
            $0.type == .spouse && [$0.from, $0.to].contains("@MARY@")
        })
        #expect(maryEdge.marriageDate?.original == "registered Dec quarter 1915")
        #expect(maryEdge.marriageDate?.earliest == 1915)
        #expect(maryEdge.marriageLocation == "BAKEWELL")
        let otherEdge = try #require(after.relationships.first {
            $0.type == .spouse && [$0.from, $0.to].contains("@OTHERWIFE@")
        })
        #expect(otherEdge.marriageDate == nil, "payload routing must not leak onto another edge")

        // Both sides' lead rows resolved (.promoted/.merged).
        for (profileID) in ["@MARY@", "@WILLIAM@"] {
            let lead = try #require(try db.loadLeads(profileID: profileID).first)
            #expect(lead.status == .promoted)
            #expect(lead.resolution == .merged)
        }

        // A later sweep sees the populated edge: nothing to gain, no re-emission.
        let resweep = try CorroborationSweep.run(db: db, snapshot: after)
        #expect(resweep.findingsEmitted == 0)
        #expect(resweep.skippedEdgePopulated == 1)
    }

    // MARK: - Criterion 3: rejection memory

    @Test func rejectedFactIsNeverReEmitted() throws {
        let db = try makeDemonstratorDB()
        let snapshot = try db.buildSnapshot()
        _ = try CorroborationSweep.run(db: db, snapshot: snapshot)

        for fact in try db.loadPendingFacts(profileID: "@MARY@") {
            try db.updatePendingFactStatus(id: fact["id"] as? String ?? "", status: "rejected")
        }
        #expect(try db.loadPendingFacts(profileID: "@MARY@").isEmpty)

        _ = try CorroborationSweep.run(db: db, snapshot: snapshot)
        #expect(try db.loadPendingFacts(profileID: "@MARY@").isEmpty,
                "INSERT OR IGNORE on the deterministic id must not resurrect a rejected fact")
    }

    // MARK: - Criteria 4-5: dismissed lead / discarded evidence exclusions

    @Test func dismissedLeadOnEitherSidePreventsEmission() throws {
        let db = try makeDemonstratorDB()
        let lead = try #require(try db.loadLeads(profileID: "@WILLIAM@").first)
        try db.upsertLead(Lead(
            id: lead.id, profileID: lead.profileID, name: lead.name,
            surname: lead.surname, givenName: lead.givenName,
            birthYear: lead.birthYear, deathYear: lead.deathYear,
            relationship: lead.relationship, source: lead.source,
            status: .dismissed, evidence: lead.evidence, createdAt: lead.createdAt,
            resolvedAt: Date(), resolution: .dismissed
        ))
        let report = try CorroborationSweep.run(db: db, snapshot: try db.buildSnapshot())
        #expect(report.findingsEmitted == 0, "a dismissed lead is rejection memory")
    }

    @Test func discardedEvidenceOnEitherSidePreventsEmission() throws {
        let db = try makeDemonstratorDB()
        try db.updateEvidenceUserStatus(
            evidenceID: EvidenceRecord.compositeID(profileID: "@WILLIAM@", sourceRecordID: "william-2130a"),
            status: .discarded
        )
        let report = try CorroborationSweep.run(db: db, snapshot: try db.buildSnapshot())
        #expect(report.findingsEmitted == 0)
    }

    // MARK: - Criterion 6: open dispute refusal

    @Test func openSpouseIdentityDisputeRefusesDetection() throws {
        let db = try makeDemonstratorDB()
        let conflict = DetectedConflict(
            kind: .spouseIdentity, profileID: "@WILLIAM@", field: "spouse",
            reason: .valueMismatch, severity: .conflict,
            competingSources: [
                FieldSource(origin: SourceOrigin(identifier: "tree"), raw: "Thompson", addedAt: Date()),
                FieldSource(origin: SourceOrigin(identifier: "freebmd"), raw: "Baker", addedAt: Date()),
            ],
            evidenceJSON: nil,
            reasoning: "fixture: unresolved spouse identity",
            detectedBy: .consistencySweep
        )
        _ = try db.upsertDispute(profileID: "@WILLIAM@", conflict: conflict,
                                 adjudication: DisputeResolver.adjudicate(conflict))
        let report = try CorroborationSweep.run(db: db, snapshot: try db.buildSnapshot())
        #expect(report.findingsEmitted == 0, "detection never argues with an open dispute")
    }

    // MARK: - Criterion 7: conflicting edge date skips, no dispute minted

    @Test func conflictingEdgeDateSkipsWithoutEmissionOrDispute() throws {
        let db = try makeDemonstratorDB(edgeMarriageDate: GenealogicalDate(parsing: "1925"))
        let report = try CorroborationSweep.run(db: db, snapshot: try db.buildSnapshot())
        #expect(report.findingsEmitted == 0)
        #expect(report.skippedEdgeConflict == 1)
        #expect(try db.openDisputes(profileID: "@MARY@").isEmpty)
        #expect(try db.openDisputes(profileID: "@WILLIAM@").isEmpty,
                "the conflict layer owns disputes; the sweep never mints one")
    }

    // MARK: - Criterion 11: withdrawal when justification lapses

    @Test func withdrawsPendingFactWhenPartnerEvidenceIsDiscarded() throws {
        let db = try makeDemonstratorDB()
        let snapshot = try db.buildSnapshot()
        _ = try CorroborationSweep.run(db: db, snapshot: snapshot)
        #expect(try db.loadPendingFacts(profileID: "@MARY@").count == 2)

        try db.updateEvidenceUserStatus(
            evidenceID: EvidenceRecord.compositeID(profileID: "@WILLIAM@", sourceRecordID: "william-2130a"),
            status: .discarded
        )
        let report = try CorroborationSweep.run(db: db, snapshot: snapshot)
        #expect(report.withdrawnStale == 2)
        #expect(try db.loadPendingFacts(profileID: "@MARY@").isEmpty,
                "a fact whose justification lapsed must not sit in review")
    }

    // MARK: - Criterion 10: cross-edge key ledger

    @Test func keyClaimedByTwoEdgesRefusesBoth() throws {
        let db = try makeDemonstratorDB()
        // Duplicate-couple debris: a second pair holding the SAME reference key.
        _ = try db.addProfile(profile("@MARY2@", first: "Mary Ellen", last: "Thompson"), source: .gedcom)
        _ = try db.addProfile(profile("@WILLIAM2@", first: "William", last: "Holmes", death: "1919"), source: .gedcom)
        _ = try db.addRelationship(spouseEdge("@MARY2@", "@WILLIAM2@"))
        try seedMarriageEvidence(db, profileID: "@MARY2@", recordID: "mary2-2130a",
                                 surname: "THOMPSON", givenName: "MARY ELLEN", spouseName: "Holmes")
        try seedMarriageEvidence(db, profileID: "@WILLIAM2@", recordID: "william2-2130a",
                                 surname: "HOLMES", givenName: "WILLIAM", spouseName: "Thompson")

        let report = try CorroborationSweep.run(db: db, snapshot: try db.buildSnapshot())
        #expect(report.findingsEmitted == 0, "one key, two edges — refuse all claimants")
        #expect(report.refusedSharedKeyClaims == 2)
    }

    // MARK: - Scoped trigger

    @Test func scopedRunOnlyTouchesEdgesOfTheGivenProfile() throws {
        let db = try makeDemonstratorDB()
        let snapshot = try db.buildSnapshot()
        let scopedElsewhere = try CorroborationSweep.run(
            db: db, snapshot: snapshot, limitToProfileID: "@NOBODY@")
        #expect(scopedElsewhere.edgesScanned == 0)
        #expect(scopedElsewhere.findingsEmitted == 0)

        let scopedHere = try CorroborationSweep.run(
            db: db, snapshot: snapshot, limitToProfileID: "@WILLIAM@")
        #expect(scopedHere.findingsEmitted == 2, "post-persist trigger sees the pair")
    }

    // MARK: - Fixtures

    private func makeDemonstratorDB(
        edgeMarriageDate: GenealogicalDate? = nil
    ) throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        _ = try db.addProfile(profile("@MARY@", first: "Mary Ellen", last: "Thompson"), source: .gedcom)
        _ = try db.addProfile(profile("@WILLIAM@", first: "William", last: "Holmes", death: "1919"), source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "@MARY@", to: "@WILLIAM@", type: .spouse, role: nil,
            subtype: .biological, marriageDate: edgeMarriageDate,
            marriageLocation: nil, divorceDate: nil))
        try seedMarriageEvidence(db, profileID: "@MARY@", recordID: "mary-2130a",
                                 surname: "THOMPSON", givenName: "MARY ELLEN", spouseName: "Holmes")
        try seedMarriageEvidence(db, profileID: "@WILLIAM@", recordID: "william-2130a",
                                 surname: "HOLMES", givenName: "WILLIAM", spouseName: "Thompson")
        return db
    }

    private func profile(_ id: String, first: String?, last: String?,
                         birth: String? = nil, death: String? = nil) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: $0) }, birthLocation: nil,
            deathDate: death.map { GenealogicalDate(parsing: $0) }, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func spouseEdge(_ from: String, _ to: String) -> Relationship {
        Relationship(id: UUID(), from: from, to: to, type: .spouse, role: nil,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil,
                     divorceDate: nil)
    }

    /// One lead-verdict marriage evidence row + its lead row — the state a
    /// research run's persist leaves behind for a held marriage lead.
    private func seedMarriageEvidence(
        _ db: ProjectDatabase, profileID: String, recordID: String,
        surname: String, givenName: String, spouseName: String?
    ) throws {
        let record = SourceRecord.marriage(MarriageRecord(
            common: RecordCommon(
                id: recordID, sourceID: "freebmd",
                name: nil, surname: surname, givenName: givenName,
                detailURL: "https://www.freebmd.org.uk/cgi/information.pl?r=\(recordID)",
                rawFields: [:]
            ),
            marriageYear: 1915, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Bakewell", volume: "7b", page: "2130a",
            spouseName: spouseName
        ))
        let scored = ScoredRecord(
            id: recordID, record: record, verdict: .lead,
            gates: [GateResult(gate: .name, outcome: .pass, reason: "surname=1.00")],
            summary: "\(givenName) \(surname), Dec 1915 Bakewell 7b/2130a"
        )
        try db.saveEvidence(profileID: profileID, scored: scored,
                            citationFull: "FreeBMD marriage index Dec 1915 Bakewell 7b/2130a",
                            citationURL: "https://www.freebmd.org.uk/cgi/information.pl?r=\(recordID)")
        try db.saveLead(Lead(
            id: "lead_\(recordID)", profileID: profileID,
            name: "\(givenName) \(surname)", surname: surname, givenName: givenName,
            birthYear: nil, deathYear: nil, relationship: "spouse",
            source: .scoredLead, status: .new,
            evidence: "Marriage index Dec 1915 Bakewell 7b/2130a",
            createdAt: Date()
        ))
    }
}
