import SwiftUI
import AncestorKit

/// The parish-record family-absorption row — one component, two hosts. The
/// FreeREG twin of `CensusHouseholdFixRow`: a baptism / marriage / burial record
/// names a spouse or parents not yet on the tree, and this offers to create
/// them. Rendered identically on the profile card's Health strip and the Health
/// tab's `parishFamilyUnabsorbed` finding, from one source of truth.
///
/// There is no fetch half (unlike census `.needsLoad`) — the parish detail is
/// already applied; only the named relatives are net-new. Adding them is a tree
/// mutation, so in the Health-list host (`reviewInProfile` set) the button routes
/// to the profile to confirm in full context rather than committing from a list
/// row; on the profile card (nil) the inline "Add" commits.
struct ParishFamilyFixRow: View {
    @Environment(AppState.self) private var appState

    let profile: Profile
    let proposal: AppState.ParishFamilyProposal
    var onChanged: () -> Void = {}
    var reviewInProfile: (() -> Void)? = nil

    var body: some View {
        switch proposal {
        case .canAdd(let links, let year, let sourceID, let kind):
            let eventWord = switch kind {
            case .marriage: "marriage"
            case .baptism:  "baptism"
            case .burial:   "burial"
            }
            let names = links.map(\.displayName).filter { !$0.isEmpty }
            VStack(alignment: .leading, spacing: 3) {
                row(icon: "person.crop.rectangle.badge.plus",
                    text: "\(String(year)) \(eventWord) names \(names.joined(separator: " + ")) — not on the tree") {
                    if let reviewInProfile {
                        // Health-list host: creating people is a tree change, so
                        // route to the profile to confirm in full context.
                        Button("Review in profile") { reviewInProfile() }
                            .buttonStyle(.glassProminent).controlSize(.mini)
                            .help("Creating these people changes the tree — open the profile to add them with full context (existing family, this person's own record) so a namesake isn't grafted on.")
                    } else {
                        Button("Add \(links.count) \(links.count == 1 ? "person" : "people")") {
                            _ = appState.addParishFamily(
                                links: links, subject: profile,
                                eventYear: year, sourceID: sourceID)
                            onChanged()
                        }
                        .buttonStyle(.glassProminent).controlSize(.mini)
                        .help("Creates the spouse and/or parents this parish record names, linked to \(profile.displayName). A wrongly-created namesake is a later merge — the record's rich detail (marriage date, occupation, residence) is already on the profile.")
                    }
                }
                roster(links: links)
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

    // MARK: - Roster preview (who would be created)

    @ViewBuilder
    private func roster(links: [AppState.ParishFamilyLink]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(links) { link in
                Text("• \(link.displayName) — \(Self.roleWord(link))")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 24)
    }

    /// The link's role relative to the subject, sexed where known.
    nonisolated static func roleWord(_ link: AppState.ParishFamilyLink) -> String {
        switch link.relation {
        case .spouse: return "spouse"
        case .parent:
            switch link.gender {
            case .female: return "mother"
            case .male:   return "father"
            default:      return "parent"
            }
        }
    }
}
