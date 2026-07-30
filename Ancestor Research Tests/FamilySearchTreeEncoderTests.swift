import Testing
import Foundation
@testable import Ancestor_Research
@testable import AncestorKit

/// User Tree encoder (WL2 — FAMILYSEARCH_TREES_WRITE_SPEC §3/§4). Pins the
/// inclusion policy (deceased/stub/living), the person/couple/child-and-parents
/// projections against the documented body shapes, formal-date rendering, and
/// citation dedup with run-stable keys.
struct FamilySearchTreeEncoderTests {

    private let config = FamilySearchTreeEncoder.Config(
        treeName: "Test Tree", treeDescription: "A test", environment: .beta, currentYear: 2026)

    private func profile(
        _ id: String, first: String? = nil, last: String? = nil,
        married: String? = nil, gender: Gender? = nil,
        birth: String? = nil, death: String? = nil,
        birthPlace: String? = nil, deathPlace: String? = nil,
        privacy: Privacy = .normal
    ) -> Profile {
        Profile(
            id: id, firstName: first, lastName: last, marriedSurname: married,
            gender: gender,
            attributes: PersonAttributes(nameStatus: .known, lifeStatus: .normal, privacy: privacy),
            birthDate: birth.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthPlace,
            deathDate: death.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathPlace,
            isDeleted: false, sources: [:], disputes: [:])
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Inclusion policy (D1/D2)

    @Test func livingAndStubAndDeletedProfilesAreOmittedWithReasons() throws {
        var deleted = profile("@I4@", first: "Gone", death: "1900")
        deleted.isDeleted = true
        let snapshot = FamilyGraphSnapshot(profiles: [
            "@I1@": profile("@I1@", first: "Ernest", last: "Cauldwell", gender: .male, birth: "1887", death: "1955"),
            "@I2@": profile("@I2@", first: "Recent", last: "Person", birth: "1990"),   // living heuristic
            "@I3@": Profile(id: "@I3@", isDeleted: false, sources: [:], disputes: [:]), // anonymous stub
            "@I4@": deleted,
            "@I5@": profile("@I5@", first: "Flagged", death: "1980", privacy: .livingPrivate),
        ], relationships: [])
        let plan = try FamilySearchTreeEncoder.makePlan(snapshot: snapshot, config: config)
        #expect(plan.persons.map(\.profileID) == ["@I1@"])
        #expect(plan.omitted["@I2@"] == "living or potentially living")
        #expect(plan.omitted["@I3@"]?.contains("stub") == true)
        #expect(plan.omitted["@I4@"] == "deleted")
        #expect(plan.omitted["@I5@"] == "living or potentially living")   // explicit flag wins over death date
    }

    @Test func unboundedBirthWithNoDeathCountsAsPotentiallyLiving() {
        let unknown = profile("@I1@", first: "Mystery")
        #expect(FamilySearchTreeEncoder.isLiving(unknown, currentYear: 2026))
        let ancient = profile("@I2@", first: "Old", birth: "1850")
        #expect(!FamilySearchTreeEncoder.isLiving(ancient, currentYear: 2026))
    }

    // MARK: Person projection

    @Test func personBodyMatchesDocumentedShape() throws {
        let p = profile("@I1@", first: "Anastasia", last: "Aleksandrova", gender: .female,
                        birth: "3 Apr 1836", death: "1900", birthPlace: "Moscow, Russia")
        let body = FamilySearchTreeEncoder.personBody(p, events: [])
        let data = try JSONEncoder().encode(body)
        let root = try json(data)
        let person = try #require((root["persons"] as? [[String: Any]])?.first)
        #expect(person["living"] as? Bool == false)
        let gender = person["gender"] as? [String: Any]
        #expect(gender?["type"] as? String == "http://gedcomx.org/Female")
        let name = try #require((person["names"] as? [[String: Any]])?.first)
        #expect(name["type"] as? String == "http://gedcomx.org/BirthName")
        #expect(name["preferred"] as? Bool == true)
        let form = try #require((name["nameForms"] as? [[String: Any]])?.first)
        #expect(form["fullText"] as? String == "Anastasia Aleksandrova")
        let parts = try #require(form["parts"] as? [[String: Any]])
        #expect(parts.contains { $0["type"] as? String == "http://gedcomx.org/Given" && $0["value"] as? String == "Anastasia" })
        #expect(parts.contains { $0["type"] as? String == "http://gedcomx.org/Surname" && $0["value"] as? String == "Aleksandrova" })
        let facts = try #require(person["facts"] as? [[String: Any]])
        let birth = try #require(facts.first { $0["type"] as? String == "http://gedcomx.org/Birth" })
        let date = birth["date"] as? [String: Any]
        #expect(date?["original"] as? String == "3 Apr 1836")
        #expect(date?["formal"] as? String == "+1836")
        #expect((birth["place"] as? [String: Any])?["original"] as? String == "Moscow, Russia")
        let display = person["display"] as? [String: Any]
        #expect(display?["name"] as? String == "Anastasia Aleksandrova")
        #expect(display?["gender"] as? String == "Female")
    }

    @Test func marriedSurnameBecomesTypedMarriedNameForm() throws {
        let p = profile("@I1@", first: "Mary", last: "Thompson", married: "Holmes",
                        gender: .female, death: "1950")
        let body = FamilySearchTreeEncoder.personBody(p, events: [])
        let names = body.persons[0].names
        #expect(names.count == 2)
        #expect(names[0].type == "http://gedcomx.org/BirthName" && names[0].preferred)
        #expect(names[1].type == "http://gedcomx.org/MarriedName" && !names[1].preferred)
        #expect(names[1].nameForms[0].fullText == "Mary Holmes")
    }

    @Test func marriedSurnameOnlyIsTypedHonestlyAsPreferredMarriedName() {
        let p = profile("@I1@", first: "Sarah", married: "Keyworth", gender: .female, death: "1920")
        let names = FamilySearchTreeEncoder.personBody(p, events: []).persons[0].names
        #expect(names.count == 1)
        #expect(names[0].type == "http://gedcomx.org/MarriedName" && names[0].preferred)
    }

    @Test func lifeEventsMapToTypedFactsWithValues() throws {
        let p = profile("@I1@", first: "Ernest", last: "Cauldwell", death: "1955")
        let events = [
            LifeEvent(id: UUID(), profileID: "@I1@", type: .occupation,
                      date: GenealogicalDate(parsing: "1911"), description: "Framework knitter"),
            LifeEvent(id: UUID(), profileID: "@I1@", type: .baptism,
                      date: GenealogicalDate(parsing: "ABT 1887"), location: "Crich, Derbyshire"),
            LifeEvent(id: UUID(), profileID: "@I1@", type: .other, description: "untyped"),
        ]
        let facts = FamilySearchTreeEncoder.personBody(p, events: events).persons[0].facts
        let occupation = try #require(facts.first { $0.type == "http://gedcomx.org/Occupation" })
        #expect(occupation.value == "Framework knitter")
        let christening = try #require(facts.first { $0.type == "http://gedcomx.org/Christening" })
        #expect(christening.date?.formal == "A+1887")
        #expect(christening.place?.original == "Crich, Derbyshire")
        #expect(!facts.contains { $0.value == "untyped" })   // .other has no honest type — skipped
    }

    @Test func sensitiveLifeEventsAreExcludedFromThePlan() throws {
        var sensitiveEvent = LifeEvent(id: UUID(), profileID: "@I1@", type: .census,
                                       date: GenealogicalDate(parsing: "1911"))
        sensitiveEvent.sensitive = true
        let snapshot = FamilyGraphSnapshot(
            profiles: ["@I1@": profile("@I1@", first: "E", last: "C", death: "1955")],
            relationships: [],
            lifeEvents: ["@I1@": [sensitiveEvent]])
        let plan = try FamilySearchTreeEncoder.makePlan(snapshot: snapshot, config: config)
        let root = try json(plan.persons[0].body)
        let person = (root["persons"] as? [[String: Any]])?.first
        let facts = person?["facts"] as? [[String: Any]] ?? []
        #expect(!facts.contains { ($0["type"] as? String) == "http://gedcomx.org/Census" })
    }

    // MARK: Formal dates

    @Test func formalDateGrammarCoversAllQualifiers() {
        func formal(_ raw: String) -> String? {
            FamilySearchTreeEncoder.formalDate(GenealogicalDate(parsing: raw))
        }
        #expect(formal("1887") == "+1887")
        #expect(formal("ABT 1887") == "A+1887")
        #expect(formal("EST 1887") == "A+1887")
        #expect(formal("BEF 1890") == "/+1890")
        #expect(formal("AFT 1880") == "+1880/")
        #expect(formal("BET 1885 AND 1890") == "+1885/+1890")
    }

    @Test func unknownDateProducesNoWireDate() {
        #expect(FamilySearchTreeEncoder.writeDate(GenealogicalDate(parsing: "?")) == nil)
    }

    // MARK: Families

    @Test func spouseCoupleCarriesMarriageFactAndHusbandFirst() throws {
        let snapshot = FamilyGraphSnapshot(profiles: [
            "@W@": profile("@W@", first: "Elizabeth", last: "Shaw", gender: .female, death: "1940"),
            "@H@": profile("@H@", first: "William", last: "Keyworth", gender: .male, death: "1930"),
        ], relationships: [
            Relationship(id: UUID(), from: "@W@", to: "@H@", type: .spouse, role: nil,
                         subtype: .unknown, marriageDate: GenealogicalDate(parsing: "1896"),
                         marriageLocation: "Worksop", divorceDate: nil),
        ])
        let plan = try FamilySearchTreeEncoder.makePlan(snapshot: snapshot, config: config)
        let couple = try #require(plan.couples.first)
        #expect(couple.person1ProfileID == "@H@")   // husband ordered first
        #expect(couple.person2ProfileID == "@W@")
        let marriage = try #require(couple.facts.first { $0.type == "http://gedcomx.org/Marriage" })
        #expect(marriage.date?.formal == "+1896")
        #expect(marriage.place?.original == "Worksop")

        let body = try json(try FamilySearchTreeEncoder.coupleBody(
            couple, person1PID: "P1", person2PID: "P2", environment: .beta))
        let rel = try #require((body["relationships"] as? [[String: Any]])?.first)
        #expect(rel["type"] as? String == "http://gedcomx.org/Couple")
        let p1 = rel["person1"] as? [String: Any]
        #expect(p1?["resourceId"] as? String == "P1")
        #expect((p1?["resource"] as? String)?.contains("apibeta.familysearch.org/platform/tree/persons/P1") == true)
    }

    @Test func spousePairedParentsFormOneTwoParentRelationship() throws {
        let snapshot = FamilyGraphSnapshot(profiles: [
            "@F@": profile("@F@", first: "George", last: "Keyworth", gender: .male, death: "1920"),
            "@M@": profile("@M@", first: "Sarah", last: "Booth", gender: .female, death: "1925"),
            "@C@": profile("@C@", first: "William", last: "Keyworth", gender: .male, death: "1950"),
        ], relationships: [
            Relationship(id: UUID(), from: "@F@", to: "@M@", type: .spouse, role: nil,
                         subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
            Relationship(id: UUID(), from: "@F@", to: "@C@", type: .parent, role: .father,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
            Relationship(id: UUID(), from: "@M@", to: "@C@", type: .parent, role: .mother,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
        ])
        let plan = try FamilySearchTreeEncoder.makePlan(snapshot: snapshot, config: config)
        #expect(plan.childAndParents.count == 1)
        let cap = try #require(plan.childAndParents.first)
        #expect(cap.parent1ProfileID == "@F@")   // father = parent1
        #expect(cap.parent2ProfileID == "@M@")
        #expect(cap.parent1Lineage == "http://gedcomx.org/BiologicalParent")

        let body = try json(try FamilySearchTreeEncoder.childAndParentsBody(
            cap, childPID: "C1", parent1PID: "F1", parent2PID: "M1", environment: .beta))
        let rel = try #require((body["childAndParentsRelationships"] as? [[String: Any]])?.first)
        #expect((rel["child"] as? [String: Any])?["resourceId"] as? String == "C1")
        #expect((rel["parent1"] as? [String: Any])?["resourceId"] as? String == "F1")
        let p1Facts = rel["parent1Facts"] as? [[String: Any]]
        #expect(p1Facts?.first?["type"] as? String == "http://gedcomx.org/BiologicalParent")
    }

    @Test func unpairedParentGetsSingleParentRelationship() throws {
        let snapshot = FamilyGraphSnapshot(profiles: [
            "@M@": profile("@M@", first: "Ann", last: "Land", gender: .female, death: "1900"),
            "@C@": profile("@C@", first: "John", last: "Land", gender: .male, death: "1930"),
        ], relationships: [
            Relationship(id: UUID(), from: "@M@", to: "@C@", type: .parent, role: .mother,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
        ])
        let plan = try FamilySearchTreeEncoder.makePlan(snapshot: snapshot, config: config)
        let cap = try #require(plan.childAndParents.first)
        #expect(cap.parent1ProfileID == nil)
        #expect(cap.parent2ProfileID == "@M@")   // mother = parent2 side
    }

    @Test func edgesTouchingOmittedProfilesAreDropped() throws {
        let snapshot = FamilyGraphSnapshot(profiles: [
            "@D@": profile("@D@", first: "Dead", last: "Parent", gender: .male, death: "1950"),
            "@L@": profile("@L@", first: "Living", last: "Child", birth: "1980"),
        ], relationships: [
            Relationship(id: UUID(), from: "@D@", to: "@L@", type: .parent, role: .father,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
        ])
        let plan = try FamilySearchTreeEncoder.makePlan(snapshot: snapshot, config: config)
        #expect(plan.childAndParents.isEmpty)   // child excluded ⇒ no relationship
        #expect(plan.persons.map(\.profileID) == ["@D@"])
    }

    // MARK: Sources

    @Test func citationsDedupAcrossPersonsWithRunStableKeys() throws {
        let shared = Citation(collection: "FreeBMD Birth Index", page: "vol 7b p213", url: "https://www.freebmd.org.uk/x")
        let source = FieldSource(origin: .freebmd, raw: "test", addedAt: Date(), citation: shared)
        var p1 = profile("@I1@", first: "A", last: "B", death: "1900")
        p1.sources[.birthDate] = [source]
        var p2 = profile("@I2@", first: "C", last: "D", death: "1910")
        p2.sources[.deathDate] = [source]

        let snapshot = FamilyGraphSnapshot(profiles: ["@I1@": p1, "@I2@": p2], relationships: [])
        let plan = try FamilySearchTreeEncoder.makePlan(snapshot: snapshot, config: config)
        #expect(plan.sourceDescriptions.count == 1)   // create once
        #expect(plan.personSourceRefs.count == 2)     // reference twice
        #expect(plan.personSourceRefs[0].citationKeys == plan.personSourceRefs[1].citationKeys)
        // Run-stable key (FNV-1a, not process-seeded Hasher):
        #expect(FamilySearchTreeEncoder.citationKey(shared) == FamilySearchTreeEncoder.citationKey(shared))

        let body = try json(plan.sourceDescriptions[0].body)
        let desc = try #require((body["sourceDescriptions"] as? [[String: Any]])?.first)
        #expect(desc["about"] as? String == "https://www.freebmd.org.uk/x")
        let citations = desc["citations"] as? [[String: Any]]
        #expect((citations?.first?["value"] as? String)?.contains("FreeBMD Birth Index") == true)
    }

    @Test func personSourcesBodyCarriesAttributionAndDescriptionURIs() throws {
        let data = try FamilySearchTreeEncoder.personSourcesBody(
            descriptionURIs: ["https://apibeta.familysearch.org/platform/sources/descriptions/QDS-1"])
        let root = try json(data)
        let entry = try #require((root["persons"] as? [[String: Any]])?.first)
        let ref = try #require((entry["sources"] as? [[String: Any]])?.first)
        #expect((ref["description"] as? String)?.hasSuffix("QDS-1") == true)
        #expect(((ref["attribution"] as? [String: Any])?["changeMessage"] as? String)?.contains("Ancestor Research") == true)
    }

    // MARK: Group / tree / finalize bodies

    @Test func treeBodySetsAllThreeAccessFieldsToAnyApps() throws {
        let data = try FamilySearchTreeEncoder.treeBody(groupID: "9M9H-2G7", config: config)
        let root = try json(data)
        let tree = try #require((root["trees"] as? [[String: Any]])?.first)
        #expect(tree["groupIds"] as? [String] == ["9M9H-2G7"])
        #expect(tree["name"] as? String == "Test Tree")
        #expect(tree["ownerAccess"] as? String == "AnyApps")
        #expect(tree["groupAccess"] as? String == "AnyApps")
        #expect(tree["allAccess"] as? String == "AnyApps")
    }

    @Test func finalizeBodyFlipsHiddenAndCarriesPrivacyChoice() throws {
        let root = try json(try FamilySearchTreeEncoder.treeFinalizeBody(startingPersonPID: "P77", isPrivate: true))
        let tree = try #require((root["trees"] as? [[String: Any]])?.first)
        #expect(tree["startingPersonId"] as? String == "P77")
        #expect(tree["hidden"] as? Bool == false)
        #expect(tree["private"] as? Bool == true)
    }
}
