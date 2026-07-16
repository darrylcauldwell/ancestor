import SwiftUI

/// Search field with dropdown results that recenters the tree on selection.
struct TreeSearchField: View {
    @Binding var searchText: String
    let allProfiles: [Profile]
    let snapshot: FamilyGraphSnapshot
    let currentViewMode: TreeViewMode
    var onSelect: (String) -> Void
    /// Whether the field is expanded. When false the control is a compact
    /// magnifying-glass button, so it stays out of the toolbar overflow; the
    /// parent drives this (button tap or ⌘F).
    @Binding var isExpanded: Bool

    @State private var highlightedIndex: Int = 0
    @FocusState private var fieldFocused: Bool

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
        Group {
            if isExpanded {
                expandedField
            } else {
                Button { isExpanded = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.body)
                        .padding(7)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.glass)
                .help("Search people (⌘F)")
                .accessibilityLabel("Search people")
                .accessibilityHint("Search for a person by name and centre the tree on them. Keyboard shortcut Command F.")
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { fieldFocused = true }
        }
    }

    private var expandedField: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search people…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($fieldFocused)
                .onChange(of: fieldFocused) { _, focused in
                    // Collapse back to the icon when focus leaves and the field
                    // is empty — keeps the toolbar tidy.
                    if !focused && searchText.isEmpty { isExpanded = false }
                }
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
                                        Text("b. \(String(year))")
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
