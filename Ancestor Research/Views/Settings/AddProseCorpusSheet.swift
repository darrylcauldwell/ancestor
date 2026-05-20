import SwiftUI

/// Add-a-prose-corpus sheet. Single-form flow with an inline verify
/// step: the user fills in URL + (optional) title + (optional)
/// advanced options, clicks **Verify**, sees the probe result and
/// any warnings, then clicks **Add and crawl** to commit.
///
/// The two-step modal alternative was rejected as overkill — most
/// users will paste a known-good URL, the verify result will be clean,
/// and a single form lets them confirm in one mental hop. The verify
/// panel sits below the form so warnings don't push the Add button
/// off-screen.
struct AddProseCorpusSheet: View {
    @Environment(ProseCorpusService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var urlString: String = ""
    @State private var displayTitle: String = ""
    @State private var crawlDepth: Int = 4
    @State private var pageBudget: Int = 10_000
    @State private var linkFilterKind: LinkFilterKind = .none
    @State private var linkFilterPattern: String = ""
    @State private var showingAdvanced: Bool = false
    /// Set once Verify has been run for the current URL string.
    /// Cleared when the URL field changes so stale verifications
    /// never gate an Add against the wrong seed.
    @State private var verifiedURL: URL?

    private enum LinkFilterKind: String, CaseIterable, Identifiable {
        case none, glob, regex
        var id: Self { self }
        var label: String {
            switch self {
            case .none: return "None"
            case .glob: return "Glob"
            case .regex: return "Regex"
            }
        }
    }

    private var parsedURL: URL? {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true, url.host != nil else {
            return nil
        }
        return url
    }

    private var verificationApplies: Bool {
        guard let url = verifiedURL, let parsed = parsedURL else { return false }
        return url == parsed
    }

    /// Add is only enabled after a verification that applies to the
    /// current URL field, and the verification is not blocking.
    private var canAdd: Bool {
        guard verificationApplies, let v = service.pendingVerification else { return false }
        if v.hasBlockingProblems { return false }
        if displayTitle.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    seedSection
                    if showingAdvanced { advancedSection }
                    verifySection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 480, idealHeight: 560)
        .onDisappear { service.clearVerification() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add Prose Corpus")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Crawl a parish-record, local-history, or county-record-office site into a local markdown corpus the research agent can search.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Seed URL")
                    .font(.headline)
                TextField("https://example.com/index.htm", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: urlString) { _, _ in
                        // Invalidate verification — old probe doesn't apply.
                        verifiedURL = nil
                        service.clearVerification()
                    }
                Text("The crawler walks same-host links from this URL. Linked pages on other hosts are recorded but not followed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Display title")
                    .font(.headline)
                TextField("e.g. Wirksworth Parish Records 1600-1900", text: $displayTitle)
                    .textFieldStyle(.roundedBorder)
                Text("Used in the corpora list and in research-activity entries. Defaults to the seed page's title after verifying.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced options", isExpanded: $showingAdvanced) {
                EmptyView()
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Maximum crawl depth: \(crawlDepth)")
                    .font(.callout)
                Slider(
                    value: Binding(
                        get: { Double(crawlDepth) },
                        set: { crawlDepth = Int($0) }
                    ),
                    in: 1...8,
                    step: 1
                )
                Text("How many link-hops from the seed to follow. Defaults to 4 — most volunteer sites are 2-3 hops deep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Page budget")
                    .font(.callout)
                TextField("10000", value: $pageBudget, format: .number)
                    .textFieldStyle(.roundedBorder)
                Text("Soft cap on pages fetched. The crawler stops with a warning if hit and leaves the partial corpus usable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Link filter")
                    .font(.callout)
                Picker("Filter kind", selection: $linkFilterKind) {
                    ForEach(LinkFilterKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                if linkFilterKind != .none {
                    TextField(linkFilterKind == .glob ? "*/PEDIGREE.htm" : "\\.htm$", text: $linkFilterPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Text("Optional pattern URLs must match to be enqueued. Leave as **None** to follow every same-host link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
    }

    private var verifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await runVerify() }
                } label: {
                    if service.isVerifying {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Verifying…")
                        }
                    } else {
                        Text(verificationApplies ? "Re-verify" : "Verify")
                    }
                }
                .buttonStyle(.glass)
                .disabled(parsedURL == nil || service.isVerifying)
                Spacer()
            }
            if let result = service.pendingVerification, verificationApplies {
                verificationResultView(result)
            } else if parsedURL == nil && !urlString.isEmpty {
                Label("That doesn't look like an http or https URL.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func verificationResultView(_ result: SiteVerification) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if !result.reachable {
                    Label("Seed URL did not return a usable response.", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    if let reason = result.unreachableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Seed reachable.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        if let title = result.seedTitle {
                            Text("**Page title:** \(title)")
                                .font(.callout)
                        }
                        Text("**Same-host links on seed:** \(result.outboundSameHostLinks)")
                            .font(.callout)
                        Text("**External-host links:** \(result.outboundExternalLinks)")
                            .font(.callout)
                        if result.robotsFetched {
                            Text("**robots.txt:** fetched")
                                .font(.callout)
                        } else {
                            Text("**robots.txt:** not present — crawler will treat as allow-all")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !result.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Add and Crawl") {
                Task { await runAdd() }
            }
            .buttonStyle(.glassProminent)
            .disabled(!canAdd)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    // MARK: - Actions

    private func runVerify() async {
        guard let url = parsedURL else { return }
        await service.verify(seedURL: url)
        verifiedURL = url
        // Auto-populate the title if empty and the seed has one.
        if displayTitle.isEmpty, let title = service.pendingVerification?.seedTitle {
            displayTitle = title
        }
    }

    private func runAdd() async {
        guard let url = parsedURL else { return }
        let filter: ProseCorpusCrawler.LinkFilter? = {
            let trimmed = linkFilterPattern.trimmingCharacters(in: .whitespaces)
            guard linkFilterKind != .none, !trimmed.isEmpty else { return nil }
            switch linkFilterKind {
            case .glob: return .glob(trimmed)
            case .regex: return .regex(trimmed)
            case .none: return nil
            }
        }()
        await service.add(
            seedURL: url,
            displayTitle: displayTitle.trimmingCharacters(in: .whitespaces),
            crawlDepth: crawlDepth,
            pageBudget: pageBudget,
            linkFilter: filter
        )
        dismiss()
    }
}
