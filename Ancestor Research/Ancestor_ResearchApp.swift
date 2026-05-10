import SwiftUI

@main
struct Ancestor_ResearchApp: App {
    /// SourceRegistry is shared across windows — it's a read-mostly catalogue
    /// of available record sources keyed by ID, with the only mutable state
    /// being the user's enabled/disabled set (persisted via @AppStorage and
    /// therefore inherently app-wide). Single instance is correct.
    @State private var sourceRegistry: SourceRegistry = {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)
        return registry
    }()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentRoot()
                .environment(sourceRegistry)
        }
        .commands {
            // M23 — multi-window. The standard "New Window" command isn't
            // exposed by SwiftUI's macOS WindowGroup unless we surface it
            // ourselves. CommandGroup(after: .newItem) places this in the
            // File menu directly below the system "New" item. Cmd+N is
            // already taken by the Add Person global shortcut, so we use
            // Cmd+Shift+T for "New Window".
            CommandGroup(after: .newItem) {
                NewWindowCommand()
            }
        }
    }
}

/// Wraps the SwiftUI `openWindow` environment value in a CommandGroup-eligible
/// View so the File menu can spawn additional WindowGroup instances. Each
/// invocation creates a fresh window with its own ContentRoot — and therefore
/// its own AppState — preserving multi-window isolation.
private struct NewWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: "main")
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}

/// Per-window root. Owning `AppState` here (rather than on the App struct)
/// gives every WindowGroup instance its own AppState, so opening a second
/// window doesn't share sidebar selection, sheet presentation, or the
/// currently-selected profile with the first.
///
/// App-wide settings (excludeSensitiveOnExport, gedcomExportFormat,
/// tasksGroupByProfile, showResearchIndicators, manualSaveToastShown) are
/// persisted via @AppStorage / UserDefaults and therefore shared between
/// windows by design — those are user preferences, not per-window state.
struct ContentRoot: View {
    @State private var appState = AppState()

    var body: some View {
        ContentView()
            .environment(appState)
    }
}
