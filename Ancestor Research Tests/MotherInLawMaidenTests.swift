import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `ResearchPipeline.maidenNameFromMotherInLaw` — the
/// helper behind the post-iteration mother-in-law maiden-name
/// pivot. Mirrors `agent/rules.py:maiden_name_from_mother_in_law`.
///
/// Background: a census enumerator recording a mother-in-law in
/// the household wrote her under her own surname. By convention
/// that surname IS the wife's maiden name — a separate signal from
/// the dispatcher's linked-father derivation.
@MainActor
struct MotherInLawMaidenTests {

    private func member(
        name: String, relationship: String
    ) -> HouseholdMember {
        HouseholdMember(
            name: name, relationship: relationship,
            age: nil, birthYear: nil, birthPlace: nil,
            occupation: nil, sex: nil
        )
    }

    @Test func motherInLawWithDifferentSurnameYieldsMaidenName() {
        let household = [
            member(name: "John Cauldwell", relationship: "Head"),
            member(name: "Mary Cauldwell", relationship: "Wife"),
            member(name: "Ann Holmes", relationship: "Mother-in-law"),
        ]
        let maiden = ResearchPipeline.maidenNameFromMotherInLaw(
            household: household, headSurname: "Cauldwell"
        )
        #expect(maiden == "Holmes")
    }

    @Test func motherInLawWithSameSurnameAsHeadYieldsNil() {
        // Same surname → not a new signal (or the rare cousin-
        // marriage case where wife was already Cauldwell). Suppress.
        let household = [
            member(name: "John Cauldwell", relationship: "Head"),
            member(name: "Ann Cauldwell", relationship: "Mother-in-law"),
        ]
        let maiden = ResearchPipeline.maidenNameFromMotherInLaw(
            household: household, headSurname: "Cauldwell"
        )
        #expect(maiden == nil)
    }

    @Test func detectsMotherInLawDespiteFormattingVariants() {
        // Python check is substring-based: `"mother" in rel and
        // "law" in rel`. Detects any spelling that carries both
        // "mother" and "law" as substrings. Abbreviated census
        // forms like "Mo-Law" miss because they don't contain the
        // full word "mother" — those need pre-normalisation that
        // neither Python nor this port implements today.
        let cases = [
            "Mother In Law", "Mother-in-Law", "MotherInLaw", "mother_in_law"
        ]
        for rel in cases {
            let household = [
                member(name: "John Cauldwell", relationship: "Head"),
                member(name: "Ann Holmes", relationship: rel),
            ]
            let maiden = ResearchPipeline.maidenNameFromMotherInLaw(
                household: household, headSurname: "Cauldwell"
            )
            #expect(maiden == "Holmes", "Should detect '\(rel)' as mother-in-law")
        }
    }

    @Test func notFiredForOtherInLawRelationships() {
        // Father-in-law, sister-in-law are not the same signal —
        // they're not the wife's mother. Suppress.
        let household = [
            member(name: "John Cauldwell", relationship: "Head"),
            member(name: "George Holmes", relationship: "Father-in-Law"),
        ]
        #expect(ResearchPipeline.maidenNameFromMotherInLaw(
            household: household, headSurname: "Cauldwell") == nil)

        let household2 = [
            member(name: "John Cauldwell", relationship: "Head"),
            member(name: "Mary Smith", relationship: "Sister-in-Law"),
        ]
        #expect(ResearchPipeline.maidenNameFromMotherInLaw(
            household: household2, headSurname: "Cauldwell") == nil)
    }

    @Test func emptyHouseholdYieldsNil() {
        #expect(ResearchPipeline.maidenNameFromMotherInLaw(
            household: [], headSurname: "Cauldwell") == nil)
    }

    @Test func caseInsensitiveSurnameComparison() {
        // "cauldwell" (lowercase) vs "CAULDWELL" (uppercase) shouldn't
        // be treated as different surnames — defensively normalise.
        let household = [
            member(name: "John CAULDWELL", relationship: "Head"),
            member(name: "Ann cauldwell", relationship: "Mother-in-Law"),
        ]
        #expect(ResearchPipeline.maidenNameFromMotherInLaw(
            household: household, headSurname: "Cauldwell") == nil)
    }
}
