import SwiftUI

@main
struct AncestorViewerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    ShareAcceptanceRelay.shared.onMetadata = { metadata in
                        Task { await model.acceptShare(metadata) }
                    }
                }
        }
    }
}
