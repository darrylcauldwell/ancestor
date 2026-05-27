import Testing
import Foundation
@testable import FieldResearcherMCP

/// Pure-helper tests for the auto-approval gate. The decision pipeline
/// (`evaluateApproval` / `commitPendingFact`) requires a live SQLite —
/// integration tests for those land in a follow-up. These cover the
/// regex / parsing / comparison logic that's most prone to silently
/// going wrong.
///
/// Reference: AncestorApp/AUTO_APPROVAL_VIA_MCP_SPEC.md.
struct AutoApprovalHelpersTests {

    // MARK: extractYear

    @Test func extractYearFromBareYear() {
        #expect(MCPHandler.extractYear(from: "1820") == 1820)
    }

    @Test func extractYearFromFullDate() {
        #expect(MCPHandler.extractYear(from: "21 Dec 1820") == 1820)
    }

    @Test func extractYearFromYearMonth() {
        #expect(MCPHandler.extractYear(from: "March 1820") == 1820)
    }

    @Test func extractYearFromCirca() {
        #expect(MCPHandler.extractYear(from: "circa 1820") == 1820)
    }

    @Test func extractYearReturnsFirstWhenMultiple() {
        // For ranges like "1820-1825", first year wins. Bias is acceptable
        // for the comparison use; the call sites don't depend on
        // disambiguation here.
        #expect(MCPHandler.extractYear(from: "1820-1825") == 1820)
    }

    @Test func extractYearRefusesTwoDigitYear() {
        #expect(MCPHandler.extractYear(from: "20") == nil)
    }

    @Test func extractYearRefusesNoDigits() {
        #expect(MCPHandler.extractYear(from: "December") == nil)
    }

    @Test func extractYearAccepts21stCentury() {
        #expect(MCPHandler.extractYear(from: "2008") == 2008)
    }

    @Test func extractYearRefuses22ndCentury() {
        // Regex caps at 20[0-9]{2} = 2099. A 2100 entry is almost certainly
        // not a real birth/death year for a genealogy app.
        #expect(MCPHandler.extractYear(from: "2100") == nil)
    }

    // MARK: extractValueFromRaw

    @Test func extractValueFromRawWithSourceTitle() {
        #expect(MCPHandler.extractValueFromRaw("1820 [FreeBMD GRO]") == "1820")
    }

    @Test func extractValueFromRawWithoutBracket() {
        #expect(MCPHandler.extractValueFromRaw("Cromford, Derbyshire") == "Cromford, Derbyshire")
    }

    @Test func extractValueFromRawTrimsWhitespace() {
        #expect(MCPHandler.extractValueFromRaw("  1820  [src]") == "1820")
    }

    // MARK: lineageLabelFromRaw

    @Test func lineageLabelFromRawExtractsTitle() {
        #expect(MCPHandler.lineageLabelFromRaw("1820 [FreeBMD GRO]") == "freebmd gro")
    }

    @Test func lineageLabelFromRawNilWhenNoBracket() {
        #expect(MCPHandler.lineageLabelFromRaw("1820") == nil)
    }

    @Test func lineageLabelFromRawNilWhenEmpty() {
        #expect(MCPHandler.lineageLabelFromRaw("1820 []") == nil)
    }

    @Test func lineageLabelFromRawCaseInsensitive() {
        // Lowercased so "FreeBMD" and "freebmd" count as the same lineage.
        // Conservative: a label that differs only in case is the same
        // source, not two independent ones.
        let a = MCPHandler.lineageLabelFromRaw("1820 [FreeBMD]")
        let b = MCPHandler.lineageLabelFromRaw("1820 [freebmd]")
        #expect(a == b)
    }

    // MARK: valuesMatch

    @Test func valuesMatchExactString() {
        #expect(MCPHandler.valuesMatch("Cromford", "Cromford", field: "birthLocation"))
    }

    @Test func valuesMatchCaseInsensitive() {
        #expect(MCPHandler.valuesMatch("CROMFORD", "cromford", field: "birthLocation"))
    }

    @Test func valuesMatchWhitespaceTolerant() {
        #expect(MCPHandler.valuesMatch("  1820  ", "1820", field: "birthDate"))
    }

    @Test func valuesMatchDateAcrossFormats() {
        #expect(MCPHandler.valuesMatch("21 Dec 1820", "December 21, 1820", field: "birthDate"))
    }

    @Test func valuesMatchDateByYear() {
        #expect(MCPHandler.valuesMatch("1820", "circa 1820", field: "birthDate"))
    }

    @Test func valuesMismatchDifferentYears() {
        #expect(!MCPHandler.valuesMatch("1820", "1822", field: "birthDate"))
    }

    @Test func valuesMismatchDifferentLocations() {
        #expect(!MCPHandler.valuesMatch("Cromford", "Wirksworth", field: "birthLocation"))
    }

    @Test func valuesMismatchPartialLocation() {
        // "Derbyshire" alone is treated as conflicting with "Cromford,
        // Derbyshire" — the spec is conservative on broader/narrower
        // place values (humans should decide whether to upgrade).
        #expect(!MCPHandler.valuesMatch("Derbyshire", "Cromford, Derbyshire", field: "birthLocation"))
    }

    // MARK: urlHost

    @Test func urlHostFromHttps() {
        #expect(MCPHandler.urlHost("https://www.freebmd.org.uk/cgi/search.pl") == "www.freebmd.org.uk")
    }

    @Test func urlHostLowercased() {
        #expect(MCPHandler.urlHost("https://WWW.FreeBMD.org.uk/") == "www.freebmd.org.uk")
    }

    @Test func urlHostNilFromMalformed() {
        #expect(MCPHandler.urlHost("not a url") == nil)
    }

    // MARK: profileFieldFor / profileColumnFor

    @Test func profileFieldForBirthDateUnchanged() {
        #expect(MCPHandler.profileFieldFor(factKind: "birthDate") == "birthDate")
    }

    @Test func profileFieldForBaptismRollsUpToBirth() {
        // Baptism dates land in the birthDate field — mirrors the app's
        // PendingFactsReviewView.addFieldSource mapping.
        #expect(MCPHandler.profileFieldFor(factKind: "baptismDate") == "birthDate")
    }

    @Test func profileFieldForBurialRollsUpToDeath() {
        #expect(MCPHandler.profileFieldFor(factKind: "burialDate") == "deathDate")
    }

    @Test func profileColumnForBirthDateHasDatePrefix() {
        let (column, prefix) = MCPHandler.profileColumnFor(factKind: "birthDate")
        #expect(column == "birth_date_original")
        #expect(prefix == "birth_date")
    }

    @Test func profileColumnForLocationHasNoDatePrefix() {
        let (column, prefix) = MCPHandler.profileColumnFor(factKind: "birthLocation")
        #expect(column == "birth_location")
        #expect(prefix == "")
    }

    @Test func profileColumnForOccupationHasNoColumn() {
        // Narrative fields (no scalar column) — auto-approval still
        // writes a field_sources row, just no profiles UPDATE.
        let (column, prefix) = MCPHandler.profileColumnFor(factKind: "occupation")
        #expect(column == nil)
        #expect(prefix == "")
    }

    // MARK: autoApprovableFields set

    @Test func autoApprovableSetExcludesNames() {
        #expect(!MCPHandler.autoApprovableFields.contains("firstName"))
        #expect(!MCPHandler.autoApprovableFields.contains("lastName"))
        #expect(!MCPHandler.autoApprovableFields.contains("middleName"))
    }

    @Test func autoApprovableSetExcludesGender() {
        #expect(!MCPHandler.autoApprovableFields.contains("gender"))
    }

    @Test func autoApprovableSetExcludesBio() {
        // Bio is narrative; never goes through this pipeline.
        #expect(!MCPHandler.autoApprovableFields.contains("bio"))
    }

    @Test func autoApprovableSetIncludesDatesAndPlaces() {
        #expect(MCPHandler.autoApprovableFields.contains("birthDate"))
        #expect(MCPHandler.autoApprovableFields.contains("deathDate"))
        #expect(MCPHandler.autoApprovableFields.contains("birthLocation"))
        #expect(MCPHandler.autoApprovableFields.contains("deathLocation"))
        #expect(MCPHandler.autoApprovableFields.contains("marriageDate"))
        #expect(MCPHandler.autoApprovableFields.contains("marriageLocation"))
    }

    // MARK: trustedHosts set

    @Test func trustedHostsIncludesFreeBMD() {
        #expect(MCPHandler.trustedHosts.contains("www.freebmd.org.uk"))
    }

    @Test func trustedHostsExcludesUnknown() {
        #expect(!MCPHandler.trustedHosts.contains("randomblog.example.com"))
    }

    // MARK: - §14.3.4 carve-out (Q5 — RESEARCH_PIPELINE_SPEC §5.14.5)

    @Test func carveOut_positivePathQualifies() {
        // All four §14.3.4 carve-out conditions satisfied — predicate
        // returns true. The live evaluator will then bypass the
        // autoApprovableFields check and the convergence-≥2 check.
        #expect(MCPHandler.isSubjectSpouseMarriageCarveOut(
            factKind: "firstName",
            agentID: "subject-spouse-marriage",
            existingFirstName: nil
        ))
        #expect(MCPHandler.isSubjectSpouseMarriageCarveOut(
            factKind: "firstName",
            agentID: "subject-spouse-marriage",
            existingFirstName: ""
        ))
        #expect(MCPHandler.isSubjectSpouseMarriageCarveOut(
            factKind: "firstName",
            agentID: "subject-spouse-marriage",
            existingFirstName: "  "    // whitespace-only treated as empty
        ))
    }

    @Test func carveOut_failsOnWrongFactKind() {
        #expect(!MCPHandler.isSubjectSpouseMarriageCarveOut(
            factKind: "lastName",
            agentID: "subject-spouse-marriage",
            existingFirstName: nil
        ), "carve-out is narrow to firstName recoveries; lastName must go through standard gate")
    }

    @Test func carveOut_failsOnWrongAgent() {
        // Pre-empts a future agent attempting to leverage the carve-out
        // by writing firstName facts.
        #expect(!MCPHandler.isSubjectSpouseMarriageCarveOut(
            factKind: "firstName",
            agentID: "field-researcher",
            existingFirstName: nil
        ))
        #expect(!MCPHandler.isSubjectSpouseMarriageCarveOut(
            factKind: "firstName",
            agentID: "prose-extractor:findagrave",
            existingFirstName: nil
        ))
    }

    @Test func carveOut_failsWhenProfileFirstNameAlreadySet() {
        // Recovery vs correction — §14.3.4 (iv). If the profile
        // already has a firstName, this would be a CORRECTION
        // (identity-shaping write that needs human review), not a
        // recovery, so the carve-out doesn't apply.
        #expect(!MCPHandler.isSubjectSpouseMarriageCarveOut(
            factKind: "firstName",
            agentID: "subject-spouse-marriage",
            existingFirstName: "Robert"
        ))
    }
}
