import SwiftUI

/// Search field with dropdown results that recenters the tree on selection.
struct TreeSearchField: View {
    @Binding var searchText: String
    let allProfiles: [Profile]
    let snapshot: FamilyGraphSnapshot
    let currentViewMode: TreeViewMode
    var onSelect: (String) -> Void

    @State private var highlightedIndex: Int = 0

    private var matches: [(profile: Profile, completeness: ProfileCompleteness)] {
        guard !searchText.isEmpty else { return [] }
        let query = TreeSearchQuery.parse(searchText)
        guard !query.isEmpty else { return [] }
        let results = allProfiles
            .filter { query.matches($0) }
            .sorted { a, b in a.displayName < b.displayName }
        return results.map { ($0, snapshot.completeness(for: $0.id)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search people…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit {
                    if highlightedIndex < matches.count {
                        onSelect(matches[highlightedIndex].profile.id)
                        searchText = ""
                    }
                }
                .onChange(of: searchText) {
                    highlightedIndex = 0
                }

            if !matches.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let displayed = Array(matches.prefix(20))
                        ForEach(Array(displayed.enumerated()), id: \.element.profile.id) { index, match in
                            Button {
                                onSelect(match.profile.id)
                                searchText = ""
                            } label: {
                                HStack(spacing: 4) {
                                    if wouldSwitchMode(for: match.profile) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .accessibilityLabel("Switches view mode")
                                    }
                                    Text(match.profile.displayName)
                                        .font(.callout)
                                    Spacer()
                                    if let year = match.profile.birthDate?.bestYear {
                                        Text("b. \(year)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text("\(match.completeness.score)/\(match.completeness.maximum)")
                                        .font(.caption2)
                                        .foregroundStyle(match.completeness.score == match.completeness.maximum ? .green : .orange)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(index == highlightedIndex ? Color.accentColor.opacity(0.1) : .clear)
                            }
                            .buttonStyle(.plain)
                        }
                        if matches.count > 20 {
                            Text("Showing 20 of \(matches.count) matches — refine search")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
            }
        }
    }

    private func wouldSwitchMode(for profile: Profile) -> Bool {
        switch currentViewMode {
        case .pedigree:
            return snapshot.parentsOf(profile.id).isEmpty && !snapshot.childrenOf(profile.id).isEmpty
        case .descendants:
            return snapshot.childrenOf(profile.id).isEmpty && !snapshot.parentsOf(profile.id).isEmpty
        }
    }
}
