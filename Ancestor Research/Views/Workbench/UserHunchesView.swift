import SwiftUI

/// User-seeded hunch surface (RESEARCH_PIPELINE_SPEC §5.15.7 phase b +
/// §5.15.8 refuted/exhausted UX). Lists the hunches the user asked the
/// engine to test for one subject, each with its verdict; refuted hunches
/// sort to the top so an answered-and-refuted question is never buried,
/// and exhausted hunches collapse into a revivable archive.
///
/// Doctrine unchanged: nothing here writes to the tree. The "Add a hunch"
/// button opens `AddHunchView`, which seeds a queued row; dismiss flips
/// `user_rejected` and keeps the verdict history.
struct UserHunchesView: View {
    @Environment(AppState.self) private var appState

    /// Subject whose hunches these are. When nil, the view prompts the
    /// user to select a person first.
    let subjectID: String?

    @State private var model = UserHypothesisViewModel()
    @State private var showingAddHunch = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingAddHunch, onDismiss: reload) {
            AddHunchView(subjectID: subjectID)
        }
        .onAppear(perform: reload)
        .onChange(of: subjectID) { _, _ in reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(subjectName.map { "Hunches — \($0)" } ?? "Hunches")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingAddHunch = true
            } label: {
                Label("Add a hunch", systemImage: "lightbulb")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(subjectID == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if subjectID == nil {
            ContentUnavailableView(
                "Select a person",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Choose someone in the tree to record and test a hunch about their parents.")
            )
        } else if model.hunches.isEmpty {
            ContentUnavailableView(
                "No hunches yet",
                systemImage: "lightbulb",
                description: Text("Think you know who this person's parents were? Add a hunch and the engine will look for the records — it never touches your tree until real evidence lands.")
            )
        } else {
            List {
                if !model.refutedHunches.isEmpty {
                    Section("Refuted") {
                        ForEach(model.refutedHunches) { hunch in
                            row(hunch)
                        }
                    }
                }
                if !model.activeHunches.isEmpty {
                    Section("In play") {
                        ForEach(model.activeHunches) { hunch in
                            row(hunch)
                        }
                    }
                }
                if !model.exhaustedHunches.isEmpty {
                    Section("Exhausted") {
                        Text("Every avenue searched, no result. Kept so the engine won't silently re-try them.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                        ForEach(model.exhaustedHunches) { hunch in
                            row(hunch)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row

    private func row(_ hunch: UserHypothesisViewModel.Hunch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(hunch.statusLabel)
                    .font(AppTypography.badge)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                    .foregroundStyle(AnyShapeStyle(verdictColour(hunch)))
                if hunch.attempts > 0 {
                    Text("tested ×\(hunch.attempts)")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(hunch.lastTestedAt, style: .relative)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
            Text(hunch.coupleSummary)
                .font(AppTypography.cardBody)
            if !hunch.reasoning.isEmpty {
                Text(hunch.reasoning)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Dismiss") { model.dismiss(hunchID: hunch.id) }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    private func verdictColour(_ hunch: UserHypothesisViewModel.Hunch) -> Color {
        switch hunch.verdict {
        case .supported: return .green
        case .contradicted: return .red
        case .inconclusive: return hunch.isExhausted ? .orange : .secondary
        }
    }

    // MARK: - Data

    private var subjectName: String? {
        guard let subjectID else { return nil }
        return appState.snapshot.profiles[subjectID]?.displayName
    }

    private func reload() {
        model.database = appState.currentDatabase
        model.snapshot = appState.snapshot
        if let subjectID {
            model.load(profileID: subjectID)
        } else {
            model.hunches = []
        }
    }
}
