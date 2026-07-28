import Foundation
import AncestorKit

/// FREEBMD_CITATION_BACKFILL_SPEC Change 2 — surfaces applied FreeBMD evidence
/// that predates the detail-link capture (commit c194066): records saved with
/// no direct entry link, and births additionally missing the mother's maiden
/// name (the parent-inference blocker).
///
/// Pure over one profile's evidence rows — `AppState` scans the tree and feeds
/// each profile's rows in. Read-only: an info-severity gap, never an error; the
/// fix is a (throttled) re-research that recaptures the link + MMN. Aggregated
/// one-per-profile so a person with several link-less records is a single row,
/// not a flood.
nonisolated enum FreeBMDCitationAudit {
    static let ruleID = "freebmdLinkMissing"

    /// The one info-gap finding for a profile that has ≥1 applied FreeBMD record
    /// with no citation link. nil when the profile has none.
    static func finding(profileID: String, profileName: String,
                        evidence: [EvidenceRecord]) -> AuditResult? {
        let missing = evidence.filter {
            $0.sourceID == "freebmd"
                && $0.userStatus == .savedAsLead   // applied/kept
                && ($0.citationURL?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
        guard !missing.isEmpty else { return nil }

        let n = missing.count
        let mmnMissing = missing.filter { e in
            if case .birth(let b) = e.record {
                return (b.mothersMaidenName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
            return false
        }.count

        var message = "\(profileName) — \(n) FreeBMD record\(n == 1 ? "" : "s") with no direct entry link"
        if mmnMissing > 0 {
            message += "; \(mmnMissing) birth\(mmnMissing == 1 ? "" : "s") also missing the mother's maiden name"
        }
        message += " — re-research to backfill."

        return AuditResult(
            profileID: profileID, profileName: profileName,
            severity: .info, category: .gap,
            ruleID: ruleID, message: message)
    }
}
