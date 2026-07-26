import Foundation

/// Classifies a research subject by how much identifying information
/// the engine has for them at scoring time. Drives the scorer's
/// verdict-cap per ENGINE_FOUNDATION_SPEC #Change1: when density is
/// `.thin`, no record from a scoring pass can land `.fact` — the
/// scorer caps at `.lead`. Hard fails still emit `.impossible`.
/// ONE exemption, amended by CROSS_PROFILE_CORROBORATION #CPC-Change4:
/// a marriage record carrying a reciprocal-tier STRONG-anchor
/// cross-profile annotation lifts the cap — a tree-linked spouse's own
/// persisted record supplies precisely the external discrimination the
/// cap exists to demand.
///
/// Rationale: with no given name, the name gate cannot discriminate a
/// single match from the cohort of surname-sharers; with a 25-plus
/// year birth-year window, the date gate's per-type tolerance is
/// irrelevant. In both cases the scorer cannot meaningfully assert
/// truth about a single match. Convergence and the placeholder
/// write-back (#Change2) re-promote leads to fact-grade once enough
/// signal accumulates.
nonisolated enum InformationDensity: Sendable, Equatable {

    /// Subject lacks the anchoring info needed to discriminate.
    case thin

    /// Subject has enough anchoring info that the gates do meaningful
    /// work. Verdicts run as today.
    case rich

    /// Birth-year window width that flips a given-name-bearing subject
    /// into `.thin`. The derived-from-oldest-child fallback in
    /// `ResearchSubject.fromProfile` produces a 27-year window —
    /// already thin by definition. 25 sits just under that, capturing
    /// the worst-of-the-fallbacks plus a small margin.
    static let wideBirthWindowYears: Int = 25

    /// Compute density from a research subject. `givenName` presence
    /// is load-bearing; birth-year window width is the secondary
    /// signal.
    static func from(subject: ResearchSubject) -> InformationDensity {
        let trimmedGiven = (subject.givenName ?? "")
            .trimmingCharacters(in: .whitespaces)
        if trimmedGiven.isEmpty { return .thin }

        if let from = subject.birthYearFrom,
           let to = subject.birthYearTo,
           to - from > wideBirthWindowYears {
            return .thin
        }

        return .rich
    }
}
