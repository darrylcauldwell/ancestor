import SwiftUI

/// Project onboarding Part B — the re-openable "Getting Started" overview.
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
        Entry(tab: .workbench, icon: "rectangle.grid.2x2",
              blurb: "Your research desk. The Attention section lists everything awaiting review anywhere in the tree — pending facts, leads, relationship proposals — and jumps you to the person's card, where the reviewing happens. Alongside it: notes, open questions, hunches, and focus sets for the line you're working on."),
        Entry(tab: .tasks, icon: "checklist",
              blurb: "Your research worklist — open questions and tentative facts you're actively working, so you always know what to do next."),
        Entry(tab: .places, icon: "mappin.and.ellipse",
              blurb: "Every place your tree names, and how confidently it maps to a registration district. Confident matches are listed too, so you decide what's settled — a place like “Middleton” can mean four different Derbyshire villages, and the app shows you the rivals rather than picking one."),
        Entry(tab: .health, icon: "heart.text.square",
              blurb: "The tree's data quality at a glance — cruft, impossibilities, duplicates, garbled names, suspect places, and missing facts across the whole tree, many with a one-click fix."),
        Entry(tab: .sourcing, icon: "doc.text.magnifyingglass",
              blurb: "Which facts are backed by a citation and which still need evidence, so you can see how well-sourced the tree is at a glance."),
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
            // SC-9 follow-up (review M9): the flow paragraph still walked the
            // retired Research → Triage tabs. Rewritten to match the entries
            // below — review happens on the person's card, routed by the
            // Workbench's Attention section.
            Text("Ancestor keeps a private, well-sourced copy of your family tree and researches it against free UK record sources. The loop is: your **Tree** holds what you know → research runs find new records → the **Workbench**'s Attention section points you at everything awaiting review, which happens on the person's card → accepted evidence flows back onto the Tree. **Health** flags data-quality issues, **Sourcing** shows citation coverage, and **Tasks** is your research worklist.")
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
