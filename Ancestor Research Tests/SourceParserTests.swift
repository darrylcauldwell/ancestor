import Testing
import Foundation
@testable import Ancestor_Research

/// Fixture-based source parser tests — validate Swift parsers produce correct output.
/// Tests parsing logic independently of HTTP, using hardcoded fixture strings.
struct SourceParserTests {

    // MARK: - Record Scorer (as a parser-level test)

    @Test func scorerClassifiesMatchingBirthAsFact() {
        let subject = ResearchSubject(
            surname: "LAND", givenName: "THOMAS",
            birthYearFrom: 1834, birthYearTo: 1834,
            gender: .male, region: .englandAndWales, mode: .extend, familyContext: nil
        )
        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "t", sourceID: "freebmd", name: nil,
                surname: "LAND", givenName: "THOMAS", detailURL: nil, rawFields: [:]),
            birthYear: 1834, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject, searchType: .birth)
        #expect(result.verdict == .fact)
    }

    @Test func scorerClassifiesMismatchAsImpossible() {
        let subject = ResearchSubject(
            surname: "LAND", givenName: "THOMAS",
            birthYearFrom: 1834, birthYearTo: 1834,
            gender: .male, region: .englandAndWales, mode: .extend, familyContext: nil
        )
        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "t", sourceID: "freebmd", name: nil,
                surname: "SMITH", givenName: "JAMES", detailURL: nil, rawFields: [:]),
            birthYear: 1834, birthDate: nil, birthPlace: nil,
            quarter: nil, district: nil, volume: nil, page: nil, mothersMaidenName: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject, searchType: .birth)
        #expect(result.verdict == .impossible)
    }

    // MARK: - Probate JSON Parsing

    @Test func probateParseJSONExtractsFields() {
        let json: [String: Any] = [
            "entries": [
                [
                    "uid": "test-uid-1",
                    "properties": [
                        "hmctsgrant:surname": "CAULDWELL",
                        "hmctsgrant:firstnames": "JOHN",
                        "hmctsgrant:dateofdeath": "2005-03-15T00:00:00.000Z",
                        "hmctsgrant:dateofprobate": "2005-06-01T00:00:00.000Z",
                        "hmctsgrant:grantdocTypeoOfName": "PROBATE",
                        "hmctsgrant:registryofficename": "Derby",
                    ] as [String: Any]
                ] as [String: Any]
            ] as [[String: Any]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let records = ProbateSource.parseJSON(data, surname: "CAULDWELL")
        #expect(records.count == 1)

        if case .probate(let r) = records.first {
            #expect(r.common.surname == "CAULDWELL")
            #expect(r.deathDate == "2005-03-15")
            #expect(r.grantType == "PROBATE")
            #expect(r.registry == "Derby")
        } else {
            Issue.record("Expected probate record")
        }
    }

    // MARK: - Wirksworth Pedigree Parsing

    @Test func wirksworthParsesStructuredPedigree() {
        let html = """
        <PRE>
        1 John Cauldwell bpt (15/7/1707) m (1730) Mary Smith d 1780
        2 Thomas Cauldwell b 1732 m Elizabeth Jones
        </PRE>
        """
        let records = WirksworthSource.parseStructuredPedigree(html, surname: "Cauldwell", url: "http://test")
        #expect(records.count == 2)

        if case .pedigree(let r) = records.first {
            #expect(r.birthYear == 1707)
            #expect(r.generation == 1)
        }
    }

    @Test func wirksworthParsesNarrativePedigree() {
        let html = "Nathaniel Caldwell born 1815 in Wirksworth was a lead miner."
        let records = WirksworthSource.parseNarrativePedigree(html, surname: "Caldwell", url: "http://test")
        #expect(records.count == 1)
        if case .pedigree(let r) = records.first {
            #expect(r.birthYear == 1815)
        }
    }

    // MARK: - FreeREG HTML Parsing

    @Test func freeregParsesTableResults() {
        let html = """
        <table>
        <tr><th>Name</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
        <tr><td>Thomas Land</td><td>1834</td><td>Wirksworth</td><td>Derbyshire</td><td>Baptism</td></tr>
        <tr><td>Mary Land</td><td>1836</td><td>Wirksworth</td><td>Derbyshire</td><td>Baptism</td></tr>
        </table>
        """
        let records = FreeREGSource.parseResults(html, recordType: .baptism)
        #expect(records.count == 2)

        if case .parish(let r) = records.first {
            #expect(r.parish == "Wirksworth")
            #expect(r.eventYear == 1834)
        }
    }

    @Test func freeregEmptyTableReturnsEmpty() {
        let html = "<table><tr><th>Name</th></tr></table>"
        let records = FreeREGSource.parseResults(html, recordType: .baptism)
        #expect(records.isEmpty)
    }
}
