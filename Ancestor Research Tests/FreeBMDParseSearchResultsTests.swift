import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the FreeBMD sparse-encoding decode behaviour for `parseSearchResults`.
///
/// FreeBMD's `var searchData = new Array(...)` payload uses document-global
/// sparse encoding for the surname / district / volume columns — only the
/// first row in a same-(surname, district, vol) group has those columns
/// populated; subsequent rows leave them blank as "same as previous".
///
/// Before the carry-forward fix, every record after the first in a group
/// landed with empty district + vol and was silently dropped by the
/// scorer's geography gate. Surfaced by Mabel Cauldwell's Mar 1897
/// Belper vol7b p615 birth (the canonical eval-corpus G5-cluster case),
/// originally diagnosed and fixed in Python `sources/freebmd.py` commit
/// `e7a005e`, then ported here.
///
/// The Python investigation observed this raw payload from a live
/// `Births / Cauldwell / Belper / 1895–1899` search — used as the test
/// fixture below verbatim.
nonisolated struct FreeBMDParseSearchResultsTests {

    /// Anchor row 0 has Cauldwell / Belper / 7b populated. Rows 1, 2, 3
    /// leave all three blank — they must inherit from row 0.
    private static let sparseEncodedPayload: String = """
    <html>
    <head><title>FreeBMD Search Results</title></head>
    <body>
    <script>
    var searchData = new Array (
      " ;0;2;1895",
      "41;Cauldwell;Bella%20Smedley;;0;Belper;7b;637;93718736:1036",
      " ;0;2;1896",
      "40;;Jack; ;;;;630;95638779:1008",
      " ;0;1;1897",
      "41;;Mabel; ;;;;615;97138920:6808",
      " ;0;4;1899",
      "40;;Wilfred; ;;;;611;102677237:7265"
    );
    </script>
    </body>
    </html>
    """

    @Test func percentEncodedDistrictAndSurnameColumnsDecode() {
        // Owner screenshot 2026-07-15: 'Chapel%20le%20F.' leaked into the
        // proposed-relative card and its persisted citation — the district
        // (and surname) columns were never percent-decoded, unlike the
        // name columns.
        let payload = """
        <html><body><script>
        var searchData = new Array (
          " ;0;2;1913",
          "41;Marshall;HARRY;Howard;0;Chapel%20le%20F.;7b;177;114000001:1036",
          "41;O%27Brien;Mary;;0;Belper;7b;620;114000002:1036"
        );
        </script></body></html>
        """
        let records = FreeBMDSource.parseSearchResults(
            payload, recordType: .birth, querySurname: "Marshall")
        #expect(records.count == 2)
        guard case let .birth(harry) = records[0], case let .birth(mary) = records[1] else {
            Issue.record("expected two birth records"); return
        }
        #expect(harry.district == "Chapel le F.",
                "district must be percent-decoded; got \(harry.district ?? "nil")")
        #expect(mary.common.surname == "O'Brien",
                "surname must be percent-decoded; got \(mary.common.surname ?? "nil")")
    }

    @Test func carriesSurnameDistrictAndVolForwardAcrossSparseRows() {
        let records = FreeBMDSource.parseSearchResults(
            Self.sparseEncodedPayload,
            recordType: .birth,
            querySurname: "Cauldwell"
        )

        #expect(records.count == 4)

        // Pull district + vol via the common.rawFields dict each record
        // carries — this is the exact path the scorer's geography gate
        // and the citation matcher use, so it's the right thing to pin.
        typealias Row = (name: String, surname: String, district: String, vol: String)
        let extracted: [Row] = records.compactMap { (record: SourceRecord) -> Row? in
            guard case let .birth(b) = record else { return nil }
            return (
                name: b.common.givenName ?? "",
                surname: b.common.surname ?? "",
                district: b.common.rawFields["district"] ?? "",
                vol: b.common.rawFields["vol"] ?? ""
            )
        }

        #expect(extracted.count == 4)

        // Row 0 — anchor.
        #expect(extracted[0].name == "Bella Smedley")
        #expect(extracted[0].surname == "Cauldwell")
        #expect(extracted[0].district == "Belper")
        #expect(extracted[0].vol == "7b")

        // Rows 1–3 — sparse-encoded, must inherit from row 0.
        for i in 1...3 {
            #expect(extracted[i].surname == "Cauldwell",
                    "row \(i) (\(extracted[i].name)) lost surname carry-forward")
            #expect(extracted[i].district == "Belper",
                    "row \(i) (\(extracted[i].name)) lost district carry-forward")
            #expect(extracted[i].vol == "7b",
                    "row \(i) (\(extracted[i].name)) lost vol carry-forward")
        }
    }

    /// Separator rows should update year/quarter (each data row reports
    /// the year/quarter of the most recent separator) without resetting
    /// the carried surname/district/vol. This is the case the early
    /// version of the Python fix got wrong: resetting on every separator
    /// undid the carry-forward immediately. See pipeline.py history for
    /// the documented misstep.
    @Test func separatorRowsDoNotResetSurnameDistrictOrVol() {
        let records = FreeBMDSource.parseSearchResults(
            Self.sparseEncodedPayload,
            recordType: .birth,
            querySurname: "Cauldwell"
        )

        // The fixture has FOUR separator rows interleaved with FOUR data
        // rows. If separators reset, rows 1-3 would have empty district.
        let districts: [String] = records.compactMap { (record: SourceRecord) -> String? in
            guard case let .birth(b) = record else { return nil }
            return b.common.rawFields["district"]
        }
        #expect(districts == ["Belper", "Belper", "Belper", "Belper"])
    }

    /// The querySurname fallback is the belt — not the braces. It only
    /// fires when carry-forward has nothing to carry (no populated row
    /// yet). With the new carry-forward in place, the fallback is a
    /// safety net for malformed pages, not the primary path.
    @Test func querySurnameFallbackFiresWhenFirstRowAlsoBlank() {
        let firstRowBlank: String = """
        var searchData = new Array (
          " ;0;2;1897",
          "41;;Mabel; ;;Belper;7b;615;97138920:6808"
        );
        """

        let records = FreeBMDSource.parseSearchResults(
            firstRowBlank,
            recordType: .birth,
            querySurname: "Cauldwell"
        )

        #expect(records.count == 1)
        guard case let .birth(b) = records[0] else {
            Issue.record("expected birth record")
            return
        }
        #expect((b.common.surname ?? "") == "Cauldwell")  // from querySurname fallback
        #expect(b.common.rawFields["district"] == "Belper")
        #expect(b.common.rawFields["vol"] == "7b")
    }

    // MARK: - Detail link + mother's maiden name (real FreeBMD HAR fixture)

    /// The exact `search.pl` payload FreeBMD returned for a
    /// `Births / Beresford / Chesterfield / 1920` search (captured HAR
    /// 2026-07-28): the per-search `var dbId` and one post-1911 birth row whose
    /// 4th column carries the mother's maiden name and whose 9th column carries
    /// the full `<recordID>:<scanID>` reference.
    private static let beresfordBirthPayload = """
    <html><body><script>
    var dbId = "bmd_1784770807";
    var searchData = new Array (
      " ;0;1;1920",
      "41;Beresford;Norah;Lees;0;Chesterfield;7b;1902;143220917:8511"
    );
    </script></body></html>
    """

    @Test func birthCapturesMothersMaidenName() {
        let records = FreeBMDSource.parseSearchResults(
            Self.beresfordBirthPayload, recordType: .birth, querySurname: "Beresford")
        #expect(records.count == 1)
        guard case let .birth(b) = records[0] else { Issue.record("expected birth"); return }
        #expect(b.mothersMaidenName == "Lees")
    }

    /// information.pl?r=<full recordRef incl scan suffix>&d=<dbId>, built exactly
    /// as FreeBMD's own results JS does. The full "143220917:8511" ref must
    /// survive — a bare pre-colon recordID 403s (verified against live FreeBMD).
    @Test func birthBuildsPermanentDetailURLFromRefAndDbId() {
        let records = FreeBMDSource.parseSearchResults(
            Self.beresfordBirthPayload, recordType: .birth, querySurname: "Beresford")
        guard case let .birth(b) = records[0] else { Issue.record("expected birth"); return }
        #expect(b.common.detailURL ==
                "https://www.freebmd.org.uk/cgi/information.pl?r=143220917:8511&d=bmd_1784770807")
    }

    /// No `dbId` on the page → no link half → detailURL stays nil (graceful),
    /// never a malformed `d=` URL.
    @Test func detailURLNilWhenPageHasNoDbId() {
        let noDbId = """
        <html><body><script>
        var searchData = new Array (
          " ;0;1;1920",
          "41;Beresford;Norah;Lees;0;Chesterfield;7b;1902;143220917:8511"
        );
        </script></body></html>
        """
        let records = FreeBMDSource.parseSearchResults(
            noDbId, recordType: .birth, querySurname: "Beresford")
        guard case let .birth(b) = records[0] else { Issue.record("expected birth"); return }
        #expect(b.common.detailURL == nil)
    }

    /// The link lives on RecordCommon, so every record type gets it — this is
    /// the universal citation-link fix, not a births-only one.
    @Test func marriageAlsoGetsDetailURL() {
        let payload = """
        <html><body><script>
        var dbId = "bmd_1784770807";
        var searchData = new Array (
          " ;0;4;1947",
          "41;Beresford;Norah;Rose;0;Chesterfield;3a;88;196270216:1"
        );
        </script></body></html>
        """
        let records = FreeBMDSource.parseSearchResults(
            payload, recordType: .marriage, querySurname: "Beresford")
        guard case let .marriage(m) = records[0] else { Issue.record("expected marriage"); return }
        #expect(m.common.detailURL ==
                "https://www.freebmd.org.uk/cgi/information.pl?r=196270216:1&d=bmd_1784770807")
        #expect(m.spouseName == "Rose")
    }
}
