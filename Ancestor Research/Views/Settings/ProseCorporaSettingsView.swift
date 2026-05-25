import SwiftUI

/// Settings section that lists every user-added prose corpus on the
/// machine and exposes Add / Sync / Remove affordances per row.
///
/// Embedded into `SettingsPlaceholderView` as a top-level Section so it
/// sits alongside the existing Project / WikiTree / Sources sections.
/// State comes from the env-injected `ProseCorpusService`; this view
/// is presentation only — no business logic lives here.
struct ProseCorporaSettingsView: View {
    @Environment(ProseCorpusService.self) private var service
    @State private var showingAddSheet: Bool = false
    @State private var corpusPendingRemoval: ProseCorpusService.Row?

    var body: some View {
        Section {
            if service.corpora.isEmpty {
                emptyState
            } else {
                ForEach(service.corpora) { row in
                    corpusRow(row)
                }
            }
            if let error = service.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { service.clearError() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            HStack {
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Corpus", systemImage: "plus.circle")
                }
                .buttonStyle(.glass)
            }
        } header: {
            HStack {
                Text("Prose Corpora")
                Spacer()
                if !service.corpora.isEmpty {
                    Text("\(service.corpora.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Add a parish-record, local-history, or county-record-office site by URL. The crawler walks same-host links into a local markdown corpus the research agent can search.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddProseCorpusSheet()
        }
        .sheet(item: $corpusPendingRemoval) { row in
            RemoveConfirmationSheet(
                row: row,
                isSyncing: service.syncingSourceIDs.contains(row.sourceID)
            ) {
                Task { await service.remove(sourceID: row.sourceID) }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "books.vertical")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No corpora added yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Add one to give the research agent access to long-form parish records and local-history pages.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Row

    private func corpusRow(_ row: ProseCorpusService.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayTitle)
                        .font(.callout)
                        .fontWeight(.medium)
                    if let url = row.seedURL {
                        HyperlinkedText(
                            url.absoluteString,
                            font: .caption,
                            plainColor: .secondary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    statsLine(row)
                }
                Spacer()
                rowActions(row)
            }
            // Persistent partial-crawl warning — survives restart via
            // the manifest's `last_sync_stop_reason` field. Distinct
            // from `lastReportSummary` below, which shows the
            // immediately-post-sync delta (+N new, ~N updated) for
            // the current session only.
            if let label = row.lastSyncStopReasonLabel {
                Label(label, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 2)
            }
            if let report = service.lastReports[row.sourceID] {
                lastReportSummary(report)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statsLine(_ row: ProseCorpusService.Row) -> some View {
        HStack(spacing: 12) {
            if row.hasBeenBuilt {
                Label("\(row.pageCount) pages", systemImage: "doc.text")
                if row.totalBytes > 0 {
                    Text(byteString(row.totalBytes))
                }
                if let synced = row.lastSyncedAt {
                    Text("Synced \(synced.formatted(.relative(presentation: .named)))")
                }
            } else {
                Label("Never built", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func rowActions(_ row: ProseCorpusService.Row) -> some View {
        HStack(spacing: 8) {
            if service.syncingSourceIDs.contains(row.sourceID) {
                ProgressView()
                    .controlSize(.small)
                    .help("Crawling…")
            } else {
                Button {
                    Task { await service.sync(sourceID: row.sourceID) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help(row.hasBeenBuilt ? "Sync" : "Build")
            }
            Button {
                corpusPendingRemoval = row
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove corpus")
            // Intentionally not disabled during sync — a user staring
            // at three duplicate in-flight crawls needs to be able to
            // cancel them. The remove confirmation sheet warns about
            // the in-flight crawl getting interrupted on its next
            // disk write.
        }
    }

    @ViewBuilder
    private func lastReportSummary(_ report: ProseCorpusCrawler.CrawlReport) -> some View {
        HStack(spacing: 12) {
            switch report.stop {
            case .complete:
                Label("Crawl complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .budgetExhausted:
                Label("Page budget reached — corpus is partial", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .circuitBreakerExhausted:
                Label("Host throttled — try again later", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            case .seedFailed(let reason):
                Label("Seed failed: \(reason)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if report.pagesWritten > 0 {
                Text("+\(report.pagesWritten) new")
                    .foregroundStyle(.secondary)
            }
            if report.pagesRewritten > 0 {
                Text("~\(report.pagesRewritten) updated")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Remove-corpus confirmation sheet. Uses `.sheet(item:)` rather than
/// an alert so the spec's "no half-baked dialogs" feedback applies —
/// destructive action gets full visual weight, not a system alert that
/// disappears the moment Cmd+Tab moves focus elsewhere.
private struct RemoveConfirmationSheet: View {
    let row: ProseCorpusService.Row
    /// `true` when a crawl is in flight for this corpus. The
    /// confirmation copy gains an "in-flight crawl will be
    /// interrupted" line so the user isn't surprised.
    let isSyncing: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Remove this corpus?", systemImage: "trash")
                .font(.title3)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayTitle)
                    .font(.headline)
                if let url = row.seedURL {
                    HyperlinkedText(
                        url.absoluteString,
                        font: .caption,
                        plainColor: .secondary
                    )
                }
                if row.hasBeenBuilt {
                    Text("This deletes \(row.pageCount) pages from disk. The on-disk corpus and the registry entry are removed; the source website is untouched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This corpus has never been built. Removing it just clears the registry entry.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if isSyncing {
                    Label("A crawl is currently running. It will be interrupted on its next disk write.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
