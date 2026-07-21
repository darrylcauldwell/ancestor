import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// FamilySearch client — Slice B (S6b). The scorer-routing helper + the
/// load-bearing §18 invariant: the FS match confidence must be inert to the
/// deterministic scorer.
@MainActor
struct FamilySearchHintRoutingTests {

    private func subject() -> ResearchSubject {
        ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "Ernest",
            birthYearFrom: 1887, birthYearTo: 1887, deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .extend,
            familyContext: FamilyContext(
                spouseName: nil, spouseSurname: nil, spouseGivenName: nil, spouseFatherSurname: nil,
                childNames: [], fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil),
            homeChapmanCode: "DBY")
    }

    private func fsBirthRecord(id: String, fsScore: String?) -> SourceRecord {
        var raw: [String: String] = [:]
        if let fsScore { raw["fsMatchScore"] = fsScore }
        let common = RecordCommon(
            id: id, sourceID: "familysearch",
            name: "Ernest Cauldwell", surname: "Cauldwell", givenName: "Ernest",
            detailURL: nil, rawFields: raw)
        return .birth(BirthRecord(common: common, birthYear: 1887, birthPlace: "Derbyshire, England"))
    }

    @Test func fsMatchScoreIsInertToTheScorer() {
        // Two records identical except fsMatchScore → identical verdict + gates.
        let s = subject()
        let withScore = RecordScorer.classify(record: fsBirthRecord(id: "a", fsScore: "9.9"), subject: s, searchType: .birth)
        let without = RecordScorer.classify(record: fsBirthRecord(id: "a", fsScore: nil), subject: s, searchType: .birth)
        #expect(withScore.verdict == without.verdict)
        #expect(withScore.gates.map(\.outcome) == without.gates.map(\.outcome))
    }

    @Test func routeScoresBucketsAndTagsEnrichment() {
        let result = FamilySearchHintRouting.route(records: [fsBirthRecord(id: "a", fsScore: "9")], subject: subject())
        #expect(result.allScoredRecords.count == 1)
        #expect(result.enrichmentRecordIDs == ["a"])
        // Exactly one bucket (fact | lead | impossible) holds the record.
        let impossible = result.allScoredRecords.filter { $0.verdict == .impossible }.count
        #expect(result.confirmedFacts.count + result.leads.count + impossible == 1)
    }
}
