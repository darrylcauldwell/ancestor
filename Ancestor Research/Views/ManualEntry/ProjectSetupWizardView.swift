import SwiftUI

/// PROJECT_ONBOARDING_SPEC Part A — the project SETUP wizard (distinct from
/// the family-entry `OnboardingWizardView`). A short, skippable flow shown once
/// per project at create / GEDCOM import / WikiTree connect, surfacing the
/// settings that materially change research quality but are otherwise
/// discoverable-by-accident.
///
/// Slice 1 (this build): Step 1 — home region / Chapman anchor. Step 2 (enable
/// local AI) is a later slice; the chrome, once-per-project lifecycle, and
/// re-run-from-Settings land here so Step 2 slots in without new plumbing.
///
/// Doctrine: nothing here blocks diving in. Every step is skippable and the
/// default (no anchor → derive per profile) leaves the project fully usable.
struct ProjectSetupWizardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome
    /// The picked Chapman code ("" = none / derive per profile). Seeded from
    /// whatever the project already has so re-running setup shows the current
    /// choice rather than resetting it.
    @State private var homeChapmanCode: String = ""
    @State private var seeded = false

    private enum Step: Int, CaseIterable {
        case welcome        // Step 0 — orientation
        case homeRegion     // Step 1 — Chapman anchor

        var title: String {
            switch self {
            case .welcome:    return "A couple of quick choices"
            case .homeRegion: return "Where is this family mostly from?"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .welcome:    welcomeStep
                    case .homeRegion: homeRegionStep
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            guard !seeded else { return }
            homeChapmanCode = appState.currentProject?.homeChapmanCode ?? ""
            seeded = true
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up this project")
                .font(.title3).fontWeight(.semibold)
            Text(step.title)
                .font(.title2).fontWeight(.semibold)
            ProgressView(value: progress)
                .tint(.accentColor)
        }
        .padding(20)
    }

    private var progress: Double {
        Double(step.rawValue + 1) / Double(Step.allCases.count)
    }

    // MARK: - Step 0 — Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This takes about a minute and you can skip any part — the app works fully with the defaults.")
                .foregroundStyle(.secondary)
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Home region").fontWeight(.semibold)
                    Text("The county your research falls back to when a record has no place of its own. The single biggest lever on search quality.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "map").foregroundStyle(.blue)
            }
            Text("You can change any of this later in Settings.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 1 — Home region

    private var homeRegionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick the county most of this family comes from. It anchors searches for any relative whose own birth place can't provide one — people who already have a location keep deriving their own county.")
                .foregroundStyle(.secondary)

            // Same registry + tags the Settings home-county picker uses, so the
            // two never diverge. "" = derive per profile (no hardcoded region).
            Picker("Home county", selection: $homeChapmanCode) {
                Text("None — derive per profile").tag("")
                ForEach(UKChapmanCodes.shared.gbAndChannelIslands(), id: \.code) { entry in
                    Text("\(entry.name) (\(entry.code))").tag(entry.code)
                }
            }
            .pickerStyle(.menu)

            if homeChapmanCode.isEmpty {
                Text("No anchor set — each profile derives its own county from its birth location. You can set one any time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { back() }
                    .buttonStyle(.glass)
            }
            Spacer()
            Button("Skip setup") { finish() }
                .buttonStyle(.glass)
                .controlSize(.small)
            if step == .homeRegion {
                Button("Done") {
                    appState.setHomeChapmanCode(homeChapmanCode)
                    finish()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { advance() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Navigation

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    /// Mark setup done (so it never auto-offers again) and close. Both "Done"
    /// and "Skip setup" route here — skipping is a valid completion.
    private func finish() {
        appState.finishSetup()
        dismiss()
    }
}
