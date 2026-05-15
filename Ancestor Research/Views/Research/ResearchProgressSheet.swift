import SwiftUI

/// In-situ research-progress sheet shown after the user picks mode/scope
/// from `ResearchConfigSheet`. Wraps `ResearchProgressView` with title bar,
/// status footer, and a Done button so the user can dismiss once the run
/// completes (or close early — research keeps running in the background).
struct ResearchProgressSheet: View {
    @Bindable var vm: ResearchViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(.title2).fontWeight(.semibold)
                Spacer()
            }
            .padding(20)
            Divider()

            ResearchProgressView(vm: vm)
                .frame(minWidth: 560, minHeight: 420)

            Divider()
            HStack {
                if vm.isResearching {
                    Text("Running in the background. You can close this and check progress on the Research tab.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
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
                Button(vm.isResearching ? "Close" : "Done") { onDismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            // Opaque footer background — belt-and-braces in case any
            // scrollable content above tries to spill into the footer
            // region. The activity feed's own clip is the primary defence.
            .background(.regularMaterial)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var headerTitle: String {
        if vm.isResearching { return "Researching…" }
        if vm.wasCancelled { return "Research cancelled" }
        return "Research complete"
    }
}
