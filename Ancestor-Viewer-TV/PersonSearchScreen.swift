import SwiftUI
import AncestorKit
import AncestorViewerKit

/// Jump to anyone by name from the sofa — reached by holding select on
/// the tree. Rows are natively focusable; picking one re-roots the tree.
struct PersonSearchScreen: View {
    let tree: ViewerTree
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Profile] {
        let all = tree.snapshot.profiles.values.sorted {
            ($0.displayName, $0.id) < ($1.displayName, $1.id)
        }
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(results) { profile in
                Button {
                    onSelect(profile.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(profile.displayName)
                            .font(AppTypography.cardBody)
                        Spacer()
                        if let years = yearsLabel(profile) {
                            Text(years)
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        if tree.annotations[profile.id]?.isRedacted == true {
                            Image(systemName: "lock")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a person")
            .navigationTitle("People (\(tree.snapshot.profiles.count))")
        }
        .onExitCommand { dismiss() }
    }

    private func yearsLabel(_ profile: Profile) -> String? {
        var parts: [String] = []
        if let birth = profile.birthDate?.bestYear { parts.append("b. \(birth)") }
        if let death = profile.deathDate?.bestYear { parts.append("d. \(death)") }
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }
}
