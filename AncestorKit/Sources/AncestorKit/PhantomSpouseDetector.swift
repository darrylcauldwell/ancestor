import Foundation

/// IMPORT_DEDUPE_SPEC Changes 4–6 — detects "phantom spouse" stubs: a
/// name-only, dateless, evidence-free profile whose SOLE relationship edge is a
/// single spouse-link to a real person. These are the one-edge cousins of the
/// zero-edge stubs `OrphanStubDetector` handles — the same GEDCOM merge habit
/// leaves them behind as extra husbands/wives, and the one spouse-edge
/// disqualifies them from the edge-less cleanse (which requires `isEdgeless`).
///
/// The motivating case: William Henry Keyworth rendered with FOUR spouses — two
/// real (Emma Gladwin, Elizabeth Wallace) and two phantoms (`Gerty`, `Elizabeth
/// Carroll`), each a dateless stub tied only to William. Unpicking it by hand
/// needs three expert moves; this detector does the structural half.
///
/// Pure over a snapshot; the rule (surfacing) and the guided card (execution via
/// `ProfileMergeEngine`) both consume it, so they can never disagree.
public nonisolated struct PhantomSpouseCandidate: Sendable, Equatable {
    public let phantomID: String
    /// The person on the other end of the phantom's single spouse-edge.
    public let anchorID: String
    /// The anchor's one documented spouse to fold into, IFF unambiguous: either
    /// exactly one documented spouse exists, or (when several do) exactly one of
    /// them has the phantom's given name contained in its full name. Nil when
    /// the documented set is empty (manual review) or ambiguous with no
    /// name-containment tiebreak — the card then offers `documentedSpouseIDs`
    /// as a picker (decision #7).
    public let suggestedTargetID: String?
    /// Every documented spouse of the anchor — the card's choices when the
    /// suggestion is nil. Deterministically ordered by ID.
    public let documentedSpouseIDs: [String]
    /// True when the phantom's given-name tokens ⊆ the suggested target's full
    /// name (the "Gerty ⊂ Elizabeth Gertrude" booster). A booster, not a gate
    /// (decision #8) — a phantom with an unrelated name still surfaces.
    public let nameContainment: Bool

    public init(phantomID: String, anchorID: String, suggestedTargetID: String?,
                documentedSpouseIDs: [String], nameContainment: Bool) {
        self.phantomID = phantomID
        self.anchorID = anchorID
        self.suggestedTargetID = suggestedTargetID
        self.documentedSpouseIDs = documentedSpouseIDs
        self.nameContainment = nameContainment
    }
}

public nonisolated enum PhantomSpouseDetector {

    /// A spouse is "documented" when it carries real data — any date, location,
    /// or bio (i.e. it is NOT an empty name-only stub). The exact complement of
    /// `OrphanStubDetector.isEmpty`, so a phantom can never be its own target.
    public static func isDocumented(_ p: Profile) -> Bool { !OrphanStubDetector.isEmpty(p) }

    /// The phantom test: the profile is empty (name only, no dates/locations/bio
    /// — reused from `OrphanStubDetector.isEmpty`) AND its ONLY relationship
    /// edge is a single `.spouse` edge. Returns the anchor (the other end) when
    /// it qualifies, else nil. Decision #6: not zero edges (that is the
    /// edge-less cleanse's job) — exactly one, and it must be a spouse edge.
    public static func phantomAnchor(for profile: Profile, in snapshot: FamilyGraphSnapshot) -> Profile? {
        guard !profile.isDeleted, OrphanStubDetector.isEmpty(profile) else { return nil }
        let edges = snapshot.relationships.filter { $0.from == profile.id || $0.to == profile.id }
        guard edges.count == 1, let edge = edges.first, edge.type == .spouse else { return nil }
        let anchorID = edge.from == profile.id ? edge.to : edge.from
        guard anchorID != profile.id,
              let anchor = snapshot.profiles[anchorID], !anchor.isDeleted else { return nil }
        return anchor
    }

    /// Name-containment booster: phantom's given-name tokens ⊆ target's full-name
    /// tokens (given + middle + last, normalised). "Gerty" alone never matches
    /// "Elizabeth Wallace" — only fires when the target's stored name actually
    /// carries the phantom's token (e.g. a "Gertrude" middle name).
    public static func nameContained(phantom: Profile, in target: Profile) -> Bool {
        let pTokens = Set(OrphanStubDetector.norm(phantom.firstName).split(separator: " ").map(String.init))
        let tFull = [target.firstName, target.middleName, target.lastName]
            .compactMap { $0 }.joined(separator: " ")
        let tTokens = Set(OrphanStubDetector.norm(tFull).split(separator: " ").map(String.init))
        guard !pTokens.isEmpty, !tTokens.isEmpty else { return false }
        return pTokens.isSubset(of: tTokens)
    }

    /// Every phantom-spouse candidate in the snapshot. One per phantom; a
    /// phantom is offered even when its anchor has more than one (or zero)
    /// documented spouse — the suggestion just becomes a choice / manual review
    /// rather than a single target (decisions #7, and #8: never dropped for
    /// ambiguity).
    public static func candidates(in snapshot: FamilyGraphSnapshot) -> [PhantomSpouseCandidate] {
        var out: [PhantomSpouseCandidate] = []
        for phantom in snapshot.profiles.values {
            guard let anchor = phantomAnchor(for: phantom, in: snapshot) else { continue }

            // The anchor's real spouses — exclude the phantom itself and any
            // OTHER empty phantom (Carroll must not count as a target for Gerty).
            let documented = snapshot.spousesOf(anchor.id)
                .filter { $0.id != phantom.id && isDocumented($0) }
                .sorted { $0.id < $1.id }
            let documentedIDs = documented.map(\.id)

            let suggested: Profile?
            switch documented.count {
            case 1:
                suggested = documented[0]
            case let n where n > 1:
                // Ambiguous set → only auto-suggest when name-containment
                // singles out exactly one (e.g. a target carrying "Gertrude").
                let contained = documented.filter { nameContained(phantom: phantom, in: $0) }
                suggested = contained.count == 1 ? contained[0] : nil
            default:
                suggested = nil   // anchor has no documented spouse — manual review
            }

            out.append(PhantomSpouseCandidate(
                phantomID: phantom.id,
                anchorID: anchor.id,
                suggestedTargetID: suggested?.id,
                documentedSpouseIDs: documentedIDs,
                nameContainment: suggested.map { nameContained(phantom: phantom, in: $0) } ?? false))
        }
        // Deterministic order for stable UI + tests.
        return out.sorted { $0.phantomID < $1.phantomID }
    }
}
