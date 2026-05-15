import SwiftUI
import AppKit

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

    @State private var quitKeyMonitor: QuitKeyMonitor = QuitKeyMonitor()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentRoot()
                .environment(sourceRegistry)
                .onAppear { quitKeyMonitor.install() }
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

            // Belt-and-braces explicit Quit. SwiftUI provides Cmd+Q by default
            // through the application menu, but a known macOS quirk is that
            // a TextField with @FocusState inside an active sheet can swallow
            // keyboard events before the menu's command processor sees them.
            // Replacing the default appTermination command group with our own
            // explicit Cmd+Q handler routes the keystroke through SwiftUI's
            // command system rather than the responder chain, so it fires even
            // when the wizard's text fields hold focus.
            CommandGroup(replacing: .appTermination) {
                Button("Quit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Ancestor Research")") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

/// Low-level Cmd+Q interceptor installed via NSEvent.addLocalMonitorForEvents.
///
/// SwiftUI's `.commands { CommandGroup(replacing: .appTermination) ... }`
/// route Cmd+Q through the menu command system — but that path can be silently
/// consumed by a `TextField` with `@FocusState` inside an active sheet. The
/// NSEvent monitor runs BEFORE the SwiftUI responder chain processes key
/// events, so it fires even when text fields hold focus.
///
/// Class (rather than struct) because the monitor token is opaque and needs a
/// stable storage location to be removed cleanly on app termination.
@MainActor
final class QuitKeyMonitor {
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Cmd+Q (or Cmd+q): terminate the app, consuming the event so no
            // downstream responder sees it.
            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),  // Cmd+Shift+Q is "Quit and Keep Windows" — let system handle
               !event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.control),
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return nil // swallow the event
            }
            return event
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
