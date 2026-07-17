import Foundation

/// Ties an emergent lead cluster back to the tree people whose research
/// surfaced it — the assessment frame the Possible People panel needs
/// (`POSSIBLE_PEOPLE_CONTEXT_SPEC.md`). A cluster is a candidate *new* person;
/// its leads carry the `profileID` of the profile whose research generated
/// them, so the "origins" are the bridge from a floating candidate back to the
/// tree, and their dates are what let a human judge "plausible relative vs.
/// namesake the search dragged in".
///
/// Pure and nonisolated — derived entirely from the snapshot, no mutation.
nonisolated enum ClusterContext {

    /// A tree person who surfaced ≥1 of the cluster's leads.
    struct Origin: Identifiable, Sendable, Equatable {
        let id: String            // profileID
        let name: String
        let birthYear: Int?
        let deathYear: Int?

        /// "(1850–1920)" / "(b. 1850)" / "(d. 1920)" / "" when undated.
        var lifespanLabel: String {
            switch (birthYear, deathYear) {
            case let (b?, d?): return "(\(b)–\(d))"
            case let (b?, nil): return "(b. \(b))"
            case let (nil, d?): return "(d. \(d))"
            case (nil, nil): return ""
            }
        }
    }

    /// Generous half-window (years) around an origin's life within which a
    /// cluster's era is still plausibly a relative — great-grandparent to
    /// great-grandchild spans ~3 generations each way. Deliberately wide so the
    /// namesake flag fires only on egregious gaps; tune once seen on real data.
    static let relativeWindowYears = 100

    /// The distinct dated tree profiles that surfaced this cluster's leads,
    /// most-recently-surfacing order preserved by first appearance. Profiles
    /// missing from the snapshot (deleted, or a lead with no owning profile) are
    /// skipped — an unresolvable origin isn't context.
    static func origins(
        for cluster: LeadDiscoveryEngine.EmergentCluster,
        in profiles: [String: Profile]
    ) -> [Origin] {
        var seen: Set<String> = []
        var result: [Origin] = []
        for lead in cluster.leads {
            guard seen.insert(lead.profileID).inserted,
                  let p = profiles[lead.profileID], !p.isDeleted else { continue }
            result.append(Origin(
                id: p.id,
                name: p.displayName.isEmpty ? p.id : p.displayName,
                birthYear: p.birthDate?.bestYear,
                deathYear: p.deathDate?.bestYear
            ))
        }
        return result
    }

    /// A short "likely a namesake" note when the cluster's era sits beyond every
    /// origin's generous relative window — else nil. Requires a cluster birth
    /// year and at least one origin with a usable date; silent otherwise (we
    /// never flag on absence of evidence). Compares against the CLOSEST origin:
    /// if the cluster plausibly relates to any one relative, it's not flagged.
    static func namesakeFlag(
        clusterBirthYear: Int?,
        origins: [Origin]
    ) -> String? {
        guard let cby = clusterBirthYear else { return nil }
        let dated = origins.filter { $0.birthYear != nil || $0.deathYear != nil }
        guard !dated.isEmpty else { return nil }

        var closest: (origin: Origin, gap: Int)?
        for origin in dated {
            let lo = (origin.birthYear ?? origin.deathYear!) - relativeWindowYears
            let hi = (origin.deathYear ?? origin.birthYear!) + relativeWindowYears
            let gap = cby < lo ? lo - cby : (cby > hi ? cby - hi : 0)
            if gap == 0 { return nil }                       // within some origin's window
            if closest == nil || gap < closest!.gap { closest = (origin, gap) }
        }
        guard let closest else { return nil }
        let ref = closest.origin.birthYear ?? closest.origin.deathYear!
        let years = abs(cby - ref)
        return "~\(years) yrs from \(closest.origin.name) · likely a namesake"
    }
}
