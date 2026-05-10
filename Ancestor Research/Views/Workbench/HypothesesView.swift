import SwiftUI

/// List of hypotheses grouped by confidence (strong → working → speculation).
/// Resolved hypotheses (promoted/dismissed) are folded into a "Resolved"
/// group at the bottom. Tapping a row opens the detail view.
struct HypothesesView: View {
    @Environment(AppState.self) private var appState
    @State private var showingComposer: Bool = false
    @State private var detail: Hypothesis?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.hypotheses.isEmpty {
                ContentUnavailableView(
                    "No hypotheses yet",
                    systemImage: "lightbulb",
                    description: Text("Capture tentative claims you can't yet commit as facts. Promote when you're sure; dismiss with a reason when you're not.")
                )
            } else {
                List {
                    ForEach(HypothesisConfidence.allCases.sorted(by: { $0.groupOrder < $1.groupOrder }), id: \.self) { conf in
                        let group = activeByConfidence[conf] ?? []
                        if !group.isEmpty {
                            Section(conf.displayName) {
                                ForEach(group) { h in
                                    Button { detail = h } label: {
                                        row(for: h)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !resolved.isEmpty {
                        Section("Resolved") {
                            ForEach(resolved) { h in
                                Button { detail = h } label: {
                                    row(for: h)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingComposer) {
            HypothesisComposerView(initial: nil)
        }
        .sheet(item: $detail) { h in
            HypothesisDetailView(hypothesis: h)
        }
    }

    private var activeByConfidence: [HypothesisConfidence: [Hypothesis]] {
        Dictionary(grouping: appState.hypotheses.filter { $0.status == .active }) { $0.confidence }
            .mapValues { $0.sorted { $0.createdAt > $1.createdAt } }
    }

    private var resolved: [Hypothesis] {
        appState.hypotheses
            .filter { $0.status.isResolved }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
    }

    private var header: some View {
        HStack {
            Text("\(appState.hypotheses.count) hypotheses")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingComposer = true
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(for h: Hypothesis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(h.claim.kind.displayName)
                    .font(AppTypography.badge)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                if h.status != .active {
                    Text(h.status.displayName)
                        .font(AppTypography.badge)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .foregroundStyle(AnyShapeStyle(statusColour(h.status)))
                }
                Spacer()
                Text(h.createdAt, style: .relative)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
            Text(h.claimSummary)
                .font(AppTypography.cardBody)
            if !h.reasoning.isEmpty {
                Text(h.reasoning)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func statusColour(_ status: HypothesisStatus) -> Color {
        switch status {
        case .promoted: return .green
        case .dismissed: return .red
        case .superseded: return .orange
        case .active: return .secondary
        }
    }
}
