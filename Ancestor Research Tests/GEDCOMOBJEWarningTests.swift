import Testing
import Foundation
@testable import Ancestor_Research

/// M16.2 — plain `.ged` documents carry OBJE references but no actual
/// media files. The parser must surface a warning so users know to
/// re-import via `.gdz` or supply the photos separately, rather than
/// silently producing a tree with broken media links.
struct GEDCOMOBJEWarningTests {

    @Test func parserCountsTopLevelOBJERecords() {
        let ged = """
0 HEAD
1 GEDC
2 VERS 7.0
1 CHAR UTF-8
0 @M1@ OBJE
1 FILE media/a.jpg
2 FORM jpg
0 @M2@ OBJE
1 FILE media/b.jpg
2 FORM jpg
0 @M3@ OBJE
1 FILE media/c.jpg
2 FORM jpg
0 @I1@ INDI
1 NAME Test /Person/
0 TRLR
"""
        let result = GEDCOMParser.parse(content: ged)
        let warning = result.warnings.first(where: { $0.contains("multimedia") })
        #expect(warning != nil, "Expected a multimedia warning")
        #expect(warning?.contains("3") == true, "Warning should mention the count 3")
    }

    @Test func parserDoesNotWarnWhenZeroOBJE() {
        let ged = """
0 HEAD
1 GEDC
2 VERS 5.5.1
2 FORM LINEAGE-LINKED
1 CHAR UTF-8
0 @I1@ INDI
1 NAME Test /Person/
1 BIRT
2 DATE 1834
0 TRLR
"""
        let result = GEDCOMParser.parse(content: ged)
        let warning = result.warnings.first(where: { $0.contains("multimedia") })
        #expect(warning == nil, "No multimedia means no warning, got: \(warning ?? "")")
    }

    @Test func parserCountsInlineOBJEReferencesAsWell() {
        // Two inline `1 OBJE @Mn@` plus zero top-level records — total 2.
        // (The dangling refs alone would trigger the warning even without
        // the corresponding records, since the count reflects what would
        // be "lost" as a plain `.ged` import.)
        let ged = """
0 HEAD
1 GEDC
2 VERS 7.0
1 CHAR UTF-8
0 @I1@ INDI
1 NAME Test /Person/
1 OBJE @M1@
1 OBJE @M2@
0 TRLR
"""
        let result = GEDCOMParser.parse(content: ged)
        let warning = result.warnings.first(where: { $0.contains("multimedia") })
        #expect(warning != nil)
        #expect(warning?.contains("2") == true)
    }
}
