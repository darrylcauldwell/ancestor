import Foundation
import CryptoKit

// DOSSIER_SPEC #T9-Change1 — the grounding machinery for the investigation
// dossier, placed in AncestorKit so PROSE_CORPUS bio synthesis reuses it
// later (spec §4 component table). Governing invariant (a): the dossier is a
// pure deterministic projection — every statement carries ≥1 provenance ref
// resolving to a live row; invariant (d): confidence language comes ONLY
// from `ConfidenceVocabulary`, narrating deterministic verdicts verbatim.

/// A typed reference to the database row (or computed criterion) a dossier
/// sentence is grounded in. Spec §3, plus two additive cases the profile-page
/// door needs (`.researchRun` — D0 renders the stored last-run GPS summary
/// when no live run is in memory; `.profileField` — structural-gap sentences
/// anchor to the profile values that bound them).
public nonisolated enum ProvenanceRef: Sendable, Equatable, Hashable, Codable {
    case fieldSource(String)
    case dispute(String)
    case hypothesis(String)
    case negativeSearch(String)
    case lifeEvent(String)
    case challenge(String)          // challenge_points fingerprint
    case gpsCriterion(Int)
    case cluster(String)
    case evidenceRecord(String)
    case relationship(String)
    case researchRun(String)
    case profileField(profileID: String, field: String)

    /// Stable display/debug identity ("dispute:41", "gps:3").
    public var key: String {
        switch self {
        case .fieldSource(let id): "fieldSource:\(id)"
        case .dispute(let id): "dispute:\(id)"
        case .hypothesis(let id): "hypothesis:\(id)"
        case .negativeSearch(let id): "negativeSearch:\(id)"
        case .lifeEvent(let id): "lifeEvent:\(id)"
        case .challenge(let fp): "challenge:\(fp)"
        case .gpsCriterion(let n): "gps:\(n)"
        case .cluster(let id): "cluster:\(id)"
        case .evidenceRecord(let id): "evidenceRecord:\(id)"
        case .relationship(let id): "relationship:\(id)"
        case .researchRun(let id): "researchRun:\(id)"
        case .profileField(let p, let f): "profileField:\(p).\(f)"
        }
    }
}

/// A sentence that cannot exist without provenance — the failable init is
/// the constructor-level enforcement of grounding rule 1 (spec §5): a
/// sentence with an empty ref set cannot be constructed.
public nonisolated struct GroundedSentence: Sendable, Equatable, Codable {
    public let text: String
    public let refs: [ProvenanceRef]

    public init?(text: String, refs: [ProvenanceRef]) {
        guard !refs.isEmpty, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.text = text
        self.refs = refs
    }
}

/// The ONLY source of confidence language in the dossier (spec decision 9,
/// ⟨A5⟩). Narrates the deterministic verdicts verbatim — a `.probable`
/// cluster is never described as established, by construction.
public nonisolated enum ConfidenceVocabulary {

    public static func phrase(for level: ConvergenceLevel) -> String {
        switch level {
        case .uncorroborated: "uncorroborated"
        case .singleSource: "single-source"
        case .possible: "possible"
        case .probable: "probable"
        case .confirmed: "confirmed"
        }
    }

    public static func phrase(for quality: MatchQuality) -> String {
        switch quality {
        case .confirmed: "confirmed match"
        case .possible: "possible match"
        case .wrong: "ruled out"
        }
    }

    public static func phrase(for verdict: ResearchHypothesis.Verdict) -> String {
        switch verdict {
        case .supported: "supported"
        case .contradicted: "contradicted"
        case .inconclusive: "inconclusive"
        }
    }

    /// Words the dossier may never emit — they overclaim beyond any
    /// deterministic verdict (spec §7.2 check 5; permanent unit-tested list).
    public static let bannedLexicon: [String] = [
        "proves", "certainly", "undoubtedly", "must have",
    ]
}

/// Deterministic zero-hallucination gate for model-smoothed text (spec §7.2).
/// Change-1 ships the core checks; smoothing itself arrives with #T9-Change5
/// — until then the verifier exists so the contract is testable and shared.
public nonisolated enum GroundedProseVerifier {

    public struct Verification: Sendable, Equatable {
        public let accepted: Bool
        public let reason: String?
        public static let ok = Verification(accepted: true, reason: nil)
        public static func rejected(_ reason: String) -> Verification {
            Verification(accepted: false, reason: reason)
        }
    }

    /// Verify a smoothed paragraph against the skeleton sentences it claims
    /// to re-phrase. Any failure → the caller renders the skeleton (drop,
    /// never soften).
    public static func verify(smoothed: String, skeleton: [String]) -> Verification {
        let input = skeleton.joined(separator: " ")

        // Digit protection ⟨A11⟩ — no number may appear that the skeleton
        // does not contain, and none may be lost.
        let inputDigits = numberTokens(in: input)
        let outputDigits = numberTokens(in: smoothed)
        if !outputDigits.isSubset(of: inputDigits) {
            return .rejected("novel number: \(outputDigits.subtracting(inputDigits).sorted().joined(separator: ", "))")
        }
        if !inputDigits.isSubset(of: outputDigits) {
            return .rejected("dropped number: \(inputDigits.subtracting(outputDigits).sorted().joined(separator: ", "))")
        }

        // Entity cross-check — title-case tokens (≥3 chars) must originate
        // in the skeleton.
        let inputEntities = entityTokens(in: input)
        let novel = entityTokens(in: smoothed).subtracting(inputEntities)
        if !novel.isEmpty {
            return .rejected("novel entity: \(novel.sorted().joined(separator: ", "))")
        }

        // Banned lexicon.
        let lowered = smoothed.lowercased()
        for banned in ConfidenceVocabulary.bannedLexicon where lowered.contains(banned) {
            return .rejected("banned word: \(banned)")
        }

        // Length ≤ 1.5× input.
        if smoothed.count > Int(Double(input.count) * 1.5) + 1 {
            return .rejected("output exceeds 1.5× skeleton length")
        }
        return .ok
    }

    static func numberTokens(in text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty })
    }

    static func entityTokens(in text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && $0.first?.isUppercase == true })
    }
}

// MARK: - Dossier display model

/// One rendered section (D0–D7). `emptyState` carries the HONEST empty copy
/// ⟨A12⟩ — distinguishing "no rows recorded" from "searched and nothing
/// found" is the assembler's job; the model just displays it.
public nonisolated struct DossierSection: Sendable, Equatable, Codable {
    public let id: String          // "D0"…"D7"
    public let title: String
    public let sentences: [GroundedSentence]
    public let emptyState: String?

    public init(id: String, title: String, sentences: [GroundedSentence], emptyState: String? = nil) {
        self.id = id
        self.title = title
        self.sentences = sentences
        self.emptyState = emptyState
    }
}

/// D7 — the provenance footer ⟨A2⟩: honest process narration.
public nonisolated struct DossierFooter: Sendable, Equatable, Codable {
    public let generatedAt: Date
    public let skeletonHash: String
    public let rowCounts: [String: Int]     // section id → source-row count
    public let narrationMode: String        // "deterministic" | "smoothed by <model> — verified"
    public let termination: String          // loop termination narration

    public init(generatedAt: Date, skeletonHash: String, rowCounts: [String: Int],
                narrationMode: String, termination: String) {
        self.generatedAt = generatedAt
        self.skeletonHash = skeletonHash
        self.rowCounts = rowCounts
        self.narrationMode = narrationMode
        self.termination = termination
    }
}

/// The investigation dossier — a projection, never data: recomputed from
/// rows, cached only as display prose, never persisted as evidence.
public nonisolated struct Dossier: Sendable, Equatable, Codable {
    public let subjectID: String
    public let subjectName: String
    public let sections: [DossierSection]
    public let footer: DossierFooter

    public init(subjectID: String, subjectName: String,
                sections: [DossierSection], footer: DossierFooter) {
        self.subjectID = subjectID
        self.subjectName = subjectName
        self.sections = sections
        self.footer = footer
    }

    /// Content hash of the deterministic skeleton — the staleness signal
    /// ⟨A6⟩ and the smoothing-cache key. Text + refs, order-sensitive.
    public static func skeletonHash(of sections: [DossierSection]) -> String {
        var hasher = SHA256()
        for section in sections {
            hasher.update(data: Data(section.id.utf8))
            for s in section.sentences {
                hasher.update(data: Data(s.text.utf8))
                for r in s.refs { hasher.update(data: Data(r.key.utf8)) }
            }
            if let empty = section.emptyState {
                hasher.update(data: Data(empty.utf8))
            }
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
