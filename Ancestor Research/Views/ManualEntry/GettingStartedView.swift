import SwiftUI

/// PROJECT_ONBOARDING_SPEC Part B — the re-openable "Getting Started" overview.
/// A single, low-maintenance explainer: how the pieces fit, then one concise
/// blurb per major view answering "what is this for". Deliberately NOT
/// coordinate-glued coach marks (those go stale every time the UI moves) — this
/// is plain prose that survives layout churn.
///
/// Opened from the toolbar "?", from Settings, and offered at the end of setup.
/// When opened via the toolbar it scrolls to the section for the tab you're on.
struct GettingStartedView: View {
    @Environment(\.dismiss) private var dismiss

    /// The view to scroll to on open (the tab the user opened help from).
    var focusTab: SidebarTab?

    /// One help entry per major view. Copy states each view's ACTUAL current
    /// purpose (Part B.3 acceptance) — keep it in step with what the views do.
    struct Entry: Identifiable {
        let tab: SidebarTab
        let icon: String
        let blurb: String
        var id: String { tab.rawValue }
    }

    /// Every sidebar tab must have a help entry (a `GettingStartedTests`
    /// completeness guard fails if a new tab is added without one).
    static let entries: [Entry] = [
        Entry(tab: .tree, icon: "tree",
              blurb: "Your family tree — everything you already know. Click a person to inspect them, right-click for actions, and set a home person to anchor navigation. Accepted records land here."),
        Entry(tab: .research, icon: "magnifyingglass",
              blurb: "Pick a person and search the free record sources for evidence about them. Results don't change the tree until you review them."),
        Entry(tab: .triage, icon: "tray.full",
              blurb: "Review what research found. Accept the records that match onto the profile; discard the rest — discards are remembered so they don't come back."),
        Entry(tab: .tasks, icon: "checklist",
              blurb: "Data-quality issues across the whole tree — missing dates, muddled identities, a wife with no married surname — many with a one-click fix."),
        Entry(tab: .sourcing, icon: "doc.text.magnifyingglass",
              blurb: "Which facts are backed by a citation and which still need evidence, so you can see how well-sourced the tree is at a glance."),
        Entry(tab: .workbench, icon: "square.grid.2x2",
              blurb: "Your research workspace — notes, open questions, hunches, and focus sets for the line you're working on."),
        Entry(tab: .settings, icon: "gearshape",
              blurb: "Home region, local AI models, which sources to use, backups — and “Re-run setup” to revisit these choices."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        overview
                        Divider()
                        ForEach(Self.entries) { entry in
                            entryRow(entry).id(entry.tab.rawValue)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    guard let focusTab else { return }
                    // Let the layout settle, then scroll to the section for the
                    // tab help was opened from.
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo(focusTab.rawValue, anchor: .top) }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Getting started")
                .font(.title2).fontWeight(.semibold)
            Text("How the pieces fit, and what each area is for.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The flow")
                .font(.title3).fontWeight(.semibold)
            Text("Ancestor keeps a private, well-sourced copy of your family tree and researches it against free UK record sources. The loop is: your **Tree** holds what you know → **Research** finds new records → **Triage** is where you accept the right ones → accepted evidence flows back onto the Tree. **Tasks** flags data-quality issues, **Sourcing** shows citation coverage, and the **Workbench** holds your notes and questions.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing you don't confirm ever changes the tree, and the app works fully without any AI models.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func entryRow(_ entry: Entry) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.tab.rawValue).font(.headline)
                Text(entry.blurb)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: entry.icon).foregroundStyle(.blue)
                .frame(width: 24)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
