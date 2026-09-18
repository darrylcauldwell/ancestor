import SwiftUI

/// Tree-overlay banner shown when the family graph has multiple connected
/// components. Offers a "Connect them?" call-to-action that opens a picker
/// of the separate groups so the user chooses which island to connect — the
/// app never guesses an anchor — plus a dismiss button to suppress the
/// banner for the rest of the session.
struct DisconnectedBannerView: View {
    let componentCount: Int
    /// Whether a connection suggestion is available (i.e. there are two or
    /// more components with at least one profile in each). When this is
    /// false we still surface the banner but skip the "Connect them?"
    /// affordance — clicking would have nothing to anchor to.
    var canConnect: Bool = true
    var onConnect: () -> Void = {}
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Your tree has \(componentCount) separate groups.")
                .font(AppTypography.cardBody)
            Spacer()
            if canConnect {
                Button("Connect them?") {
                    onConnect()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .help("Add a relationship between profiles in the two largest groups")
                .accessibilityHint("Add a relationship between profiles in the two largest groups")
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help("Dismiss this banner for the rest of the session")
            .accessibilityLabel("Dismiss banner")
            .accessibilityHint("Dismiss this banner for the rest of the session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }
}
