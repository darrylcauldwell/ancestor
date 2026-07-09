import SwiftUI
import AncestorViewerKit

struct ContentView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                StatusScreen(
                    systemImage: "icloud.and.arrow.down",
                    title: "Loading your family tree…",
                    message: "Fetching the published tree from iCloud.",
                    showsProgress: true)
            case .noAccount:
                StatusScreen(
                    systemImage: "person.icloud",
                    title: "Sign in to iCloud",
                    message: "This Apple TV must be signed into the same iCloud account that publishes the tree from the Mac app. Sign in from Settings, then relaunch.")
            case .notPublished:
                StatusScreen(
                    systemImage: "tree",
                    title: "No published tree yet",
                    message: "Publish your tree from Ancestor Research on the Mac (Publish Tree to iCloud…), then relaunch.")
            case .failed(let message):
                StatusScreen(
                    systemImage: "exclamationmark.icloud",
                    title: "Couldn't load the tree",
                    message: message)
            case .ready:
                if let tree = model.tree {
                    TreeScreen(tree: tree)
                }
            }
        }
        .task { await model.launch() }
    }
}

/// Full-screen state card — no-account, not-published, loading, failure.
struct StatusScreen: View {
    let systemImage: String
    let title: String
    let message: String
    var showsProgress = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: systemImage)
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text(title)
                .font(AppTypography.screenTitle)
            Text(message)
                .font(AppTypography.cardBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            if showsProgress {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
