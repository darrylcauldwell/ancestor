import Testing
@testable import Ancestor_Research

/// Nickname equivalence in the name gate — owner case 2026-07-15: Elsie
/// Twyford was known as Betty; her registered form could be Elsie,
/// Elizabeth, or appear as Betty on a memorial. All three must score as
/// the same person, and two diminutives of one formal name must match
/// each other (the flat pair table can't express transitivity — the
/// shared-canonical clause can).
struct NicknameEquivalenceTests {

    @Test func elsieMatchesElizabeth() {
        #expect(ScoringRules.nameSimilarity("ELSIE", "ELIZABETH") >= 0.85)
        #expect(ScoringRules.nameSimilarity("ELIZABETH", "ELSIE") >= 0.85)
    }

    @Test func sharedCanonicalMatchesDiminutivesToEachOther() {
        #expect(ScoringRules.nameSimilarity("ELSIE", "BETTY") >= 0.85,
                "both are Elizabeth diminutives — a Betty-inscribed memorial must match an Elsie subject")
        #expect(ScoringRules.nameSimilarity("LIZZIE", "BETTY") >= 0.85)
        #expect(ScoringRules.nameSimilarity("WILLIE", "BILL") >= 0.85)
        // NELLIE/NELL resolves via the earlier prefix rule at 0.8 —
        // still a match, just a different clause.
        #expect(ScoringRules.nameSimilarity("NELLIE", "NELL") >= 0.8)
    }

    @Test func unrelatedNamesStayUnrelated() {
        #expect(ScoringRules.nameSimilarity("ELSIE", "MARY") < 0.7)
        #expect(ScoringRules.nameSimilarity("BETTY", "MARGARET") < 0.7)
    }

    @Test func harryHenryStillPaired() {
        // The pre-existing pair the Harry Marshall search depends on —
        // his registered form may be HENRY.
        #expect(ScoringRules.nameSimilarity("HARRY", "HENRY") >= 0.85)
    }
}
