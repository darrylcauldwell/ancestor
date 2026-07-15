import SwiftUI

/// Empty-state view shown when a project has zero profiles.
/// Manual projects get a "Start with yourself" prompt that launches the
/// onboarding wizard. GEDCOM/WikiTree projects get the original guidance.
struct TreePlaceholderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.snapshot.profiles.isEmpty {
            switch appState.currentProject?.source {
            case .manual:
                manualEmptyState
            default:
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "person.3")
                } description: {
                    Text("Import a GEDCOM file or sync from WikiTree to see your family tree.")
                }
            }
        } else {
            List(Array(appState.snapshot.profiles.values).sorted(by: { $0.displayName < $1.displayName })) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.displayName)
                            .font(.headline)
                        if let year = profile.birthDate?.bestYear {
                            Text("b. \(String(year))")
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

    private var manualEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Start with yourself")
                .font(.title2).fontWeight(.semibold)
            Text("Your tree grows from here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                appState.showOnboardingWizard = true
            } label: {
                Label("Begin", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
