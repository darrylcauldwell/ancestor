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

    /// Shared across windows — the corpus registry lives in
    /// Application Support, is machine-wide, and a crawl initiated
    /// from one settings window must be visible from another. Single
    /// instance is correct. Failure to resolve Application Support is
    /// non-fatal: the service falls back to an in-memory registry
    /// rooted at a temp directory so the Settings UI still renders
    /// (the Add button simply won't persist across launches).
    @State private var proseCorpusService: ProseCorpusService = {
        if let service = try? ProseCorpusService.makeForProduction() {
            return service
        }
        // Degraded mode — Application Support unreachable. The temp
        // directory at least keeps the app launchable; the user sees
        // an empty Prose Corpora section with no entries.
        let fallbackBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AncestorResearchFallback", isDirectory: true)
        let registry = ProseCorpusRegistry(baseDirectory: fallbackBase)
        let adder = ProseCorpusAdder(registry: registry, http: SourceHTTPClient.shared)
        return ProseCorpusService(adder: adder)
    }()

    @State private var quitKeyMonitor: QuitKeyMonitor = QuitKeyMonitor()

    /// Shared across windows — the bridge that lets the detached Record
    /// Review window borrow the main window's AppState and receive the
    /// live result at pop-out. See `ReviewWindowBroker`.
    @State private var reviewWindowBroker = ReviewWindowBroker()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentRoot()
                .environment(sourceRegistry)
                .environment(proseCorpusService)
                .environment(reviewWindowBroker)
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

        // Detached Record Review window (owner request 2026-07-21): the
        // record review in its own movable window, keyed by profileID —
        // opening the same person again focuses the existing window. The
        // main window stays free for tree navigation while reviewing.
        WindowGroup("Record Review", id: "record-review", for: String.self) { $profileID in
            if let profileID {
                ReviewWindowRoot(profileID: profileID)
                    .environment(sourceRegistry)
                    .environment(proseCorpusService)
                    .environment(reviewWindowBroker)
            } else {
                // Value-less open (e.g. Window menu) — nothing to review.
                ContentUnavailableView(
                    "No review selected",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Pop a review out from Triage or the Research tab.")
                )
                .frame(minWidth: 720, minHeight: 520)
            }
        }
        .defaultSize(width: 940, height: 720)
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
    @AppStorage("reasoningModelChoice") private var reasoningModelChoiceRaw: String = ReasoningModel.default.rawValue
    /// Opt-IN launch load (owner decision 2026-07-30). Default OFF: the
    /// reasoning model stays unloaded until the user loads it in Settings
    /// (or enables this toggle there). Every AI path has a deterministic
    /// fallback, so unloaded is the app's honest baseline — the previous
    /// always-on auto-load silently re-armed the AI tier on every
    /// relaunch, which made AI-vs-deterministic comparisons impossible
    /// to keep clean.
    @AppStorage("autoLoadReasoningModelAtLaunch") private var autoLoadReasoningModelAtLaunch = false
    // PROJECT_ONBOARDING_SPEC Part A Step 2 — the user's consent to use the
    // semantic clustering embedder. Default off (core doctrine: fully
    // functional deterministically with no model). Shared across windows.
    @AppStorage("semanticEmbedderEnabled") private var semanticEmbedderEnabled = false
    @Environment(ReviewWindowBroker.self) private var reviewWindowBroker

    var body: some View {
        ContentView()
            .environment(appState)
            .task { await autoLoadReasoningModelIfOnDisk() }
            .task { await autoLoadEmbedderIfEnabledAndPresent() }
            // Register this window's AppState as the one the detached
            // Record Review window borrows. Last-registered wins — with
            // multiple main windows the most recently opened is the
            // review window's anchor (documented limitation; the common
            // case is a single main window).
            .onAppear { reviewWindowBroker.activeAppState = appState }
            // Explicit deregistration on window close (identity-guarded so a
            // closing older window can't clobber a newer one's registration).
            // The weak var would zero anyway, but assigning nil through the
            // @Observable setter makes the change visible to the review
            // window's body immediately.
            .onDisappear {
                if reviewWindowBroker.activeAppState === appState {
                    reviewWindowBroker.activeAppState = nil
                }
            }
    }

    /// Auto-loads the user's selected reasoning model on app launch if the
    /// safetensors files are already on disk. Avoids the per-relaunch
    /// click-Load-Model dance for users who've completed the download.
    /// Idempotent: subsequent windows or repeat calls return early because
    /// `LocalInferenceService.loadModel` short-circuits when already loaded.
    ///
    /// Skipped under XCTest. The test target launches a full app instance,
    /// so this `.task` would otherwise fire concurrently with the user's
    /// running app — both processes racing to memory-map the same 14B
    /// safetensors triggers an MLX `_mlx_error` that calls
    /// `Swift.assertionFailure` and terminates the test host. Detected via
    /// `XCTestConfigurationFilePath`, the env var Xcode sets for any
    /// xctest run.
    private func autoLoadReasoningModelIfOnDisk() async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        // Launch-load is opt-in (default off) — see the property doc.
        guard autoLoadReasoningModelAtLaunch else { return }
        let model = ReasoningModel(rawValue: reasoningModelChoiceRaw) ?? .default
        // 1 GB threshold filters out partial/empty model directories — only
        // proceed when the model is plausibly complete on disk.
        guard LocalInferenceService.shared.onDiskBytes(for: model) > 1_000_000_000 else {
            return
        }
        _ = try? await LocalInferenceService.shared.loadModel(configuration: model.configuration)
    }

    /// PROJECT_ONBOARDING_SPEC Part A Step 2 / B.4 — auto-USE the semantic
    /// embedder once it is present, so the user opts in once (Settings / the
    /// setup wizard) rather than clicking "Use semantic model" every session.
    /// NEVER auto-downloads: it loads only when the user has enabled it AND the
    /// files are already on disk. Same XCTest guard as the reasoning auto-load.
    private func autoLoadEmbedderIfEnabledAndPresent() async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        guard semanticEmbedderEnabled else { return }
        #if canImport(MLXEmbedders) && canImport(MLX)
        guard MLXTextEmbedder.shared.isDownloaded() else { return }
        try? await MLXTextEmbedder.shared.loadModel()
        #endif
    }
}
