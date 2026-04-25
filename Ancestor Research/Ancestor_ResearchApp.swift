import SwiftUI

@main
struct Ancestor_ResearchApp: App {
    @State private var appState = AppState()
    @State private var sourceRegistry: SourceRegistry = {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)
        return registry
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(sourceRegistry)
        }
    }
}
