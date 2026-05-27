import Testing
import Foundation
@testable import Ancestor_Research

/// Slice 11 — `ProjectDatabase.ensureSpouseEdgeForParents` materialises
/// the spouse relationship between two linked parents when a
/// `.parentMarriage` hypothesis is supported. Closes the gap surfaced
/// by Lilian Brooks's tree: the marriage was found and the parent
/// hypotheses were cross-referenced with it, but no spouse edge was
/// ever created between the parent ghosts.
@MainActor
struct SpouseEdgeMaterializationTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(
        id: String, surname: String, given: String?,
        gender: Gender, birthYear: Int?
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: given, middleName: nil, lastName: surname,
            marriedSurname: nil, nickName: nil, mothersMaidenName: nil,
            gender: gender, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, birthLocationCode: nil,
            deathDate: nil, deathLocation: nil, deathLocationCode: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func parentEdge(from: String, to: String, role: ParentRole) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: role, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func marriageRecord(
        id: String, surname: String, givenName: String,
        spouseSurname: String,
        year: Int = 1911, quarter: String = "Dec", district: String = "Belper"
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: "freebmd", name: "\(givenName) \(surname)",
            surname: surname, givenName: givenName,
            detailURL: nil, rawFields: [:]
        )
        let m = MarriageRecord(
            common: common,
            marriageYear: year, marriageDate: nil, marriagePlace: nil,
            quarter: quarter, district: district,
            volume: "7b", page: "1397", spouseName: spouseSurname
        )
        return ScoredRecord(id: id, record: .marriage(m), verdict: .lead, gates: [], summary: "")
    }

    private func supportedParentMarriage(
        subjectID: String, mother: String, father: String,
        evidenceIDs: [String]
    ) -> ResearchHypothesis {
        let kind = HypothesisKind.parentMarriage(
            motherSurname: mother, fatherSurname: father, windowYears: 1884...1915
        )
        return ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: subjectID),
            subjectProfileID: subjectID, kind: kind,
            verdict: .supported, isModelAssisted: false,
            supportingEvidence: evidenceIDs, contradictingEvidence: [],
            reasoning: "test", createdAt: Date(), lastTestedAt: Date(),
            attempts: 1, history: []
        )
    }

    // MARK: - Positive path

    @Test func createsSpouseEdgeWithMarriageDateAndDistrict() throws {
        let db = try makeTempDB()

        let lilian = makeProfile(id: "lilian", surname: "Brooks", given: "Lilian",
                                  gender: .female, birthYear: 1914)
        let father = makeProfile(id: "brooks-ghost", surname: "Brooks", given: nil,
                                  gender: .male, birthYear: nil)
        let mother = makeProfile(id: "land-ghost", surname: "Land", given: nil,
                                  gender: .female, birthYear: nil)

        try db.addFamily(
            profiles: [lilian, father, mother],
            relationships: [
                parentEdge(from: "brooks-ghost", to: "lilian", role: .father),
                parentEdge(from: "land-ghost", to: "lilian", role: .mother),
            ],
            source: .gedcom
        )

        let snapshot = try db.buildSnapshot()
        let groomRec = marriageRecord(
            id: "m-groom", surname: "Brooks", givenName: "George H",
            spouseSurname: "", year: 1911, quarter: "Dec", district: "Belper"
        )
        let brideRec = marriageRecord(
            id: "m-bride", surname: "Land", givenName: "Ida L",
            spouseSurname: "", year: 1911, quarter: "Dec", district: "Belper"
        )
        let marriage = supportedParentMarriage(
            subjectID: "lilian", mother: "Land", father: "Brooks",
            evidenceIDs: ["m-groom", "m-bride"]
        )

        let newEdgeID = try db.ensureSpouseEdgeForParents(
            ofSubject: "lilian",
            hypotheses: [marriage],
            scoredRecords: [groomRec, brideRec],
            snapshot: snapshot
        )
        #expect(newEdgeID != nil)

        // Reload + verify
        let after = try db.buildSnapshot()
        let spouseEdge = after.relationships.first { r in
            r.type == .spouse &&
            ((r.from == "brooks-ghost" && r.to == "land-ghost") ||
             (r.from == "land-ghost" && r.to == "brooks-ghost"))
        }
        let edge = try #require(spouseEdge)
        #expect(edge.from == "brooks-ghost", "husband (father) is .from in the spouse edge convention")
        #expect(edge.to == "land-ghost")
        #expect(edge.marriageDate?.original == "DEC 1911")
        #expect(edge.marriageLocation == "Belper")
    }

    // MARK: - Idempotence

    @Test func idempotentWhenSpouseEdgeAlreadyExists() throws {
        let db = try makeTempDB()
        let lilian = makeProfile(id: "lilian", surname: "Brooks", given: "Lilian", gender: .female, birthYear: 1914)
        let father = makeProfile(id: "brooks-ghost", surname: "Brooks", given: nil, gender: .male, birthYear: nil)
        let mother = makeProfile(id: "land-ghost", surname: "Land", given: nil, gender: .female, birthYear: nil)
        let existingSpouseEdge = Relationship(
            id: UUID(), from: "brooks-ghost", to: "land-ghost",
            type: .spouse, role: nil, subtype: .biological,
            marriageDate: GenealogicalDate(parsing: "1900"),  // user-set
            marriageLocation: "Somewhere", divorceDate: nil
        )
        try db.addFamily(
            profiles: [lilian, father, mother],
            relationships: [
                parentEdge(from: "brooks-ghost", to: "lilian", role: .father),
                parentEdge(from: "land-ghost", to: "lilian", role: .mother),
                existingSpouseEdge,
            ],
            source: .gedcom
        )

        let snapshot = try db.buildSnapshot()
        let groomRec = marriageRecord(
            id: "m-groom", surname: "Brooks", givenName: "George H",
            spouseSurname: ""
        )
        let marriage = supportedParentMarriage(
            subjectID: "lilian", mother: "Land", father: "Brooks",
            evidenceIDs: ["m-groom"]
        )
        let newEdgeID = try db.ensureSpouseEdgeForParents(
            ofSubject: "lilian",
            hypotheses: [marriage], scoredRecords: [groomRec],
            snapshot: snapshot
        )
        #expect(newEdgeID == nil, "existing spouse edge → no-op")
    }

    // MARK: - Gating

    @Test func skipsWhenNoSupportedParentMarriage() throws {
        let db = try makeTempDB()
        let lilian = makeProfile(id: "lilian", surname: "Brooks", given: "Lilian", gender: .female, birthYear: 1914)
        let father = makeProfile(id: "brooks-ghost", surname: "Brooks", given: nil, gender: .male, birthYear: nil)
        let mother = makeProfile(id: "land-ghost", surname: "Land", given: nil, gender: .female, birthYear: nil)
        try db.addFamily(
            profiles: [lilian, father, mother],
            relationships: [
                parentEdge(from: "brooks-ghost", to: "lilian", role: .father),
                parentEdge(from: "land-ghost", to: "lilian", role: .mother),
            ],
            source: .gedcom
        )
        let snapshot = try db.buildSnapshot()
        let newEdgeID = try db.ensureSpouseEdgeForParents(
            ofSubject: "lilian",
            hypotheses: [],  // no .parentMarriage
            scoredRecords: [],
            snapshot: snapshot
        )
        #expect(newEdgeID == nil)
        let after = try db.buildSnapshot()
        #expect(after.relationships.filter { $0.type == .spouse }.isEmpty)
    }

    @Test func skipsWhenOnlyOneParentLinked() throws {
        let db = try makeTempDB()
        let lilian = makeProfile(id: "lilian", surname: "Brooks", given: "Lilian", gender: .female, birthYear: 1914)
        let father = makeProfile(id: "brooks-ghost", surname: "Brooks", given: nil, gender: .male, birthYear: nil)
        try db.addFamily(
            profiles: [lilian, father],
            relationships: [
                parentEdge(from: "brooks-ghost", to: "lilian", role: .father),
            ],
            source: .gedcom
        )
        let snapshot = try db.buildSnapshot()
        let marriage = supportedParentMarriage(
            subjectID: "lilian", mother: "Land", father: "Brooks",
            evidenceIDs: []
        )
        let newEdgeID = try db.ensureSpouseEdgeForParents(
            ofSubject: "lilian",
            hypotheses: [marriage], scoredRecords: [],
            snapshot: snapshot
        )
        #expect(newEdgeID == nil, "mother not linked yet → can't create spouse edge")
    }

    @Test func skipsWhenMarriageHypothesisHasNoCitedRecords() throws {
        // Supported hypothesis but supporting_evidence is empty (or
        // unresolvable). Without a year we can't fill marriage_date,
        // so abort rather than create a malformed spouse edge.
        let db = try makeTempDB()
        let lilian = makeProfile(id: "lilian", surname: "Brooks", given: "Lilian", gender: .female, birthYear: 1914)
        let father = makeProfile(id: "brooks-ghost", surname: "Brooks", given: nil, gender: .male, birthYear: nil)
        let mother = makeProfile(id: "land-ghost", surname: "Land", given: nil, gender: .female, birthYear: nil)
        try db.addFamily(
            profiles: [lilian, father, mother],
            relationships: [
                parentEdge(from: "brooks-ghost", to: "lilian", role: .father),
                parentEdge(from: "land-ghost", to: "lilian", role: .mother),
            ],
            source: .gedcom
        )
        let snapshot = try db.buildSnapshot()
        let marriage = supportedParentMarriage(
            subjectID: "lilian", mother: "Land", father: "Brooks",
            evidenceIDs: []  // nothing to extract date from
        )
        let newEdgeID = try db.ensureSpouseEdgeForParents(
            ofSubject: "lilian",
            hypotheses: [marriage], scoredRecords: [],
            snapshot: snapshot
        )
        #expect(newEdgeID == nil)
    }
}
