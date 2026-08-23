import Testing
import Foundation
@testable import Ancestor_Research

/// The scorer accepts what the dispatcher probes for.
///
/// Confirmed critical by the 2026-08-23 adversarial sweep: the variant layers
/// (generated rules, curated seeds, learned pairs) were consulted ONLY by the
/// query fan-out. The dispatcher probed STEPHENSON because those layers say it
/// is a spelling of STEVENSON, FreeREG returned Mary's baptism — and the name
/// gate scored the pair 0.0 (a substitution plus an insertion, below every
/// similarity rung) and hard-failed the record to .impossible. Fetched, then
/// killed at scoring. The fan-out and the gate must share one notion of
/// "same name spelled differently".
@MainActor
struct VariantSpellingScoringTests {

    // MARK: - The similarity rung

    @Test func stephensonScoresAsAVariantOfStevenson() {
        #expect(ScoringRules.nameSimilarity("STEPHENSON", "STEVENSON") == 0.78)
        #expect(ScoringRules.nameSimilarity("STEVENSON", "STEPHENSON") == 0.78)
    }

    /// Curated irregulars reach the scorer too — HULME is a Holmes the rules
    /// cannot generate.
    @Test func curatedIrregularsScoreAsVariants() {
        #expect(ScoringRules.nameSimilarity("HULME", "HOLMES") == 0.78)
    }

    /// The rung only UPGRADES: pairs the higher rungs already score keep
    /// their scores (containment 0.8, exact 1.0).
    @Test func higherRungsAreNeverDowngraded() {
        #expect(ScoringRules.nameSimilarity("STEVENS", "STEVENSON") == 0.8, "containment stays 0.8")
        #expect(ScoringRules.nameSimilarity("STEVENSON", "STEVENSON") == 1.0)
    }

    /// Unrelated names stay unrelated — the rung must not weld distinct
    /// families together.
    @Test func unrelatedNamesStillScoreZero() {
        #expect(ScoringRules.nameSimilarity("STEVENSON", "WHEELDON") == 0.0)
        #expect(ScoringRules.nameSimilarity("HOLMES", "HOLLINGWORTH") == 0.0,
                "the soundex collision pair must NOT become a variant")
    }

    // MARK: - End to end: the actual record against the actual subject

    /// Mary's baptism, exactly as FreeREG returns it, scored against Mary as
    /// the tree holds her: the verdict must be a reviewable lead — never
    /// .impossible (killed silently), and never .fact (a variant spelling is
    /// a human's call).
    @Test func marysActualBaptismSurvivesTheGauntlet() {
        let record = SourceRecord.parish(ParishRecord(
            common: RecordCommon(
                id: "b", sourceID: "freereg", name: "Mary STEPHENSON",
                surname: "STEPHENSON", givenName: "Mary",
                detailURL: "https://www.freereg.org.uk/search_records/683052198655746c655cef5d/mary-stephenson-baptism-derbyshire-youlgreave-1823-12-28",
                rawFields: [:]),
            eventType: "baptism", eventDate: "28 Dec 1823", eventYear: 1823,
            parish: "Youlgreave", county: "Derbyshire",
            fatherName: "John STEPHENSON", motherName: "Lydia"))
        let mary = ResearchSubject(
            profileID: "mary", surname: "Stevenson", givenName: "Mary",
            birthYearFrom: 1824, birthYearTo: 1825,
            birthAnchorIsDerived: true,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .female, region: nil, mode: .adaptive,
            familyContext: nil, homeChapmanCode: "DBY")

        let scored = RecordScorer.classify(record: record, subject: mary, searchType: .parish)
        #expect(scored.verdict != .impossible,
                "the record this whole hunt was for must never be scored dead: \(scored.gates)")
        #expect(scored.verdict == .lead,
                "a variant-spelling match is a reviewable lead; got \(scored.verdict)")
        let nameGate = scored.gates.first { $0.gate == .name }
        #expect(nameGate?.outcome == .softFail,
                "the surname difference must surface for review, not pass silently: \(String(describing: nameGate))")
    }

    // MARK: - Learned pairs reach the scorer

    /// Registering a learned pair (as ResearchRunService now does at pipeline
    /// build) lifts it to 0.9 — gate-pass grade, right for a pairing a human
    /// confirmed by applying a record.
    @Test func learnedPairsReachTheScorerAtPassGrade() {
        ScoringRules.addLearnedEquivalence("KEYWORTH", "KEYWORTHE")
        defer { ScoringRules.learnedEquivalences = [] }
        #expect(ScoringRules.nameSimilarity("KEYWORTH", "KEYWORTHE") == 0.9)
    }
}
