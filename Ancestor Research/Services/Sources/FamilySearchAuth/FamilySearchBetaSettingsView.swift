import SwiftUI

/// Settings surface for the FamilySearch OAuth session (Beta). Replaces the
/// retired cookie sign-in. This is the live-handshake UX for the FS pivot
/// (owner 2026-07-21): set the confidential Beta AppKey, sign in through the
/// browser + loopback OAuth flow, and verify the token reaches the API. Once
/// this passes on Beta, the enrichment / Tree-API integration builds on the
/// same OAuth foundation.
///
/// Developer Program Level = non-production / Beta only, so the environment is
/// fixed to `.beta` here.
struct FamilySearchBetaSettingsView: View {
    private let environment: FamilySearchEnvironment = .beta

    @State private var appKeyConfigured = false
    @State private var appKeyDraft = ""
    @State private var signedIn = false
    @State private var tokenExpiry: Date?
    @State private var signingIn = false
    @State private var probing = false
    @State private var statusMessage: String?

    // Tree-API spike inputs/output (diagnostic — learn the real contract).
    @State private var probeGiven = ""
    @State private var probeSurname = ""
    @State private var probeYear = ""
    @State private var probePersonID = ""
    @State private var treeProbing = false
    @State private var probeSummary: String?
    @State private var probeRaw: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            appKeyRow
            Divider()
            sessionRow
            if let statusMessage {
                Text(statusMessage)
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Beta (non-production) only. Records come from the free direct sources; FamilySearch is used for enrichment/hints and document-image links, not as a data source.")
                .font(AppTypography.badge)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refresh() }
    }

    // MARK: - AppKey

    @ViewBuilder
    private var appKeyRow: some View {
        if appKeyConfigured {
            Label("Beta AppKey configured", systemImage: "key.fill")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Beta AppKey")
                    .font(AppTypography.cardTitle)
                Text("Confidential — stored only in the macOS Keychain, never in git.")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
                HStack {
                    SecureField("Paste your FamilySearch Beta AppKey", text: $appKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let key = appKeyDraft.trimmingCharacters(in: .whitespaces)
                        appKeyDraft = ""
                        Task {
                            await FamilySearchTokenStore.shared.saveAppKey(key)
                            await refresh()
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(appKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Session

    private var sessionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: signedIn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(signedIn ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(signedIn ? "Signed in" : "Not signed in")
                        .font(AppTypography.cardTitle)
                    if signedIn, let tokenExpiry {
                        Text("Token valid until \(tokenExpiry.formatted(date: .omitted, time: .shortened))")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    } else if signingIn {
                        Text("A browser window opened — complete sign-in there.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if signingIn {
                    ProgressView().controlSize(.small)
                } else {
                    Button(signedIn ? "Re-authenticate" : "Sign in") { signIn() }
                        .buttonStyle(.glass)
                        .disabled(!appKeyConfigured)
                }
            }

            if signedIn {
                HStack(spacing: 8) {
                    Button(probing ? "Verifying…" : "Verify connection") { verify() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(probing)
                    Button("Sign out") { signOut() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                Divider()
                treeProbeSection
            }
        }
    }

    // MARK: - Tree-API spike (diagnostic)

    private var treeProbeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API probe (diagnostic)")
                .font(AppTypography.cardTitle)
            Text("Read-only calls through the real FamilySearch client. Records search answers whether our key is granted historical records; tree search + record hints exercise the enrichment surface. Shows HTTP status + decoded count + the raw body — a 4xx body is as useful as a 2xx (it reveals the tier wall).")
                .font(AppTypography.badge)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Given name", text: $probeGiven).textFieldStyle(.roundedBorder)
                TextField("Surname", text: $probeSurname).textFieldStyle(.roundedBorder)
                TextField("Birth year", text: $probeYear).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            HStack {
                Button(treeProbing ? "…" : "Records search") { runProbe(.records) }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(treeProbing || probeSurname.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(treeProbing ? "…" : "Tree search") { runProbe(.tree) }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(treeProbing || probeSurname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                TextField("Tree person id (e.g. LZ8X-…)", text: $probePersonID).textFieldStyle(.roundedBorder)
                Button(treeProbing ? "…" : "Record hints") { runProbe(.hints) }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(treeProbing || probePersonID.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let probeSummary {
                Text(probeSummary)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !probeRaw.isEmpty {
                ScrollView {
                    Text(probeRaw)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(6)
                .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Actions

    private func signIn() {
        statusMessage = nil
        signingIn = true
        Task {
            do {
                _ = try await FamilySearchOAuth.signIn(environment: environment)
                statusMessage = "Signed in — token stored."
            } catch {
                statusMessage = "Sign-in failed: \(error.localizedDescription)"
            }
            signingIn = false
            await refresh()
        }
    }

    private func verify() {
        probing = true
        Task {
            let result = await FamilySearchConnection.verify(environment: environment)
            probing = false
            switch result {
            case .notSignedIn:
                statusMessage = "Not signed in."
            case .connected(let user):
                statusMessage = "Connected as \(user.displayName)."
            case .failed(let status, let detail):
                statusMessage = "Verify failed\(status.map { " (HTTP \($0))" } ?? ""): \(detail)"
            }
        }
    }

    private func signOut() {
        Task {
            await FamilySearchTokenStore.shared.clear(environment: environment)
            statusMessage = nil
            await refresh()
        }
    }

    private enum ProbeKind { case records, tree, hints }

    /// Fire one read-only call through the real client and show status + a
    /// decoded summary + the raw body. Uses `execute` (not the throwing typed
    /// wrappers) so a 4xx body — e.g. an entitlement wall — is displayed, not
    /// swallowed.
    private func runProbe(_ kind: ProbeKind) {
        treeProbing = true
        probeSummary = "Calling…"
        probeRaw = ""
        let env = environment
        let query = buildProbeQuery()
        let pid = probePersonID.trimmingCharacters(in: .whitespaces)
        Task {
            let client = FamilySearchClient(
                environment: env,
                tokenSource: KeychainFamilySearchTokenSource(environment: env))
            let url: URL = switch kind {
            case .records: FamilySearchEndpoints.recordsPersonaSearch(env, query)
            case .tree:    FamilySearchEndpoints.treeSearch(env, query)
            case .hints:   FamilySearchEndpoints.personMatches(env, pid: pid, collection: .records)
            }
            do {
                let response = try await client.execute(
                    FamilySearchRequest(url: url, accept: .gedcomxAtom))
                let body = String(data: response.body, encoding: .utf8)
                    ?? "<non-UTF8 body, \(response.body.count) bytes>"
                treeProbing = false
                probeSummary = summariseProbe(status: response.statusCode, body: response.body)
                probeRaw = String(body.prefix(6000))
            } catch FamilySearchClientError.notAuthenticated {
                treeProbing = false
                probeSummary = "Not signed in — sign in first."
            } catch {
                treeProbing = false
                probeSummary = "Transport error: \(error.localizedDescription)"
            }
        }
    }

    private func buildProbeQuery() -> FamilySearchQuery {
        var query = FamilySearchQuery()
        query.givenName = probeGiven.trimmingCharacters(in: .whitespaces)
        query.surname = probeSurname.trimmingCharacters(in: .whitespaces)
        if let year = Int(probeYear.trimmingCharacters(in: .whitespaces)) {
            query.birthDateRange = year...year
        }
        return query
    }

    /// Count GEDCOM X Atom entries when the body decodes, else defer to the raw.
    private func summariseProbe(status: Int, body: Data) -> String {
        if let feed = try? JSONDecoder().decode(RecordsSearchFeed.self, from: body),
           let entries = feed.entries {
            let total = feed.results.map { " of ~\($0)" } ?? ""
            return "HTTP \(status) — \(entries.count) entr\(entries.count == 1 ? "y" : "ies")\(total) (see raw)"
        }
        return "HTTP \(status) — see raw response"
    }

    private func refresh() async {
        appKeyConfigured = await FamilySearchTokenStore.shared.appKey() != nil
        let tokens = await FamilySearchTokenStore.shared.load(environment: environment)
        signedIn = tokens.map { !$0.isExpired() } ?? false
        tokenExpiry = tokens.map { $0.obtainedAt.addingTimeInterval(TimeInterval($0.expiresIn ?? 3600)) }
    }
}
