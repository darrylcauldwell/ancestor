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
///    a namesake household is caught before its parents are grafted on.
struct CensusHouseholdFixRow: View {
    @Environment(AppState.self) private var appState

    let profile: Profile
    let proposal: AppState.CensusHouseholdProposal
    var onChanged: () -> Void = {}

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
                row(icon: "person.2.badge.plus",
                    text: inLaws > 0
                        ? "In the \(String(year)) census — \(links.count) household member\(links.count == 1 ? "" : "s") + \(inLaws) in-law grandparent\(inLaws == 1 ? "" : "s") not on the tree"
                        : "In the \(String(year)) census with \(links.count) household member\(links.count == 1 ? "" : "s") not on the tree") {
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
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Text(Self.rosterLine(link))
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
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
