import Foundation
import AncestorKit

// FamilySearch User Tree encoder (WL2 — FAMILYSEARCH_TREES_WRITE_SPEC §3/§4).
//
// Pure projection from the local model onto the documented write-body shapes
// (FS_WRITE_WIRE_CONTRACTS.md). Persons encode fully at plan time; relationship
// and source-reference bodies are SPECS rendered later, once FamilySearch has
// minted the pids they reference. All inclusion/mapping policy lives here so
// the orchestrator (WL4) is dumb plumbing and the whole policy is unit-tested.

// MARK: - Write body shapes (Encodable mirrors of the documented examples)

nonisolated struct FSWriteGroupBody: Encodable, Sendable {
    struct Group: Encodable, Sendable {
        let name: String
        let description: String
        let codeOfConduct: String
    }
    let groups: [Group]
}

nonisolated struct FSWriteTreeBody: Encodable, Sendable {
    struct Tree: Encodable, Sendable {
        let groupIds: [String]
        let name: String
        let description: String
        let ownerAccess: String
        let groupAccess: String
        let allAccess: String
    }
    let trees: [Tree]
}

nonisolated struct FSWriteTreeUpdateBody: Encodable, Sendable {
    struct Update: Encodable, Sendable {
        let startingPersonId: String
        let hidden: Bool
        let `private`: Bool
    }
    let trees: [Update]
}

nonisolated struct FSWriteAttribution: Encodable, Sendable {
    let changeMessage: String
}

nonisolated struct FSWriteDate: Encodable, Sendable {
    let original: String
    let formal: String?
}

nonisolated struct FSWritePlace: Encodable, Sendable {
    let original: String
}

nonisolated struct FSWriteFact: Encodable, Sendable {
    let type: String
    let date: FSWriteDate?
    let place: FSWritePlace?
    /// GEDCOM X `Fact.value` — the freeform payload ("Framework knitter").
    let value: String?

    init(type: String, date: FSWriteDate? = nil, place: FSWritePlace? = nil, value: String? = nil) {
        self.type = type
        self.date = date
        self.place = place
        self.value = value
    }
}

nonisolated struct FSWritePersonBody: Encodable, Sendable {
    struct Person: Encodable, Sendable {
        struct Gender: Encodable, Sendable { let type: String }
        struct Name: Encodable, Sendable {
            struct Form: Encodable, Sendable {
                struct Part: Encodable, Sendable { let type: String; let value: String }
                let fullText: String
                let parts: [Part]
            }
            let type: String
            let preferred: Bool
            let nameForms: [Form]
        }
        struct Display: Encodable, Sendable { let name: String; let gender: String? }

        let living: Bool
        let gender: Gender?
        let names: [Name]
        let facts: [FSWriteFact]
        let display: Display
    }
    let persons: [Person]
}

nonisolated struct FSWriteResourceReference: Encodable, Sendable {
    let resource: String
    let resourceId: String
}

nonisolated struct FSWriteCoupleBody: Encodable, Sendable {
    struct Couple: Encodable, Sendable {
        let type: String
        let person1: FSWriteResourceReference
        let person2: FSWriteResourceReference
        let facts: [FSWriteFact]?
    }
    let relationships: [Couple]
}

nonisolated struct FSWriteChildAndParentsBody: Encodable, Sendable {
    struct LineageFact: Encodable, Sendable { let type: String }
    struct ChildAndParents: Encodable, Sendable {
        let parent1: FSWriteResourceReference?
        let parent2: FSWriteResourceReference?
        let child: FSWriteResourceReference
        let parent1Facts: [LineageFact]?
        let parent2Facts: [LineageFact]?
    }
    let childAndParentsRelationships: [ChildAndParents]
}

nonisolated struct FSWriteSourceDescriptionBody: Encodable, Sendable {
    struct Description: Encodable, Sendable {
        struct CitationValue: Encodable, Sendable { let value: String }
        struct Title: Encodable, Sendable { let value: String }
        let about: String?
        let citations: [CitationValue]
        let titles: [Title]?
    }
    let sourceDescriptions: [Description]
}

/// Person source-reference body — POSTs to the person resource itself.
nonisolated struct FSWritePersonSourcesBody: Encodable, Sendable {
    struct Entry: Encodable, Sendable {
        struct Ref: Encodable, Sendable {
            let attribution: FSWriteAttribution
            let description: String
        }
        let sources: [Ref]
    }
    let persons: [Entry]
}

/// Couple source-reference body (carries the relationship id, per the docs).
nonisolated struct FSWriteCoupleSourcesBody: Encodable, Sendable {
    struct Entry: Encodable, Sendable {
        let id: String
        let sources: [FSWritePersonSourcesBody.Entry.Ref]
    }
    let relationships: [Entry]
}

// MARK: - Plan (persons encoded; relationships/sources as specs)

nonisolated struct FSUploadPlan: Sendable {
    struct PersonUpload: Sendable {
        let profileID: String
        let displayName: String
        let body: Data
    }
    struct CoupleSpec: Sendable {
        /// Stable resume key: `"couple|" + sorted pair of profile IDs`.
        let localKey: String
        let person1ProfileID: String
        let person2ProfileID: String
        let facts: [FSWriteFact]
        /// Citation keys (into `sourceDescriptions`) to reference on this couple.
        let citationKeys: [String]
    }
    struct ChildAndParentsSpec: Sendable {
        /// Stable resume key: `"cap|<child>|<parent1 ?? ->|<parent2 ?? ->"`.
        let localKey: String
        let childProfileID: String
        let parent1ProfileID: String?
        let parent2ProfileID: String?
        let parent1Lineage: String?
        let parent2Lineage: String?
    }
    struct SourceDescriptionUpload: Sendable {
        /// Stable dedup/resume key (content hash of the citation).
        let key: String
        let body: Data
    }
    struct PersonSourceRefSpec: Sendable {
        let profileID: String
        let citationKeys: [String]
    }

    let groupBody: Data
    let treeBody: Data
    let persons: [PersonUpload]
    let couples: [CoupleSpec]
    let childAndParents: [ChildAndParentsSpec]
    let sourceDescriptions: [SourceDescriptionUpload]
    let personSourceRefs: [PersonSourceRefSpec]
    /// Profiles excluded from upload, keyed by profile ID → human-readable reason.
    let omitted: [String: String]

    var isEmpty: Bool { persons.isEmpty }
}

// MARK: - Encoder

nonisolated enum FamilySearchTreeEncoder {

    /// ADR-009: writes carry a deterministic attribution message.
    static let changeMessage = "Uploaded from Ancestor Research (deterministic pipeline; human-reviewed)"

    /// D3 — fixed for the tree's lifetime; all three AnyApps or the tree can
    /// never participate in FS search/match. The docs are inconsistent about
    /// the wire form (bare enum vs URI) — single constant so the WL4 live
    /// probe can flip it in one place.
    static let accessValue = "AnyApps"

    struct Config: Sendable {
        let treeName: String
        let treeDescription: String
        let environment: FamilySearchEnvironment
        /// Injected for determinism (living heuristic) — tests pin it.
        let currentYear: Int
    }

    // MARK: Plan

    static func makePlan(
        snapshot: FamilyGraphSnapshot,
        relationshipCitations: [UUID: [Citation]] = [:],
        config: Config
    ) throws -> FSUploadPlan {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // -- Inclusion (D1/D2): deceased, non-stub, non-deleted only.
        var omitted: [String: String] = [:]
        var included: [String: Profile] = [:]
        for (id, profile) in snapshot.profiles {
            if profile.isDeleted { omitted[id] = "deleted" }
            else if profile.isAnonymousStub { omitted[id] = "anonymous stub (no name, no dates)" }
            else if isLiving(profile, currentYear: config.currentYear) { omitted[id] = "living or potentially living" }
            else { included[id] = profile }
        }

        // -- Persons (deterministic order: sorted by profile ID).
        var persons: [FSUploadPlan.PersonUpload] = []
        for id in included.keys.sorted() {
            let profile = included[id]!
            let events = (snapshot.lifeEvents[id] ?? []).filter { !$0.sensitive }
            let body = try encoder.encode(personBody(profile, events: events))
            persons.append(.init(profileID: id, displayName: profile.displayName, body: body))
        }

        // -- Citations: dedup across all included persons (registry pattern).
        var descriptionsByKey: [String: Citation] = [:]
        var personRefs: [FSUploadPlan.PersonSourceRefSpec] = []
        for id in included.keys.sorted() {
            let profile = included[id]!
            var citations = profile.sources.values.flatMap { $0 }.compactMap(\.citation)
            citations += (snapshot.lifeEvents[id] ?? [])
                .filter { !$0.sensitive }
                .flatMap(\.sources).compactMap(\.citation)
            let keys = citations.filter { !$0.isEmpty }.map { citation in
                let key = citationKey(citation)
                descriptionsByKey[key] = citation
                return key
            }
            let unique = Array(Set(keys)).sorted()
            if !unique.isEmpty {
                personRefs.append(.init(profileID: id, citationKeys: unique))
            }
        }

        // -- Families: mirror GEDCOMExporter.buildFamilies semantics over the
        //    INCLUDED subgraph (edges touching an omitted profile drop).
        var couples: [String: FSUploadPlan.CoupleSpec] = [:]
        for rel in snapshot.relationships where rel.type == .spouse {
            guard included[rel.from] != nil, included[rel.to] != nil else { continue }
            let pair = [rel.from, rel.to].sorted()
            let key = "couple|" + pair.joined(separator: "+")
            guard couples[key] == nil else { continue }
            // person1 = husband by gender when known (docs' Family-Tree
            // convention; harmless if user trees don't enforce it).
            let (p1, p2) = orderCouple(rel.from, rel.to, profiles: included)
            var facts: [FSWriteFact] = []
            if rel.marriageDate != nil || rel.marriageLocation != nil {
                facts.append(FSWriteFact(
                    type: "http://gedcomx.org/Marriage",
                    date: rel.marriageDate.flatMap(writeDate),
                    place: rel.marriageLocation.map { FSWritePlace(original: $0) }))
            }
            if let divorce = rel.divorceDate {
                facts.append(FSWriteFact(type: "http://gedcomx.org/Divorce", date: writeDate(divorce)))
            }
            let citationKeys = (relationshipCitations[rel.id] ?? [])
                .filter { !$0.isEmpty }
                .map { citation -> String in
                    let key = citationKey(citation)
                    descriptionsByKey[key] = citation
                    return key
                }
            couples[key] = .init(localKey: key, person1ProfileID: p1, person2ProfileID: p2,
                                 facts: facts, citationKeys: Array(Set(citationKeys)).sorted())
        }

        var childToParentEdges: [String: [Relationship]] = [:]
        for rel in snapshot.relationships where rel.type == .parent {
            guard included[rel.to] != nil, included[rel.from] != nil else { continue }
            childToParentEdges[rel.to, default: []].append(rel)
        }

        var caps: [FSUploadPlan.ChildAndParentsSpec] = []
        for childID in childToParentEdges.keys.sorted() {
            let edges = childToParentEdges[childID]!
            var assigned: Set<String> = []
            let parentIDs = edges.map(\.from)

            // Spouse-paired parents → one two-parent relationship.
            for i in 0..<parentIDs.count {
                guard !assigned.contains(parentIDs[i]) else { continue }
                for j in (i + 1)..<parentIDs.count {
                    guard !assigned.contains(parentIDs[j]) else { continue }
                    let pairKey = "couple|" + [parentIDs[i], parentIDs[j]].sorted().joined(separator: "+")
                    guard couples[pairKey] != nil else { continue }
                    let edgeA = edges.first { $0.from == parentIDs[i] }!
                    let edgeB = edges.first { $0.from == parentIDs[j] }!
                    let (p1Edge, p2Edge) = orderParents(edgeA, edgeB, profiles: included)
                    caps.append(.init(
                        localKey: "cap|\(childID)|\(p1Edge.from)|\(p2Edge.from)",
                        childProfileID: childID,
                        parent1ProfileID: p1Edge.from,
                        parent2ProfileID: p2Edge.from,
                        parent1Lineage: lineageType(p1Edge.subtype),
                        parent2Lineage: lineageType(p2Edge.subtype)))
                    assigned.insert(parentIDs[i])
                    assigned.insert(parentIDs[j])
                }
            }

            // Leftover single parents → one-parent relationships.
            for edge in edges where !assigned.contains(edge.from) {
                let asParent1 = included[edge.from]?.gender != .female
                caps.append(.init(
                    localKey: "cap|\(childID)|\(asParent1 ? edge.from : "-")|\(asParent1 ? "-" : edge.from)",
                    childProfileID: childID,
                    parent1ProfileID: asParent1 ? edge.from : nil,
                    parent2ProfileID: asParent1 ? nil : edge.from,
                    parent1Lineage: asParent1 ? lineageType(edge.subtype) : nil,
                    parent2Lineage: asParent1 ? nil : lineageType(edge.subtype)))
            }
        }

        // -- Source description bodies.
        var descriptions: [FSUploadPlan.SourceDescriptionUpload] = []
        for key in descriptionsByKey.keys.sorted() {
            let body = try encoder.encode(sourceDescriptionBody(descriptionsByKey[key]!))
            descriptions.append(.init(key: key, body: body))
        }

        let groupBody = try encoder.encode(FSWriteGroupBody(groups: [.init(
            name: "\(config.treeName) — access group",
            description: "Access group for the tree “\(config.treeName)” uploaded by Ancestor Research.",
            codeOfConduct: "Please be respectful of this family history research.")]))
        let treeBody = try encoder.encode(FSWriteTreeBody(trees: [.init(
            groupIds: [], name: config.treeName, description: config.treeDescription,
            ownerAccess: accessValue, groupAccess: accessValue, allAccess: accessValue)]))
        // NB groupIds is patched by the orchestrator once the group exists —
        // see `treeBody(groupID:config:)`.

        return FSUploadPlan(
            groupBody: groupBody,
            treeBody: treeBody,
            persons: persons,
            couples: couples.keys.sorted().map { couples[$0]! },
            childAndParents: caps.sorted { $0.localKey < $1.localKey },
            sourceDescriptions: descriptions,
            personSourceRefs: personRefs,
            omitted: omitted)
    }

    /// The tree body with the (runtime-minted) group ID in place.
    static func treeBody(groupID: String, config: Config) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(FSWriteTreeBody(trees: [.init(
            groupIds: [groupID], name: config.treeName, description: config.treeDescription,
            ownerAccess: accessValue, groupAccess: accessValue, allAccess: accessValue)]))
    }

    // MARK: Runtime body rendering (pids known only after creation)

    static func coupleBody(
        _ spec: FSUploadPlan.CoupleSpec, person1PID: String, person2PID: String,
        environment: FamilySearchEnvironment
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(FSWriteCoupleBody(relationships: [.init(
            type: "http://gedcomx.org/Couple",
            person1: personRef(person1PID, environment: environment),
            person2: personRef(person2PID, environment: environment),
            facts: spec.facts.isEmpty ? nil : spec.facts)]))
    }

    static func childAndParentsBody(
        _ spec: FSUploadPlan.ChildAndParentsSpec,
        childPID: String, parent1PID: String?, parent2PID: String?,
        environment: FamilySearchEnvironment
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(FSWriteChildAndParentsBody(childAndParentsRelationships: [.init(
            parent1: parent1PID.map { personRef($0, environment: environment) },
            parent2: parent2PID.map { personRef($0, environment: environment) },
            child: personRef(childPID, environment: environment),
            parent1Facts: spec.parent1Lineage.map { [.init(type: $0)] },
            parent2Facts: spec.parent2Lineage.map { [.init(type: $0)] })]))
    }

    static func personSourcesBody(descriptionURIs: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let refs = descriptionURIs.map {
            FSWritePersonSourcesBody.Entry.Ref(
                attribution: FSWriteAttribution(changeMessage: changeMessage), description: $0)
        }
        return try encoder.encode(FSWritePersonSourcesBody(persons: [.init(sources: refs)]))
    }

    static func coupleSourcesBody(relationshipID: String, descriptionURIs: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let refs = descriptionURIs.map {
            FSWritePersonSourcesBody.Entry.Ref(
                attribution: FSWriteAttribution(changeMessage: changeMessage), description: $0)
        }
        return try encoder.encode(FSWriteCoupleSourcesBody(relationships: [.init(id: relationshipID, sources: refs)]))
    }

    static func treeFinalizeBody(startingPersonPID: String, isPrivate: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(FSWriteTreeUpdateBody(trees: [.init(
            startingPersonId: startingPersonPID, hidden: false, private: isPrivate)]))
    }

    // MARK: - Person projection

    static func personBody(_ profile: Profile, events: [LifeEvent]) -> FSWritePersonBody {
        var names: [FSWritePersonBody.Person.Name] = []

        let givenValue = [profile.firstName, profile.middleName]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let maiden = profile.lastName?.trimmingCharacters(in: .whitespaces)
        let married = profile.marriedSurname?.trimmingCharacters(in: .whitespaces)

        func nameEntry(type: String, preferred: Bool, surname: String?) -> FSWritePersonBody.Person.Name {
            var parts: [FSWritePersonBody.Person.Name.Form.Part] = []
            if !givenValue.isEmpty { parts.append(.init(type: "http://gedcomx.org/Given", value: givenValue)) }
            if let surname, !surname.isEmpty { parts.append(.init(type: "http://gedcomx.org/Surname", value: surname)) }
            let fullText = [givenValue, surname ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            return .init(type: type, preferred: preferred, nameForms: [.init(fullText: fullText, parts: parts)])
        }

        if let maiden, !maiden.isEmpty {
            names.append(nameEntry(type: "http://gedcomx.org/BirthName", preferred: true, surname: maiden))
            if let married, !married.isEmpty, married.caseInsensitiveCompare(maiden) != .orderedSame {
                names.append(nameEntry(type: "http://gedcomx.org/MarriedName", preferred: false, surname: married))
            }
        } else if let married, !married.isEmpty {
            // Only a married surname is known — E2's "clean gain": type it honestly.
            names.append(nameEntry(type: "http://gedcomx.org/MarriedName", preferred: true, surname: married))
        } else {
            names.append(nameEntry(type: "http://gedcomx.org/BirthName", preferred: true, surname: nil))
        }
        if let nick = profile.nickName, !nick.isEmpty {
            names.append(.init(type: "http://gedcomx.org/Nickname", preferred: false,
                               nameForms: [.init(fullText: nick, parts: [])]))
        }

        var facts: [FSWriteFact] = []
        if profile.birthDate != nil || profile.birthLocation != nil {
            facts.append(FSWriteFact(
                type: "http://gedcomx.org/Birth",
                date: profile.birthDate.flatMap(writeDate),
                place: profile.birthLocation.map { FSWritePlace(original: $0) }))
        }
        if profile.deathDate != nil || profile.deathLocation != nil {
            facts.append(FSWriteFact(
                type: "http://gedcomx.org/Death",
                date: profile.deathDate.flatMap(writeDate),
                place: profile.deathLocation.map { FSWritePlace(original: $0) }))
        }
        for event in events {
            guard let type = factType(event.type) else { continue }
            facts.append(FSWriteFact(
                type: type,
                date: event.date.flatMap(writeDate),
                place: event.location.map { FSWritePlace(original: $0) },
                value: event.description?.isEmpty == false ? event.description : nil))
        }

        return FSWritePersonBody(persons: [.init(
            living: false,   // D1 — only deceased upload, stated explicitly
            gender: genderType(profile.gender).map { .init(type: $0) },
            names: names,
            facts: facts,
            display: .init(name: profile.displayName, gender: displayGender(profile.gender)))])
    }

    // MARK: - Leaf mappings

    /// D1 living test: explicit flag OR the publisher's 100-year heuristic.
    static func isLiving(_ profile: Profile, currentYear: Int) -> Bool {
        if (profile.attributes ?? .default).privacy == .livingPrivate { return true }
        if profile.deathDate != nil { return false }
        if let latestBirth = profile.birthDate?.latest { return latestBirth + 100 >= currentYear }
        return true   // unbounded birth, no death — cannot rule out living
    }

    /// GenealogicalDate → GEDCOM X formal grammar at year precision (the
    /// model is year-integer by design; `original` carries the verbatim text).
    static func formalDate(_ date: GenealogicalDate) -> String? {
        func y(_ year: Int) -> String { String(format: "%+05d", year) }
        switch date.qualifier {
        case .exact, .yearOnly:
            return date.bestYear.map(y)
        case .about, .estimated, .calculated:
            return date.bestYear.map { "A" + y($0) }
        case .before:
            return date.latest.map { "/" + y($0) }
        case .after:
            return date.earliest.map { y($0) + "/" }
        case .between:
            guard let e = date.earliest, let l = date.latest else { return date.bestYear.map(y) }
            return y(e) + "/" + y(l)
        }
    }

    static func writeDate(_ date: GenealogicalDate) -> FSWriteDate? {
        let original = date.original.trimmingCharacters(in: .whitespaces)
        let formal = formalDate(date)
        // "?" and other no-information dates carry nothing worth sending.
        guard formal != nil || (!original.isEmpty && original != "?") else { return nil }
        return FSWriteDate(original: original, formal: formal)
    }

    static func factType(_ type: LifeEventType) -> String? {
        switch type {
        case .baptism: "http://gedcomx.org/Christening"
        case .burial: "http://gedcomx.org/Burial"
        case .probate: "http://gedcomx.org/Probate"
        case .census: "http://gedcomx.org/Census"
        case .residence: "http://gedcomx.org/Residence"
        case .occupation: "http://gedcomx.org/Occupation"
        case .education: "http://gedcomx.org/Education"
        case .militaryService: "http://gedcomx.org/MilitaryService"
        case .religion: "http://gedcomx.org/Religion"
        case .immigration: "http://gedcomx.org/Immigration"
        case .emigration: "http://gedcomx.org/Emigration"
        case .other: nil   // freeform — no honest GEDCOM X type
        }
    }

    static func genderType(_ gender: Gender?) -> String? {
        switch gender {
        case .male: "http://gedcomx.org/Male"
        case .female: "http://gedcomx.org/Female"
        case .other, .unknown: "http://gedcomx.org/Unknown"
        case nil: nil
        }
    }

    private static func displayGender(_ gender: Gender?) -> String? {
        switch gender {
        case .male: "Male"
        case .female: "Female"
        default: nil
        }
    }

    static func lineageType(_ subtype: RelationshipSubtype) -> String? {
        switch subtype {
        case .biological: "http://gedcomx.org/BiologicalParent"
        case .adoptive: "http://gedcomx.org/AdoptiveParent"
        case .step: "http://gedcomx.org/StepParent"
        case .unknown: nil
        }
    }

    /// Content-hash key for citation dedup (registry pattern) — FNV-1a, NOT
    /// `Hasher` (which is process-seeded): the key must be stable across runs
    /// because it doubles as the resume key in `familysearch_entity_links`.
    static func citationKey(_ citation: Citation) -> String {
        let fields = [citation.repository, citation.collection, citation.title,
                      citation.page, citation.url, citation.notes]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in fields.map({ $0 ?? "" }).joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "cit|\(String(hash, radix: 36))"
    }

    static func sourceDescriptionBody(_ citation: Citation) -> FSWriteSourceDescriptionBody {
        let title = [citation.title, citation.collection].compactMap { $0 }.first { !$0.isEmpty }
        return FSWriteSourceDescriptionBody(sourceDescriptions: [.init(
            about: citation.url?.isEmpty == false ? citation.url : nil,
            citations: [.init(value: citation.formatted)],
            titles: title.map { [.init(value: $0)] })])
    }

    // MARK: - Ordering helpers

    private static func personRef(_ pid: String, environment: FamilySearchEnvironment) -> FSWriteResourceReference {
        FSWriteResourceReference(
            resource: "https://\(environment.apiHost)/platform/tree/persons/\(pid)",
            resourceId: pid)
    }

    private static func orderCouple(_ a: String, _ b: String, profiles: [String: Profile]) -> (String, String) {
        if profiles[a]?.gender == .male { return (a, b) }
        if profiles[b]?.gender == .male { return (b, a) }
        return (a, b)
    }

    /// parent1 = father when the roles/genders say so, else stable order.
    private static func orderParents(
        _ a: Relationship, _ b: Relationship, profiles: [String: Profile]
    ) -> (Relationship, Relationship) {
        func isFather(_ edge: Relationship) -> Bool {
            edge.role == .father || profiles[edge.from]?.gender == .male
        }
        if isFather(a) { return (a, b) }
        if isFather(b) { return (b, a) }
        return a.from < b.from ? (a, b) : (b, a)
    }
}
