import SwiftUI
import AncestorKit

// WikiTree contribution preview (WT3 — WIKITREE_MERGEEDIT_SPEC §5).
//
// Shows EXACTLY what a MergeEdit contribution will propose — field diffs
// (WikiTree's last-known value → the app's research-backed value), the
// research-notes bio addition, and anything MergeEdit cannot carry — before
// opening WikiTree's own review page in the browser. Nothing is saved until
// Darryl confirms there; the sheet says so in as many words.

/// Identifiable wrapper for `.sheet(item:)` (feedback_sheet_isPresented_race).
struct WikiTreeContributeContext: Identifiable {
    let id = UUID()
    let profile: Profile
    let lifeEvents: [LifeEvent]
}

struct WikiTreeContributeSheet: View {
    let context: WikiTreeContributeContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var openedFileURL: URL?
    @State private var launchError: String?

    private var payload: WikiTreeMergeEditPayload? {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return WikiTreeMergeEdit.build(
            profile: context.profile,
            lifeEvents: context.lifeEvents,
            currentYear: Calendar.current.component(.year, from: Date()),
            date: formatter.string(from: Date()))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Contribute to WikiTree", systemImage: "arrow.up.doc")
                    .font(AppTypography.popoverTitle)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    @ViewBuilder
    private var content: some View {
        if openedFileURL != nil {
            openedView
        } else if let payload {
            previewView(payload)
        } else {
            nothingToContributeView
        }
    }

    // MARK: - Preview

    private func previewView(_ payload: WikiTreeMergeEditPayload) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Profile") {
                    LabeledContent("WikiTree ID", value: payload.userName)
                }
                if !payload.personFields.isEmpty {
                    Section("Field changes (each needs your tick on WikiTree)") {
                        ForEach(payload.personFields.keys.sorted(), id: \.self) { field in
                            LabeledContent(field) {
                                let old = payload.expectedFields[field] ?? ""
                                Text("\(old.isEmpty ? "—" : old)  →  \(payload.personFields[field] ?? "")")
                                    .font(AppTypography.cardBody)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let bio = payload.bioAppend {
                    Section("Added to the biography") {
                        Text(bio)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if !payload.manualNotes.isEmpty {
                    Section("Needs a manual edit (MergeEdit can't carry these)") {
                        ForEach(payload.manualNotes, id: \.self) { note in
                            Label(note, systemImage: "hand.point.right")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    LabeledContent("Change summary", value: payload.summary)
                        .font(AppTypography.cardMeta)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let launchError {
                    Text(launchError)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Open WikiTree Review Page") { openReviewPage(payload) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private var openedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Review page opened in your browser")
                .font(AppTypography.cardTitle)
            Text("Nothing has been saved. WikiTree shows each proposed change with a checkbox — review and save there. This offer is logged locally; whether it was saved only shows up after a future WikiTree sync.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nothingToContributeView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing to contribute yet")
                .font(AppTypography.cardTitle)
            Text(ineligibilityReason)
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Close") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ineligibilityReason: String {
        let profile = context.profile
        if (profile.wikiTreeID ?? "").isEmpty {
            return "This profile has no WikiTree ID — contributions need a linked WikiTree profile."
        }
        if FamilySearchTreeEncoder.isLiving(
            profile, currentYear: Calendar.current.component(.year, from: Date())) {
            return "Living (or possibly living) people never leave the app."
        }
        return "No research-backed changes differ from what WikiTree already holds — imported values never round-trip back as contributions."
    }

    private func openReviewPage(_ payload: WikiTreeMergeEditPayload) {
        do {
            let url = try WikiTreeMergeEditLauncher.open(payload)
            if let db = appState.currentDatabase {
                let fieldsJSON = (try? JSONSerialization.data(
                    withJSONObject: payload.personFields, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try? db.recordWikiTreeContribution(
                    profileID: context.profile.id,
                    wikiTreeID: payload.userName,
                    fieldsJSON: fieldsJSON,
                    bioAppended: payload.bioAppend != nil,
                    summary: payload.summary)
            }
            openedFileURL = url
        } catch {
            launchError = "Couldn't open the review page: \(error.localizedDescription)"
        }
    }
}
