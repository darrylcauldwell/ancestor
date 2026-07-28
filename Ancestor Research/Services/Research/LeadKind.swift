import Foundation

/// The two fundamentally different things a lead can be — the split the Triage
/// "Possible People" panel needs to extract signal from namesake noise.
///
/// A common surname drags in dozens of leads that are almost all *different
/// people who happen to share the name* (category A). Mixed into that pile are
/// a handful of genuinely valuable leads that propose a *new relative to add to
/// the tree* (category B). Today both live in one undifferentiated cluster
/// list, and because the discovery leads (inferred parents) carry no birth
/// year, they sink to the bottom of the low-confidence fold — the signal buried
/// under the noise.
///
/// `LeadKind` makes the distinction explicit so the panel can elevate B
/// (grouped by relationship) and rank/collapse A. Pure and `nonisolated` —
/// derived entirely from a lead's stored fields, no I/O, fully testable.
nonisolated enum LeadKind: Equatable, Sendable {
    /// Category B — a new person to attach to the tree in a known kin role.
    /// These are the tree-growing leads; they should never be buried.
    case relative(RelativeRole)
    /// Category A — a record/person that might be the *same person* as an
    /// existing profile. Namesake noise for a common name; the pile to rank
    /// and collapse.
    case identityCandidate

    /// The kin role a discovery lead proposes, normalised from the free-text
    /// `Lead.relationship` the pipeline stored. Ordered/grouped for display.
    enum RelativeRole: String, CaseIterable, Sendable {
        case parent, spouse, child, sibling

        /// Section order in the "Relatives to add" list — closest kin first.
        var sortOrder: Int {
            switch self {
            case .parent: 0; case .spouse: 1; case .child: 2; case .sibling: 3
            }
        }

        /// Plural section header, e.g. "Parents to add".
        var sectionTitle: String {
            switch self {
            case .parent: "Parents to add"
            case .spouse: "Spouses to add"
            case .child: "Children to add"
            case .sibling: "Siblings to add"
            }
        }

        var systemImage: String {
            switch self {
            case .parent: "arrow.up.circle"
            case .spouse: "heart.circle"
            case .child: "arrow.down.circle"
            case .sibling: "arrow.left.arrow.right.circle"
            }
        }
    }

    /// Classify one lead. A lead is a *relative* (category B) when its stored
    /// `relationship` names a concrete kin role; otherwise it's an *identity
    /// candidate* (category A) — the scored-record namesakes that reach the
    /// pool with `relationship == nil`.
    static func classify(_ lead: Lead) -> LeadKind {
        guard let role = role(from: lead.relationship) else { return .identityCandidate }
        return .relative(role)
    }

    /// Map a free-text relationship string onto a kin role. Covers the
    /// vocabularies the several lead emitters use: `createFromParentInferred`
    /// ("father"/"mother"), `createFromHouseholdMember` (census relationship,
    /// e.g. "son"/"wife"/"head"), and MCP `submit_lead` (caller-supplied).
    /// Anything not a recognised kin word — including "unknown", "head", "" —
    /// returns nil, keeping the lead a category-A candidate.
    static func role(from relationship: String?) -> RelativeRole? {
        guard let raw = relationship?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "father", "mother", "parent", "dad", "mum", "mother-in-law", "father-in-law":
            return .parent
        case "spouse", "husband", "wife", "married", "partner":
            return .spouse
        case "son", "daughter", "child", "stepson", "stepdaughter":
            return .child
        case "brother", "sister", "sibling", "half-brother", "half-sister":
            return .sibling
        default:
            return nil
        }
    }

    /// The kind of a whole cluster: a cluster is a relative-discovery when its
    /// leads carry a kin role (they cluster on their own distinctive shape,
    /// e.g. "[father] /KEYWORTH/", so they don't mix with namesake candidates).
    /// When roles disagree the most common wins; ties break toward closest kin.
    /// A cluster with no relative leads is an identity candidate.
    static func classify(_ leads: [Lead]) -> LeadKind {
        var counts: [RelativeRole: Int] = [:]
        for lead in leads {
            if case .relative(let role) = classify(lead) { counts[role, default: 0] += 1 }
        }
        guard let winner = counts.max(by: { a, b in
            a.value != b.value ? a.value < b.value : a.key.sortOrder > b.key.sortOrder
        }) else { return .identityCandidate }
        return .relative(winner.key)
    }
}
