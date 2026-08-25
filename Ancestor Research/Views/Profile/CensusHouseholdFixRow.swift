import SwiftUI
import AncestorKit

/// The census-household absorption row — one component, two hosts.
///
/// Extracted from the profile card's Health strip (`SharedProfileLayout`) so the
/// SAME row + action + roster preview renders in BOTH the profile and the Health
/// tab's `censusUnabsorbed` finding, from one source of truth. This is the twin
/// of `AuditFixButton` ("one switch, two hosts, so the sweep and the card never
/// disagree") applied to the richer census row rather than a bare button. Owner
/// request 2026-08-12: put the Load-household / Add-N action on the Health row
/// instead of forcing a click-through into the profile.
///
/// Two cases, matching `AppState.CensusHouseholdProposal`:
///  - `.needsLoad` → a **fetch** ("Load household"); it doesn't change the tree,
///    so it is a safe one-click. The row flips to `.canAbsorb` once loaded.
///  - `.canAbsorb` → **adds N people** ("Add N family members"), shown with the
///    named roster (who would be added + the subject's own census birthplace) so
///    a namesake household is caught before its parents are grafted on. Each
///    net-new roster row carries its own Add in the profile host, so one
///    relative can be taken without the whole household.
struct CensusHouseholdFixRow: View {
    @Environment(AppState.self) private var appState

    let profile: Profile
    let proposal: AppState.CensusHouseholdProposal
    var onChanged: () -> Void = {}
    /// When set (the Health-list host), the mutating "Add N" becomes "Review in
    /// profile" — adding people is a tree change and must be confirmed with the
    /// profile's full context (existing family, this person's own record) in
    /// view. Nil (the profile card) → the inline add commits, since that host
    /// IS the context. The safe fetch (`.needsLoad`) stays inline in both.
    var reviewInProfile: (() -> Void)? = nil

    var body: some View {
        switch proposal {
        case .needsLoad(let sourceRecordID, let year):
            row(icon: "person.2.badge.plus",
                text: "The \(String(year)) census household isn't loaded — fetch it to add parents & siblings") {
                Button("Load household") {
                    Task {
                        _ = await appState.loadCensusHousehold(
                            sourceRecordID: sourceRecordID, profileID: profile.id)
                        onChanged()
                    }
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Fetches this census's full schedule — one page from FreeCen — so its household family can be added.")
            }
        case .canAbsorb(let links, let year, let sourceID, let household, let inLaws, let citationURL):
            // Nuclear family + any in-law grandparent STILL net-new (a father/
            // mother-in-law is a two-generation unlock; the count clears once added).
            let total = links.count + inLaws
            VStack(alignment: .leading, spacing: 3) {
                // State the whole and the part, so the number reads as a subset
                // of a list the reader can see rather than a claim they must
                // take on trust.
                row(icon: "person.2.badge.plus",
                    text: inLaws > 0
                        ? "\(String(year)) census · \(household.count) in the household · \(links.count) not on the tree, plus \(inLaws) in-law grandparent\(inLaws == 1 ? "" : "s")"
                        : "\(String(year)) census · \(household.count) in the household · \(links.count) not on the tree") {
                    if let reviewInProfile {
                        // Health-list host: adding N people is a tree change, so
                        // route to the profile to confirm in full context rather
                        // than committing from a list row.
                        Button("Review in profile") { reviewInProfile() }
                            .buttonStyle(.glassProminent).controlSize(.mini)
                            .help("Adding these people changes the tree — open the profile to add them with full context (existing family, this person's own record) so a namesake household isn't grafted on.")
                    } else {
                        Button("Add \(total) family member\(total == 1 ? "" : "s")") {
                            _ = appState.addCensusFamily(
                                links: links, subject: profile,
                                censusYear: year, sourceID: sourceID, household: household,
                                citationURL: citationURL)
                            onChanged()
                        }
                        .buttonStyle(.glassProminent).controlSize(.mini)
                        .help("Adds the family rows (parents, spouse, children, siblings) plus a father/mother-in-law as a grandparent — which also gives the married-in parent their maiden surname. Boarders, lodgers, visitors and servants are left out.")
                    }
                }
                // Show WHO would be added + the subject's own census birthplace —
                // evidence at the point of the click, so a namesake household (a
                // target row born elsewhere than the profile records) is caught
                // before its parents are grafted on.
                roster(links: links, household: household)
            }
        }
    }

    // MARK: - Row layout (mirror of the profile strip's healthStripRow)

    @ViewBuilder
    private func row(icon: String, text: String,
                     @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(AppTypography.badge)
                .foregroundStyle(Color.blue)
                .frame(width: 16)
            Text(text)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
    }

    // MARK: - Roster preview (who would be added)

    @ViewBuilder
    private func roster(links: [CensusFamilyLinker.Link], household: [HouseholdMember]) -> some View {
        // EVERY household row, each carrying what the tree already knows about
        // it — not just the ones that would be added.
        //
        // Owner request 2026-08-22. This row previously listed only the net-new
        // members beside a count, so "Add 4 family members" was an assertion the
        // reader had no way to check; they would have had to compare the roster
        // against the tree by hand, which is the app's job. It was wrong twice in
        // one day — 5 on Samuel Holmes, 4 on Harriet — each time including a
        // relative already linked to the profile. Showing the whole household
        // makes the count a CONSEQUENCE of visible rows: the add rows ARE
        // `links`, so the button and the list cannot disagree.
        let addLinks = Dictionary(links.map { ($0.member, $0) }, uniquingKeysWith: { first, _ in first })
        let statuses = rosterStatuses(household: household)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(household.enumerated()), id: \.offset) { _, member in
                HStack(alignment: .top, spacing: 6) {
                    Text(Self.householdLine(member))
                        .font(AppTypography.badge)
                        .foregroundStyle(addLinks[member] != nil ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let link = addLinks[member] {
                        addControl(link: link)
                    } else {
                        Text(statusLabel(for: member, status: statuses[member]))
                            .font(AppTypography.badge)
                            .foregroundStyle(statusTint(status: statuses[member]))
                    }
                }
            }
            if let target = household.first(where: { $0.isTarget == true }),
               let born = target.birthPlace?.trimmingCharacters(in: .whitespaces),
               !born.isEmpty {
                // Neutral juxtaposition — the profile's recorded birthplace is
                // appended only when it names a different town, never as a verdict.
                let recorded = profile.birthLocation
                let suffix = AppState.placesDivergeAtTown(born, recorded)
                    ? " · profile records \(recorded ?? "")" : ""
                Text("census lists this person born \(born)\(suffix)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(.leading, 24)
    }

    // MARK: - Per-row tree status

    /// What the reconciler makes of each roster row, keyed by member. One
    /// classifier for the whole surface — the same statuses the Health tab's
    /// roster renders — so this list can never tell a different story from the
    /// `censusRelationship` finding sitting beside it.
    private func rosterStatuses(
        household: [HouseholdMember]
    ) -> [HouseholdMember: CensusRelationshipReconciler.CensusReconciliation.RosterEntry.Status] {
        var out: [HouseholdMember: CensusRelationshipReconciler.CensusReconciliation.RosterEntry.Status] = [:]
        for recon in CensusRelationshipReconciler.reconciliations(for: profile, in: appState.snapshot) {
            for entry in recon.entries where household.contains(entry.member) {
                out[entry.member] = entry.status
            }
        }
        return out
    }

    private func name(_ id: String) -> String {
        appState.snapshot.profiles[id]?.displayName ?? "a profile"
    }

    /// The `.canAbsorb` payload the per-row Add needs, or nil in `.needsLoad`.
    /// Reading it here rather than threading it through the roster keeps the
    /// per-row add landing EXACTLY what the whole-household button would land
    /// for that row — same source id, same household context, same citation —
    /// so the two adds can never write different provenance for one person.
    private var absorbable: (year: Int, sourceID: String,
                             household: [HouseholdMember], citationURL: String?)? {
        if case .canAbsorb(_, let year, let sourceID, let household, _, let url) = proposal {
            return (year, sourceID, household, url)
        }
        return nil
    }

    /// The net-new rows are the only ones this component can act on, and they
    /// used to render as a tinted, right-aligned "add" — indistinguishable from
    /// the real buttons its Health-tab sibling puts in the same column, and inert
    /// (owner dogfood 2026-08-25: clicked repeatedly, nothing happened). In the
    /// profile host it is now the control it looked like; in the Health host it
    /// stays a MARKER, because that host's whole-household action is deliberately
    /// "Review in profile" — a tree change is confirmed with the existing family
    /// in view — and a per-row commit would walk straight through that gate.
    @ViewBuilder
    private func addControl(link: CensusFamilyLinker.Link) -> some View {
        if let a = absorbable, reviewInProfile == nil {
            let lands = Self.perRowAddLands(
                relation: link.relation,
                subjectHasParent: !appState.snapshot.parentsOf(profile.id).isEmpty)
            Button("Add \(Self.relationLabel(link))") {
                _ = appState.addCensusFamily(
                    links: [link], subject: profile,
                    censusYear: a.year, sourceID: a.sourceID,
                    household: a.household, citationURL: a.citationURL)
                onChanged()
            }
            .buttonStyle(.glass).controlSize(.mini)
            .disabled(!lands)
            .help(lands
                  ? "Create \(link.member.name) and link them as \(profile.displayName)'s \(Self.relationLabel(link)) from the \(String(a.year)) census, cited to the household schedule — this row only, rather than the whole household."
                  : "\(link.member.name) can only be added once \(profile.displayName) has a parent to share — add the father or mother from this roster first, or take the whole household in one click.")
        } else {
            Text("will add")
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether a single-row add can actually land, or would be skipped inside
    /// `addCensusFamily` and look inert all over again.
    ///
    /// A sibling is wired as a CHILD OF THE SUBJECT'S PARENTS — siblinghood is
    /// shared parentage, never a direct edge — so the add skips a sibling with
    /// no parent to hang it on. The proposal still offers those siblings, and
    /// correctly: `censusFamilyNetNewLinks` counts a sibling as net-new when a
    /// parent is coming from the SAME roster, which the whole-household add
    /// creates first. Taken one row at a time that parent never arrives.
    nonisolated static func perRowAddLands(
        relation: CensusRelation, subjectHasParent: Bool
    ) -> Bool {
        relation != .sibling || subjectHasParent
    }

    private func statusLabel(
        for member: HouseholdMember,
        status: CensusRelationshipReconciler.CensusReconciliation.RosterEntry.Status?
    ) -> String {
        switch status {
        case .subject:                       return "this person"
        case .inTree(let pid):               return "✓ \(name(pid))"
        case .nearMatch(let pid, _):         return "✓ \(name(pid))"
        case .unlinkedInTree(let pid):       return "link \(name(pid))"
        case .contradiction(let tid, _):     return "⚠ conflicts with \(name(tid))"
        case .inLawOfSpouse:                 return "in-law"
        case .outOfScope:                    return "not family"
        case .missing, .none:                return ""
        }
    }

    private func statusTint(
        status: CensusRelationshipReconciler.CensusReconciliation.RosterEntry.Status?
    ) -> Color {
        if case .contradiction = status { return .orange }
        if case .inTree = status { return .green }
        if case .nearMatch = status { return .green }
        return .secondary
    }

    /// One household line: "• Name — daughter · age 6 · born Via Gellia".
    /// Unlike `rosterLine` this takes a raw roster member, because the list now
    /// shows every row rather than only the net-new ones.
    nonisolated static func householdLine(_ m: HouseholdMember) -> String {
        var parts = ["\(m.name) — \(m.relationship.lowercased())"]
        if let a = m.age { parts.append("age \(a)") }
        else if let raw = m.rawAge?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            parts.append("age \(raw)")
        }
        if let bp = m.birthPlace?.trimmingCharacters(in: .whitespaces), !bp.isEmpty {
            parts.append("born \(bp)")
        }
        return "• " + parts.joined(separator: " · ")
    }

    /// One roster line: "• Name — father · age 56 · born Wigan".
    nonisolated static func rosterLine(_ link: CensusFamilyLinker.Link) -> String {
        let m = link.member
        var parts = ["\(m.name) — \(relationLabel(link))"]
        if let a = m.age { parts.append("age \(a)") }
        else if let raw = m.rawAge?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            parts.append("age \(raw)")
        }
        if let bp = m.birthPlace?.trimmingCharacters(in: .whitespaces), !bp.isEmpty {
            parts.append("born \(bp)")
        }
        return "• " + parts.joined(separator: " · ")
    }

    /// The member's relation to the SUBJECT, sexed where the roster allows
    /// (father/mother, son/daughter, brother/sister).
    nonisolated static func relationLabel(_ link: CensusFamilyLinker.Link) -> String {
        let g = AppState.censusMemberGender(link.member)
        switch link.relation {
        case .parent:  return g == .female ? "mother" : g == .male ? "father" : "parent"
        case .child:   return g == .female ? "daughter" : g == .male ? "son" : "child"
        case .sibling: return g == .female ? "sister" : g == .male ? "brother" : "sibling"
        case .spouse:  return "spouse"
        }
    }
}

extension AppState.CensusHouseholdProposal {
    /// The census this proposal is about. Both hosts key the one-affordance
    /// rule on it: a `censusRelationship` finding covering the same year would
    /// otherwise put a second bulk-add button beside this row, and only this
    /// one carries the household's citation URL.
    var censusYear: Int {
        switch self {
        case .needsLoad(_, let year): year
        case .canAbsorb(_, let year, _, _, _, _): year
        }
    }
}
