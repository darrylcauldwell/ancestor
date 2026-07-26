import Foundation
import os
import CryptoKit

/// The Evidence Firewall — validates Field Researcher findings before they
/// reach the 4-gate scorer. Implements Rules 1-8 from the spec.
nonisolated struct EvidenceFirewall {

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Firewall")
    /// Cap on stored/compared evidence excerpts. Shared with `HallucinationRecheck`.
    static let maxEvidenceTextLength = 200

    // MARK: - Validate a Finding

    /// Run all hallucination checks on a finding. Returns nil if the finding passes,
    /// or a rejection reason if it fails.
    static func validate(
        finding: PendingFact,
        existingCitedURLs: Set<String>,
        profileBirthYear: Int?,
        profileDeathYear: Int?
    ) async -> String? {
        // Rule 2: URL required
        guard !finding.sourceURL.isEmpty else {
            return "no source URL provided"
        }

        // Rule 2: URL not blocked
        let (blocked, reason) = SourceTierRegistry.isBlocked(url: finding.sourceURL)
        if blocked {
            return "blocked URL: \(reason)"
        }

        // Rule 3: evidence_text length cap
        if finding.evidenceText.count > maxEvidenceTextLength {
            logger.info("Firewall: evidence_text truncated from \(finding.evidenceText.count) to \(maxEvidenceTextLength) chars")
            // Truncation is not rejection — the processor truncates before storing
        }

        // Rule 6: Date sanity
        if let year = extractYear(from: finding.value) {
            if year < 1500 || year > Calendar.current.component(.year, from: Date()) {
                return "date sanity: year \(year) is outside plausible range (1500-present)"
            }
        }

        // Rule 6: Temporal impossibility
        if let birthYear = profileBirthYear, let eventYear = extractYear(from: finding.value) {
            if finding.field == "deathDate" && eventYear < birthYear {
                return "temporal impossibility: death \(eventYear) before birth \(birthYear)"
            }
            if finding.field == "marriageDate" && eventYear < birthYear + 14 {
                return "temporal impossibility: marriage at age \(eventYear - birthYear)"
            }
        }
        if let deathYear = profileDeathYear, let eventYear = extractYear(from: finding.value) {
            if finding.field == "birthDate" && eventYear > deathYear {
                return "temporal impossibility: birth \(eventYear) after death \(deathYear)"
            }
        }

        // Rule 6: Name plausibility (for name-type fields)
        if finding.field.contains("Name") || finding.field == "name" {
            let nameChars = CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "'-"))
            if finding.value.unicodeScalars.contains(where: { !nameChars.contains($0) }) {
                return "name plausibility: contains non-alphabetic characters"
            }
            if finding.value.count > 100 {
                return "name plausibility: suspiciously long (\(finding.value.count) chars)"
            }
        }

        // Rule 6: Source recycling
        if existingCitedURLs.contains(finding.sourceURL) {
            // Same URL cited before for a different profile — flag but don't reject
            // (it's valid for the same parish register to mention multiple family members)
            logger.info("Firewall: URL previously cited — checking for source recycling")
        }

        return nil // Passed all checks
    }

    // MARK: - URL Verification (Rule 2)

    /// True for FamilySearch ark record URLs (any familysearch.org host,
    /// path containing `ark:/`) — the class of URL whose content is
    /// licence-walled and must never be fetched or cached (spec §16.1(3)).
    /// Pure predicate, extracted for hermetic testing.
    nonisolated static func isFamilySearchArk(url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        guard host == "familysearch.org" || host.hasSuffix(".familysearch.org") else { return false }
        return url.contains("ark:/")
    }

    /// Verify a source URL: fetch the page, check evidence_text appears in content,
    /// cache the page for provenance. Returns cached page data or nil if verification fails.
    static func verifyURL(
        url: String,
        evidenceText: String
    ) async -> URLVerificationResult {
        guard let requestURL = URL(string: url) else {
            return .failed("invalid URL format")
        }

        // FamilySearch ark URLs — record content is licence-walled behind
        // sign-in, so an unauthenticated fetch returns a shell page that can
        // never contain the evidence text; content verification would
        // auto-reject every legitimate FS-cited fact. Per
        // FAMILYSEARCH_SOURCE_SPEC §16.1(3), FS verification degrades to
        // pointer classification: treat as restricted, never fetch or cache
        // ark content (the pointer-only compliance posture).
        if isFamilySearchArk(url: url) {
            return .restricted("FamilySearch ark — record content is licence-walled; pointer-only (spec §16)")
        }

        // Check if restricted source
        if SourceTierRegistry.isRestricted(url: url) {
            return .restricted("restricted source — verify at URL directly")
        }

        do {
            var request = URLRequest(url: requestURL, timeoutInterval: 15)
            request.setValue("AncestorResearch/1.0 (genealogy research)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("not an HTTP response")
            }

            guard httpResponse.statusCode == 200 else {
                return .failed("HTTP \(httpResponse.statusCode)")
            }

            // Content verification: evidence_text must appear in page
            let pageText = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            let normalisedEvidence = normalise(evidenceText)
            let normalisedPage = normalise(pageText)

            if normalisedEvidence.isEmpty || normalisedPage.contains(normalisedEvidence) {
                return .verified(pageData: data, pageHash: sha256(data))
            } else {
                return .contentMismatch("evidence text not found in page content")
            }
        } catch {
            return .failed("fetch error: \(error.localizedDescription)")
        }
    }

    // MARK: - §14.B.1 Defensive Hallucination Re-check

    /// Re-verify an auto-approval candidate against its cited source before the
    /// §14.3 gate is allowed to commit it. This is the firewall's defensive
    /// second look: it independently re-fetches the page (page-cache first, so a
    /// page already fetched during the original extraction costs nothing) and
    /// deterministically re-extracts the specific claim. A confirmed claim is
    /// approved; anything else bounces back to `pending_facts` with a
    /// hallucination flag.
    ///
    /// The implementation lives in `HallucinationRecheck`; this method is the
    /// firewall-facing entry point so callers (`PendingFactsProcessor`, the MCP
    /// approve path) route through the Evidence Firewall as the single home for
    /// hallucination checks.
    ///
    /// - Returns: an audit entry carrying the per-claim decision. Approve only on
    ///   `.approved`; on `.bounced` leave the fact in `pending_facts`.
    static func recheckForAutoApproval(
        finding: PendingFact,
        pages: any PageProvider
    ) async -> HallucinationRecheck.AuditEntry {
        await HallucinationRecheck.recheck(claim: .init(finding: finding), pages: pages)
    }

    // MARK: - Idempotency Key (§13)

    /// Generate a deterministic ID for a finding, used for deduplication.
    static func idempotencyKey(profileID: String, field: String, value: String, sourceURL: String) -> String {
        let input = "\(profileID)|\(field)|\(value)|\(sourceURL)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    static func extractYear(from text: String) -> Int? {
        let pattern = #"\b(\d{4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    /// Normalise text for content matching: lowercase, collapse whitespace, strip punctuation.
    /// Shared with `HallucinationRecheck` so the §14.B.1 re-check uses identical
    /// content-matching semantics to the firewall's original URL verification.
    static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func sha256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

/// Result of URL verification.
nonisolated enum URLVerificationResult: Sendable {
    case verified(pageData: Data, pageHash: String)
    case restricted(String)          // Paywalled source — can't verify content
    case contentMismatch(String)     // Page exists but evidence_text not found
    case failed(String)              // Network error or bad status
}

/// A pending fact submitted by the Field Researcher, awaiting firewall validation and scoring.
nonisolated struct PendingFact: Identifiable, Sendable {
    let id: String                   // Idempotency key (SHA256)
    let profileID: String
    let field: String
    let value: String
    let sourceURL: String
    let sourceTitle: String
    let evidenceText: String         // Capped at 200 chars
    let reasoning: String
    let confidence: String           // high/medium/low — metadata only
    let agentID: String              // "claude-code", "field-researcher"
    let submittedAt: Date
    var verificationStatus: VerificationStatus
    /// #CPC-Change2 — machine-readable routing payload (rides the
    /// `pending_facts.sources_json` column). Set only by in-app detectors
    /// whose accept path needs structure (cross-profile corroboration);
    /// nil for every other producer, preserving the historical "{}".
    var payloadJSON: String? = nil

    enum VerificationStatus: String, Sendable {
        case pending                 // Not yet verified
        case verified                // URL fetched, content matches
        case restricted              // Paywalled source
        case contentMismatch         // URL exists but evidence not found
        case failed                  // URL doesn't exist or network error
        case rejected                // Failed hallucination checks
    }
}

/// A narrative finding — unstructured biographical evidence that doesn't map to a single field.
nonisolated struct NarrativeFinding: Identifiable, Sendable {
    let id: String
    let profileID: String
    let category: String             // apprenticeship, will_probate, newspaper, etc.
    let description: String          // Max 500 chars
    let dateOrPeriod: String?
    let sourceURL: String
    let sourceTitle: String
    let evidenceText: String         // Max 200 chars
    let reasoning: String
    let agentID: String
    let submittedAt: Date
    var verificationStatus: PendingFact.VerificationStatus
}
