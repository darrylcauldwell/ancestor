import SwiftUI

/// In-situ research-progress sheet shown after the user picks mode/scope
/// from `ResearchConfigSheet`. Wraps `ResearchProgressView` with title bar,
/// status footer, and a Done button so the user can dismiss once the run
/// completes (or close early — research keeps running in the background).
struct ResearchProgressSheet: View {
    @Bindable var vm: ResearchViewModel
    let onDismiss: () -> Void
    /// Fired when the user picks "Open Settings" from the local-AI-not-loaded
    /// alert. ContentView routes this to switch the sidebar tab to Settings
    /// and close the sheet. Optional so existing call sites continue to
    /// work even if they don't surface that path.
    var onOpenSettings: (() -> Void)? = nil

    private var aiGatePresented: Binding<Bool> {
        Binding(
            get: { vm.aiGate != nil },
            set: { if !$0 { vm.aiGate = nil } }
        )
    }

    private var aiGateMessage: String {
        guard let gate = vm.aiGate else { return "" }
        if gate.modelOnDisk {
            return "\(gate.modelDisplayName) is downloaded but not loaded. Open Settings to load it (~10–30 s). Or run without AI assistance — Level-2 focused queries will be skipped."
        } else {
            return "\(gate.modelDisplayName) needs to be downloaded (~8 GB, one-time) and loaded before AI-assisted research is available. Open Settings to start the download, or run without AI for now."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(.title2).fontWeight(.semibold)
                Spacer()
            }
            .padding(20)
            Divider()

            ResearchProgressView(vm: vm, onOpenSettings: onOpenSettings)
                .frame(minWidth: 560, minHeight: 420)

            Divider()
            HStack {
                if vm.isResearching {
                    Text("Running in the background. You can close this and check progress on the Research tab.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                } else if let result = vm.currentResult, result.consensusProposalCount > 0 {
                    // Slice B3 — surface subject-self-narrowing proposals so
                    // the user notices them in Triage. Per
                    // `SUBJECT_SELF_NARROWING_SPEC.md` §6: footer-only,
                    // no accept/reject here — the real decision happens
                    // in Triage where the supporting evidence renders.
                    let n = result.consensusProposalCount
                    let plural = n == 1 ? "" : "s"
                    Label("\(n) narrowing proposal\(plural) — review in Triage", systemImage: "sparkles")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.blue)
                }
                Spacer()
                if vm.isResearching {
                    Button(role: .destructive) {
                        vm.cancelResearch()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut(".", modifiers: .command)
                }
                // The dismiss hands off to Triage where the run's review
                // renders immediately — say so (owner request 2026-07-15:
                // 'Done' read as a dead end and sent the user hunting).
                Button(vm.isResearching
                       ? "Close"
                       : (vm.currentResult != nil ? "Review results" : "Done")) { onDismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .frame(minWidth: 560, minHeight: 520)
        .alert("Local AI Not Loaded", isPresented: aiGatePresented) {
            Button("Open Settings") {
                vm.aiGate = nil
                onOpenSettings?()
            }
            Button("Run Without AI") {
                let gate = vm.aiGate
                vm.aiGate = nil
                if let gate { Task { await gate.proceed() } }
            }
            Button("Cancel", role: .cancel) {
                vm.aiGate = nil
                onDismiss()
            }
        } message: {
            Text(aiGateMessage)
        }
    }

    private var headerTitle: String {
        if vm.isResearching { return "Researching…" }
        if vm.wasCancelled { return "Research cancelled" }
        return "Research complete"
    }
}
