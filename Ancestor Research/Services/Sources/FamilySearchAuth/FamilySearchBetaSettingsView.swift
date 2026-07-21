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

    private func refresh() async {
        appKeyConfigured = await FamilySearchTokenStore.shared.appKey() != nil
        let tokens = await FamilySearchTokenStore.shared.load(environment: environment)
        signedIn = tokens.map { !$0.isExpired() } ?? false
        tokenExpiry = tokens.map { $0.obtainedAt.addingTimeInterval(TimeInterval($0.expiresIn ?? 3600)) }
    }
}
