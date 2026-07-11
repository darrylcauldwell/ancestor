import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-09 + T1-13 (parse level) + T1-C4
/// (CONNECTOR_AUDIT_2026-07.md §6.2/§8) — CWGC's CSV export is parsed
/// header-keyed (DictReader semantics, matching Python cwgc.py) with an
/// RFC-4180 quote-aware tokeniser. Pins:
///   * embedded newlines inside quoted fields are data, not row breaks
///   * a column reorder shifts nothing
///   * doubled quotes unescape
///   * apostrophes survive end-to-end (T1-C4)
///   * a body without the casualty header is `.notCSV`, never a clean zero
struct CWGCCSVParsingTests {

    // MARK: - Fixtures

    private static let header = "Id,Surname,Forename,Initials,AgeAtDeath,Honours,DateOfDeath,DateOfDeath2,Rank,Regiment,SecondaryRegiment,Unit,SecondaryUnit,CountryOfService,ServiceNumber,Burial,Cemetery,GraveRef,AdditionalInfo"

    private func row(
        id: String = "123456",
        surname: String = "CAULDWELL",
        forename: String = "ERNEST",
        initials: String = "E",
        age: String = "31",
        honours: String = "",
        dateOfDeath: String = "21/03/1918",
        rank: String = "Private",
        regiment: String = "Sherwood Foresters",
        countryOfService: String = "United Kingdom",
        serviceNumber: String = "'12345",
        burial: String = "France",
        cemetery: String = "Arras Memorial",
        graveRef: String = "Bay 7",
        additionalInfo: String = ""
    ) -> String {
        [id, surname, forename, initials, age, honours, dateOfDeath, "",
         rank, regiment, "", "", "", countryOfService, serviceNumber,
         burial, cemetery, graveRef, additionalInfo].joined(separator: ",")
    }

    private func military(_ record: SourceRecord) -> MilitaryRecord? {
        guard case .military(let r) = record else { return nil }
        return r
    }

    // MARK: - Canonical row (parity with the previous parser)

    @Test func canonicalRowParsesAllFields() {
        let csv = Self.header + "\n" + row()
        let records = CWGCSource.parseCSV(csv)
        #expect(records.count == 1)
        guard let record = records.first, let r = military(record) else {
            Issue.record("expected one military record")
            return
        }
        #expect(record.id == "cwgc_123456")
        #expect(record.surname == "CAULDWELL")
        #expect(record.givenName == "ERNEST")
        #expect(r.age == 31)
        #expect(r.dateOfDeath == "21 March 1918")
        #expect(r.deathYear == 1918)
        #expect(r.rank == "Private")
        #expect(r.regiment == "Sherwood Foresters")
        #expect(r.serviceNumber == "12345", "CWGC's quote wrapper is stripped")
        #expect(r.cemetery == "Arras Memorial")
        #expect(r.graveRef == "Bay 7")
        #expect(record.rawFields["initials"] == "E")
        #expect(record.rawFields["country_of_service"] == "United Kingdom")
        #expect(record.rawFields["burial_country"] == "France")
    }

    @Test func ageZeroMeansUnknown() {
        let csv = Self.header + "\n" + row(age: "0")
        guard let r = CWGCSource.parseCSV(csv).first.flatMap(military) else {
            Issue.record("expected one record")
            return
        }
        #expect(r.age == nil)
    }

    // MARK: - T1-09 — header-keyed parsing

    @Test func reorderedColumnsStillLandInTheRightFields() {
        // Swap Cemetery and GraveRef relative to the canonical order —
        // the positional parser silently wrote cemetery into graveRef.
        let reorderedHeader = "Id,Surname,Forename,Initials,AgeAtDeath,Honours,DateOfDeath,DateOfDeath2,Rank,Regiment,SecondaryRegiment,Unit,SecondaryUnit,CountryOfService,ServiceNumber,Burial,GraveRef,Cemetery,AdditionalInfo"
        let dataRow = ["123456", "CAULDWELL", "ERNEST", "E", "31", "", "21/03/1918", "",
                       "Private", "Sherwood Foresters", "", "", "", "United Kingdom", "12345",
                       "France", "Bay 7", "Arras Memorial", ""].joined(separator: ",")
        let records = CWGCSource.parseCSV(reorderedHeader + "\n" + dataRow)
        guard let r = records.first.flatMap(military) else {
            Issue.record("expected one record")
            return
        }
        #expect(r.cemetery == "Arras Memorial")
        #expect(r.graveRef == "Bay 7")
    }

    @Test func embeddedNewlineInQuotedAdditionalInfoStaysOneRecord() {
        // The positional parser split this record on the embedded
        // newline and dropped BOTH halves via its field-count guard.
        let quotedInfo = "\"Son of John Brooks,\nof Belper, Derbyshire.\""
        let csv = Self.header + "\n"
            + row(id: "111111", additionalInfo: quotedInfo) + "\n"
            + row(id: "222222")
        let records = CWGCSource.parseCSV(csv)
        #expect(records.count == 2, "embedded newline must not split or drop records")
        guard let first = records.first.flatMap(military) else {
            Issue.record("expected two records")
            return
        }
        #expect(first.additionalInfo?.contains("Son of John Brooks") == true)
        #expect(first.additionalInfo?.contains("of Belper, Derbyshire") == true)
        #expect(records.last?.id == "cwgc_222222")
    }

    @Test func doubledQuotesUnescapeToLiteralQuote() {
        let quotedInfo = "\"Known as \"\"Ernie\"\" to his family.\""
        let csv = Self.header + "\n" + row(additionalInfo: quotedInfo)
        guard let r = CWGCSource.parseCSV(csv).first.flatMap(military) else {
            Issue.record("expected one record")
            return
        }
        #expect(r.additionalInfo == "Known as \"Ernie\" to his family.")
    }

    @Test func quotedFieldWithCommaStaysOneField() {
        let quotedInfo = "\"Son of William and Mary Brooks, of Belper.\""
        let csv = Self.header + "\n" + row(additionalInfo: quotedInfo)
        guard let r = CWGCSource.parseCSV(csv).first.flatMap(military) else {
            Issue.record("expected one record")
            return
        }
        #expect(r.additionalInfo == "Son of William and Mary Brooks, of Belper.")
        #expect(r.cemetery == "Arras Memorial", "columns after the quoted field must not shift")
    }

    @Test func crlfLineEndingsParse() {
        let csv = Self.header + "\r\n" + row() + "\r\n"
        #expect(CWGCSource.parseCSV(csv).count == 1)
    }

    // MARK: - T1-C4 — apostrophes and diacritics

    @Test func apostropheInSurnameAndQuotedInfoSurvives() {
        let quotedInfo = "\"Son of Patrick O'Brien, of Cork.\""
        let csv = Self.header + "\n" + row(surname: "O'BRIEN", forename: "PATRICK", serviceNumber: "9876", additionalInfo: quotedInfo)
        let records = CWGCSource.parseCSV(csv)
        guard let record = records.first, let r = military(record) else {
            Issue.record("expected one record")
            return
        }
        #expect(record.surname == "O'BRIEN")
        #expect(record.name == "PATRICK O'BRIEN")
        #expect(r.additionalInfo == "Son of Patrick O'Brien, of Cork.")
    }

    @Test func diacriticsSurvive() {
        let csv = Self.header + "\n" + row(surname: "MÜLLER", forename: "KARL")
        #expect(CWGCSource.parseCSV(csv).first?.surname == "MÜLLER")
    }

    // MARK: - T1-13 — header sanity check

    @Test func htmlBodyIsNotCSV() {
        let html = "<!DOCTYPE html><html><head><title>Maintenance</title></head><body>Back soon.</body></html>"
        guard case .notCSV(let reason) = CWGCSource.parseExport(html) else {
            Issue.record("an HTML body must not parse as a genuine zero")
            return
        }
        #expect(reason.lowercased().contains("not the casualty csv") || reason.lowercased().contains("empty"))
    }

    @Test func emptyBodyIsNotCSV() {
        guard case .notCSV = CWGCSource.parseExport("") else {
            Issue.record("an empty body must not parse as a genuine zero")
            return
        }
    }

    @Test func headerOnlyExportIsAValidZero() {
        guard case .casualties(let records) = CWGCSource.parseExport(Self.header + "\n") else {
            Issue.record("a header-only export is CWGC's genuine empty answer")
            return
        }
        #expect(records.isEmpty)
    }

    @Test func missingRequiredColumnIsNotCSV() {
        // A header row that exists but lacks Id/Surname is some other
        // document wearing commas.
        let bogus = "Title,Description,Link\nSomething,Else,https://example.org"
        guard case .notCSV = CWGCSource.parseExport(bogus) else {
            Issue.record("missing required headers must fail loudly")
            return
        }
    }

    @Test func legacyParseCSVWrapperReturnsEmptyForInvalidBody() {
        #expect(CWGCSource.parseCSV("<html></html>").isEmpty)
    }
}

/// Connector-audit T1-10 — deterministic structured parse of the
/// next-of-kin line. No LLM: the format is highly regular.
struct CWGCNextOfKinParserTests {

    @Test func canonicalTwoParentLineWithSpouse() {
        let parsed = CWGCNextOfKin.parse(
            "Son of John and Mary Cauldwell, of 5 Mill St., Belper; husband of Sarah Ann Cauldwell, of 12 Chapel St., Derby."
        )
        #expect(parsed?.parents == ["John Cauldwell", "Mary Cauldwell"])
        #expect(parsed?.spouseName == "Sarah Ann Cauldwell")
        #expect(parsed?.residence == "5 Mill St., Belper",
                "the parents clause's place is the next-of-kin residence")
    }

    @Test func sharedSurnameExpandsToBothParents() {
        let parsed = CWGCNextOfKin.parse("Son of William and Jane Brooks, of Turnditch.")
        #expect(parsed?.parents == ["William Brooks", "Jane Brooks"])
    }

    @Test func fullyNamedParentsAreKeptVerbatim() {
        let parsed = CWGCNextOfKin.parse("Daughter of Thomas Ward and Emma Land, of Heage.")
        #expect(parsed?.parents == ["Thomas Ward", "Emma Land"])
    }

    @Test func singleParentParses() {
        let parsed = CWGCNextOfKin.parse("Son of William Brooks, of Turnditch, Derby.")
        #expect(parsed?.parents == ["William Brooks"])
        #expect(parsed?.residence == "Turnditch, Derby")
    }

    @Test func theLatePrefixIsStripped() {
        let parsed = CWGCNextOfKin.parse("Son of the late John Cauldwell and Mary Cauldwell, of Belper.")
        #expect(parsed?.parents == ["John Cauldwell", "Mary Cauldwell"])
    }

    @Test func wifeOfClauseYieldsSpouse() {
        let parsed = CWGCNextOfKin.parse("Wife of George Herbert Brooks, of Belper.")
        #expect(parsed?.spouseName == "George Herbert Brooks")
        #expect(parsed?.parents.isEmpty == true)
        #expect(parsed?.residence == "Belper",
                "spouse clause's place is the residence fallback")
    }

    @Test func nativeOfClauseYieldsResidence() {
        let parsed = CWGCNextOfKin.parse("Native of Wirksworth, Derbyshire.")
        #expect(parsed?.residence == "Wirksworth, Derbyshire")
    }

    @Test func spousePlaceUsedOnlyWhenParentsClauseHasNone() {
        let parsed = CWGCNextOfKin.parse("Son of John and Mary Cauldwell; husband of Sarah Cauldwell, of Ripley.")
        #expect(parsed?.parents == ["John Cauldwell", "Mary Cauldwell"])
        #expect(parsed?.residence == "Ripley")
    }

    @Test func apostrophesInNamesSurvive() {
        let parsed = CWGCNextOfKin.parse("Son of Patrick O'Brien, of Cork.")
        #expect(parsed?.parents == ["Patrick O'Brien"])
        #expect(parsed?.residence == "Cork")
    }

    @Test func unstructuredTextReturnsNil() {
        #expect(CWGCNextOfKin.parse("Awarded the Military Medal for gallantry.") == nil)
        #expect(CWGCNextOfKin.parse("") == nil)
        #expect(CWGCNextOfKin.parse("   ") == nil)
    }
}
