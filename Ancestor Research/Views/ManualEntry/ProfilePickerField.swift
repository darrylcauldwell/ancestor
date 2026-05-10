import SwiftUI

/// Searchable profile picker with a "Create new instead" toggle.
/// Used by AddFamilyView to switch each parent/child slot between
/// "pick an existing person" and "create a new person".
struct ProfilePickerField: View {
    let label: String
    let snapshot: FamilyGraphSnapshot
    @Binding var selectedID: String?

    @State private var query: String = ""

    private var matches: [Profile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = Array(snapshot.profiles.values).sorted { $0.displayName < $1.displayName }
        guard !trimmed.isEmpty else { return Array(all.prefix(20)) }
        return all.filter { $0.displayName.lowercased().contains(trimmed) }.prefix(20).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let id = selectedID, let profile = snapshot.profiles[id] {
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(profile.displayName)
                        .font(AppTypography.cardBody)
                    if let year = profile.birthDate?.bestYear {
                        Text("b. \(year)")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Change") {
                        selectedID = nil
                        query = ""
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
            } else {
                TextField(label, text: $query, prompt: Text("Search existing people…"))
                    .textFieldStyle(.roundedBorder)
                if !query.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { profile in
                            Button {
                                selectedID = profile.id
                                query = ""
                            } label: {
                                HStack {
                                    Text(profile.displayName)
                                        .font(AppTypography.cardBody)
                                    if let year = profile.birthDate?.bestYear {
                                        Text("b. \(year)")
                                            .font(AppTypography.cardMeta)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                        if matches.isEmpty {
                            Text("No matches.")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 6))
                }
            }
        }
    }
}
