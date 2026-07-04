import Foundation

/// PUBLISHER_SPEC §5 — per-person publish policy.
///
/// Stored in `publish_policy` (migration v30). `auto` is the default for
/// every person; the pre-publish review screen writes explicit overrides.
nonisolated enum PublishPolicy: String, Codable, Sendable, CaseIterable {
    case auto
    case full
    case nameOnly
    case omit
}

/// What the projection actually applies after resolving `auto`.
nonisolated enum ResolvedPublishPolicy: String, Sendable {
    case full
    case nameOnly
    case omit
}

/// The redaction decision, as a pure function (PUBLISHER_SPEC §5).
///
/// `auto` resolves via the existing `ProfileCompleteness.potentiallyLiving`
/// heuristic (FamilyGraphSnapshot — no death date ⇒ living unless born
/// >100 years ago; no birth date at all ⇒ living). One definition, reused,
/// never forked: the publisher deliberately shares the completeness UI's
/// notion of "possibly alive" so the review screen and tree badges agree.
///
/// A death recorded without a `deathDate` (death life-event, or
/// deathLocation only) still resolves living ⇒ `nameOnly` — the safe
/// default; the pre-publish review screen is where a human corrects it.
nonisolated enum PublishPolicyResolver {
    static func resolve(override: PublishPolicy, potentiallyLiving: Bool) -> ResolvedPublishPolicy {
        switch override {
        case .full: .full
        case .nameOnly: .nameOnly
        case .omit: .omit
        case .auto: potentiallyLiving ? .nameOnly : .full
        }
    }
}
