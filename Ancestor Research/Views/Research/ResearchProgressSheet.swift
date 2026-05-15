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
                Text(vm.isResearching ? "Researching…" : "Research complete")
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
}
