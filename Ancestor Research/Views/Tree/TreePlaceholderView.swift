import SwiftUI

/// Placeholder for M3 — will become TreeGraphView with hierarchical layout.
struct TreePlaceholderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.snapshot.profiles.isEmpty {
            ContentUnavailableView {
                Label("No Profiles", systemImage: "person.3")
            } description: {
                Text("Import a GEDCOM file or sync from WikiTree to see your family tree.")
            }
        } else {
            List(Array(appState.snapshot.profiles.values).sorted(by: { $0.displayName < $1.displayName })) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.displayName)
                            .font(.headline)
                        if let year = profile.birthDate?.bestYear {
                            Text("b. \(year)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    let comp = appState.snapshot.completeness(for: profile.id)
                    Text("\(comp.score)/\(comp.maximum)")
                        .font(.caption)
                        .foregroundStyle(comp.score == comp.maximum ? .green : .orange)
                }
            }
            .navigationTitle("Tree (\(appState.snapshot.profiles.count) profiles)")
        }
    }
}
