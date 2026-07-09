import SwiftUI

@main
struct AncestorViewerApp: App {
    @State private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
