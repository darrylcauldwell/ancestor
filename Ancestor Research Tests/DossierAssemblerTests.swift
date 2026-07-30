import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// DOSSIER_SPEC #T9-Change1 acceptance criteria for the deterministic
/// skeleton: every sentence grounded (refs resolve to input rows), D2
/// byte-matches stored dispute strings, D3 never converts a truncated
/// search into a gap claim, honest empty states, D7 footer hash + counts.
/// The assembler takes plain values and holds no DB handle — "zero DB
/// writes during assembly" is true by construction.
@MainActor
struct DossierAssemblerTests {

    // MARK: - Fixtures

    private func profile(_ id: String = "@P1@", birthYear: Int? = 1869,
                         deathYear: Int? = 1916) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: "Elizabeth", lastName: "Shaw",
                gender: .female, attributes: nil,
                birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
                birthLocation: "Eastwood",
                deathDate: deathYear.map { GenealogicalDate(parsing: String($0)) },
                deathLocation: "Bakewell",
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func deathEvidence(_ recordID: String) -> EvidenceRecord {
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: recordID, sourceID: "freebmd", name: nil,
                                 surname: "KEYWORTH", givenName: "ELIZABETH",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1916, deathDate: nil, deathPlace: nil, age: 46,
            quarter: "Dec", district: "Bakewell", volume: "7b", page: "920"))
        return EvidenceRecord(
            id: "@P1@|\(recordID)", profileID: "@P1@", sourceID: "freebmd",
            sourceRecordID: recordID, recordType: .death, verdict: .fact,
            record: record, citationFull: nil, citationURL: nil,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: .unreviewed)
    }

    private func negativeRow(_ id: Int64, resultKind: String?,
                             recordType: String = "death") -> NegativeSearchRow {
        NegativeSearchRow(
            id: id, sourceID: "freebmd", recordType: recordType,
            searchedAt: Date(timeIntervalSince1970: 1_780_000_000),
            searchParams: nil, resultKind: resultKind, hitCount: resultKind == "truncated" ? 250 : 0)
    }

    private func inputs(
        evidence: [EvidenceRecord] = [],
        disputes: [DisputeRow] = [],
        hypotheses: [ResearchHypothesis] = [],
        negatives: [NegativeSearchRow] = [],
        clusters: [LifeCluster] = [],
        subject: Profile? = nil
    ) -> DossierAssembler.Inputs {
        DossierAssembler.Inputs(
            profile: subject ?? profile(), disputes: disputes, evidence: evidence,
            hypotheses: hypotheses, negativeSearches: negatives,
            lastRun: .init(id: "run-1", date: Date(timeIntervalSince1970: 1_780_000_000),
                           gps: 3, mode: "standard"),
            liveGPS: nil, liveClusters: clusters, sourceInfoMap: [:],
            now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Every ref in the dossier must resolve to a row the inputs actually
    /// contain — the walk from acceptance criterion 2.
    private func assertRefsResolve(_ dossier: Dossier, _ inputs: DossierAssembler.Inputs) {
        let evidenceIDs = Set(inputs.evidence.map(\.sourceRecordID))
        let disputeIDs = Set(inputs.disputes.map { String($0.id) })
        let hypothesisIDs = Set(inputs.hypotheses.map(\.id))
        let negativeIDs = Set(inputs.negativeSearches.map { String($0.id) })
        let clusterIDs = Set(inputs.liveClusters.map(\.id))
        for section in dossier.sections {
            for sentence in section.sentences {
                #expect(!sentence.refs.isEmpty, "ungrounded sentence: \(sentence.text)")
                for ref in sentence.refs {
                    switch ref {
                    case .evidenceRecord(let id):
                        #expect(evidenceIDs.contains(id), "dangling evidence ref \(id)")
                    case .dispute(let id):
                        #expect(disputeIDs.contains(id), "dangling dispute ref \(id)")
                    case .hypothesis(let id):
                        #expect(hypothesisIDs.contains(id), "dangling hypothesis ref \(id)")
                    case .negativeSearch(let id):
                        #expect(negativeIDs.contains(id), "dangling negative ref \(id)")
                    case .cluster(let id):
                        #expect(clusterIDs.contains(id), "dangling cluster ref \(id)")
                    case .researchRun(let id):
                        #expect(id == inputs.lastRun?.id, "dangling run ref \(id)")
                    case .profileField(let profileID, _):
                        #expect(profileID == inputs.profile.id)
                    default:
                        Issue.record("unexpected ref kind in Change-1 dossier: \(ref.key)")
                    }
                }
            }
        }
    }

    // MARK: - Tests

    @Test func everySentenceIsGroundedAndRefsResolve() {
        let hypothesis = ResearchHypothesis(
            id: "h1", subjectProfileID: "@P1@",
            kind: .burialAtParish(parish: "Bakewell", yearWindow: 1916...1917),
            verdict: .inconclusive, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [],
            reasoning: "no burial register match yet",
            createdAt: Date(timeIntervalSince1970: 0),
            lastTestedAt: Date(timeIntervalSince1970: 0),
            attempts: 1, history: [])
        let ins = inputs(
            evidence: [deathEvidence("d1"), deathEvidence("d2")],
            hypotheses: [hypothesis],
            negatives: [negativeRow(11, resultKind: "zero"),
                        negativeRow(12, resultKind: "truncated")])
        let dossier = DossierAssembler.assemble(ins)
        assertRefsResolve(dossier, ins)
        #expect(dossier.sections.map(\.id) == ["D0", "D1", "D2", "D3", "D4", "D5"])
    }

    @Test func d1NarratesConvergenceViaVocabularyOnly() {
        // Two index rows of the SAME GRO death → the witness-collapsed
        // convergence machinery must not read them as two witnesses.
        let ins = inputs(evidence: [deathEvidence("d1"), deathEvidence("d2")])
        let dossier = DossierAssembler.assemble(ins)
        let d1 = dossier.sections.first { $0.id == "D1" }!
        #expect(!d1.sentences.isEmpty)
        let text = d1.sentences.map(\.text).joined(separator: " ")
        #expect(text.contains("1 independent witness"), Comment(rawValue: text))
        // Confidence words come only from the vocabulary's fixed set.
        #expect(text.contains("single-source") || text.contains("uncorroborated"), Comment(rawValue: text))
        for banned in ConfidenceVocabulary.bannedLexicon {
            #expect(!text.lowercased().contains(banned))
        }
    }

    @Test func d3NeverConvertsTruncationIntoAGap() {
        // Acceptance criterion 4: a truncated outcome is labelled a partial
        // answer, never "no match"; the clean row IS an absence claim.
        let ins = inputs(negatives: [negativeRow(1, resultKind: "truncated"),
                                     negativeRow(2, resultKind: "zero")])
        let dossier = DossierAssembler.assemble(ins)
        let d3 = dossier.sections.first { $0.id == "D3" }!
        let truncatedLine = d3.sentences.first { $0.refs.contains(.negativeSearch("1")) }
        let cleanLine = d3.sentences.first { $0.refs.contains(.negativeSearch("2")) }
        #expect(truncatedLine?.text.contains("not evidence of absence") == true)
        #expect(truncatedLine?.text.contains("no match") == false)
        #expect(cleanLine?.text.contains("no match") == true)
    }

    @Test func d3EmptyStateDistinguishesNotYetSearched() {
        // Acceptance criterion 4b ⟨A12⟩: no negative rows at all (and no
        // structural gaps derivable — dateless subject) → the empty state
        // says "not yet searched", never implying verified absence.
        let dossier = DossierAssembler.assemble(
            inputs(subject: profile(birthYear: nil, deathYear: nil)))
        let d3 = dossier.sections.first { $0.id == "D3" }!
        #expect(d3.sentences.filter { $0.refs.contains { if case .negativeSearch = $0 { return true }; return false } }.isEmpty)
        #expect(d3.emptyState?.contains("not yet searched") == true)
    }

    @Test func structuralCensusGapsAreDerivedFromLifespan() {
        // b.1869 d.1916 → in-scope census years 1871…1911; no census
        // evidence and no clean census negative → all listed.
        let ins = inputs()
        let years = DossierAssembler.uncoveredCensusYears(ins)
        #expect(years == [1871, 1881, 1891, 1901, 1911])
    }

    @Test func d2ByteMatchesStoredDisputeStrings() {
        let dispute = DisputeRow(
            id: 41, entityID: "@P1@", entityKind: "profile",
            kind: .fieldValue, field: "deathDate", reason: .valueMismatch,
            severity: nil, detectedBy: nil, competingSources: [],
            evidenceJSON: nil, ladderTrace: "R2a: CWGC primary over community memorial",
            witnessSummary: "2 witnesses say 1916; 1 says 1914",
            detectedAt: Date(timeIntervalSince1970: 0), resolution: nil, resolvedAt: nil)
        let ins = inputs(disputes: [dispute])
        let dossier = DossierAssembler.assemble(ins)
        let d2 = dossier.sections.first { $0.id == "D2" }!
        let line = d2.sentences.first
        // The stored weighing string appears VERBATIM (byte-match).
        #expect(line?.text.contains("2 witnesses say 1916; 1 says 1914") == true)
        #expect(line?.refs == [.dispute("41")])
    }

    @Test func d5RendersBothRivalClusters() {
        func cluster(_ id: String, year: Int, recordID: String) -> LifeCluster {
            let record = SourceRecord.birth(BirthRecord(
                common: RecordCommon(id: recordID, sourceID: "freebmd", name: nil,
                                     surname: "SHAW", givenName: "JOHN",
                                     detailURL: nil, rawFields: [:]),
                birthYear: year, birthDate: nil, birthPlace: "Belper",
                quarter: "Mar", district: "Belper", volume: "7b", page: "1",
                mothersMaidenName: nil))
            return LifeCluster(
                id: id,
                records: [ScoredRecord(id: recordID, record: record, verdict: .fact,
                                       gates: [], summary: "")],
                lifespanStart: year, lifespanEnd: year + 70, mergeCandidate: nil)
        }
        let ins = inputs(clusters: [cluster("c1", year: 1840, recordID: "r1"),
                                    cluster("c2", year: 1841, recordID: "r2")])
        let dossier = DossierAssembler.assemble(ins)
        let d5 = dossier.sections.first { $0.id == "D5" }!
        #expect(d5.sentences.contains { $0.refs.contains(.cluster("c1")) })
        #expect(d5.sentences.contains { $0.refs.contains(.cluster("c2")) })
        #expect(d5.sentences.contains { $0.text.contains("1840 vs 1841") })
    }

    @Test func d7FooterCarriesHashCountsAndHonestNarration() {
        let ins = inputs(evidence: [deathEvidence("d1")],
                         negatives: [negativeRow(1, resultKind: "zero")])
        let dossier = DossierAssembler.assemble(ins)
        #expect(dossier.footer.narrationMode == "deterministic")
        #expect(dossier.footer.termination == "no challenge pass run yet")
        #expect(dossier.footer.rowCounts["D1"] == 1)
        #expect(dossier.footer.rowCounts["D3"] == 1)
        #expect(dossier.footer.skeletonHash.count == 32)
        // Deterministic: same inputs → same hash; changed inputs → new hash.
        let again = DossierAssembler.assemble(ins)
        #expect(again.footer.skeletonHash == dossier.footer.skeletonHash)
        let changed = DossierAssembler.assemble(inputs(evidence: [deathEvidence("d1"), deathEvidence("d9")]))
        #expect(changed.footer.skeletonHash != dossier.footer.skeletonHash)
    }

    @Test func groundedSentenceCannotExistWithoutRefs() {
        #expect(GroundedSentence(text: "orphan claim", refs: []) == nil)
        #expect(GroundedSentence(text: "  ", refs: [.gpsCriterion(1)]) == nil)
        #expect(GroundedSentence(text: "grounded", refs: [.gpsCriterion(1)]) != nil)
    }

    @Test func verifierRejectsNovelNumbersEntitiesAndBannedWords() {
        let skeleton = ["Birth year 1883 — 2 independent witnesses; convergence: probable."]
        #expect(GroundedProseVerifier.verify(
            smoothed: "Birth year 1883 is backed by 2 independent witnesses and is probable.",
            skeleton: skeleton).accepted)
        #expect(!GroundedProseVerifier.verify(
            smoothed: "Birth year 1884 is backed by 2 independent witnesses.",
            skeleton: skeleton).accepted)                    // digit drift
        #expect(!GroundedProseVerifier.verify(
            smoothed: "Birth year 1883 in Chesterfield — 2 witnesses; probable.",
            skeleton: skeleton).accepted)                    // novel entity
        #expect(!GroundedProseVerifier.verify(
            smoothed: "Birth year 1883, 2 witnesses — this certainly proves it; probable.",
            skeleton: skeleton).accepted)                    // banned lexicon
    }
}
