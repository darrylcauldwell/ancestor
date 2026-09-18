import Foundation
import AncestorKit

/// FreeBMD citation backfill Change 2 — surfaces applied FreeBMD evidence
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
    ///
    /// Change 6 Fix 2 — checks BOTH layers: link-less applied *evidence* rows
    /// AND link-less applied *fact* citations (`field_sources`). The enrich path
    /// can heal the evidence row while the published citation stays bare
    /// (Abraham 2026-08-10), which would leave an evidence-only audit falsely
    /// green while the profile you'd publish still has no link. `profile` is
    /// optional so pure evidence-layer callers/tests need not pass it — but the
    /// Health sweeps do, so the finding reflects the layer that reaches print.
    static func finding(profileID: String, profileName: String,
                        evidence: [EvidenceRecord],
                        profile: Profile? = nil) -> AuditResult? {
        let missing = evidence.filter {
            $0.sourceID == "freebmd"
                && $0.userStatus == .savedAsLead   // applied/kept
                && ($0.citationURL?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }

        // Fact-layer gap: an applied FreeBMD field-source citation whose own url
        // is empty. Deduped by access-date-trimmed notes so a registration cited
        // on two fields (deathDate + deathLocation) counts once.
        var linklessFactTexts: Set<String> = []
        if let profile {
            for sources in profile.sources.values {
                for source in sources where source.origin == .freebmd {
                    guard let citation = source.citation,
                          (citation.url?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty,
                          let notes = EvidenceRecord.trimAccessDate(citation.notes)?
                              .trimmingCharacters(in: .whitespaces), !notes.isEmpty
                    else { continue }
                    linklessFactTexts.insert(notes)
                }
            }
        }

        // Count = every link-less applied evidence row (each its own record),
        // PLUS every link-less fact citation whose registration is not already
        // represented by one of those evidence rows — so the same registration
        // appearing in BOTH layers (or cited on two fields) counts once, while
        // genuinely distinct records each count.
        let evidenceKeys = Set(missing.compactMap {
            EvidenceRecord.trimAccessDate($0.citationFull)?.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
        let factOnly = linklessFactTexts.subtracting(evidenceKeys)
        let n = missing.count + factOnly.count
        guard n > 0 else { return nil }
        // The mother's maiden name only entered the GRO birth index from Sep
        // 1911 (`ScoringRules.mothersMaidenNameStart`). A pre-1911 birth never
        // carried one, so its absence is not a "missing" field and unlocks
        // nothing — don't flag it (and don't let it inflate the severity below).
        // Unknown birth year → treat conservatively as not-missing.
        let mmnMissing = missing.filter { e in
            if case .birth(let b) = e.record,
               let year = b.birthYear, year >= ScoringRules.mothersMaidenNameStart {
                return (b.mothersMaidenName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
            return false
        }.count

        var message = "\(profileName) — \(n) FreeBMD record\(n == 1 ? "" : "s") with no direct entry link"
        if mmnMissing > 0 {
            message += "; \(mmnMissing) birth\(mmnMissing == 1 ? "" : "s") also missing the mother's maiden name"
        }
        message += " — re-research to backfill."

        // Severity by consequence, not by tidiness: a link-only gap is cosmetic
        // provenance (info), but a birth missing its MMN GATES new data —
        // enriching it seeds parent inference (mother's maiden name -> parents ->
        // new relatives), so it's an actionable warning (owner call 2026-07-28).
        let severity: Severity = mmnMissing > 0 ? .warning : .info

        return AuditResult(
            profileID: profileID, profileName: profileName,
            severity: severity, category: .gap,
            ruleID: ruleID, message: message)
    }

    // MARK: - Change 3 — cross-transcription link reconciliation

    /// vol + page identify a GRO entry independent of *which* transcription
    /// supplied it — the key for matching a link-less applied record against a
    /// sibling transcription that carries the link. nil for record types with
    /// no vol/page.
    static func volPage(_ record: SourceRecord) -> (vol: String?, page: String?) {
        let typed: (vol: String?, page: String?) = switch record {
        case .birth(let r): (r.volume, r.page)
        case .death(let r): (r.volume, r.page)
        case .marriage(let r): (r.volume, r.page)
        default: (nil, nil)
        }
        // Typed fields present → use them.
        if let v = typed.vol?.trimmingCharacters(in: .whitespaces), !v.isEmpty,
           let p = typed.page?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            return (v, p)
        }
        // Fallback: an applied/imported FreeBMD row can carry vol/page ONLY in
        // its stable id — built as "freebmd_{type}_{vol}_{page}_{row}" where
        // FreeBMDSource mints `RecordCommon.id` — while the typed volume/page
        // never populated. It's
        // the same GRO reference, so recover it so the citation enricher can
        // re-locate the entry instead of falsely reporting "no volume/page"
        // (owner dogfood 2026-08-13: three profiles' applied death facts).
        if let recovered = volPageFromFreeBMDID(record.common.id) {
            return (recovered.vol, recovered.page)
        }
        return typed
    }

    /// Parse (vol, page) from a FreeBMD source-record id of the shape
    /// "freebmd_{type}_{vol}_{page}_{row}" — e.g. "freebmd_death_6_122_264339957"
    /// → ("6","122"); "freebmd_birth_7b_933_51" → ("7b","933"). nil when the id
    /// isn't that shape (never guesses).
    static func volPageFromFreeBMDID(_ id: String) -> (vol: String, page: String)? {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, parts[0] == "freebmd" else { return nil }
        let vol = parts[2].trimmingCharacters(in: .whitespaces)
        let page = parts[3].trimmingCharacters(in: .whitespaces)
        guard !vol.isEmpty, !page.isEmpty else { return nil }
        return (vol, page)
    }

    /// After a run, `saveEvidence`'s ON CONFLICT already re-links a *re-scraped
    /// same transcription*. This closes the *cross-transcription* gap: an applied
    /// record (e.g. transcription 143213883, no link) adopts the citation link of
    /// a sibling (e.g. 143220917, same GRO entry `7b/1902`) that a re-research
    /// found *with* a link. Returns the `(evidenceID, url)` column updates to
    /// apply — pure; the DB layer persists them. Zero extra FreeBMD load.
    static func linkReconciliation(
        evidence: [EvidenceRecord]
    ) -> [(evidenceID: String, citationURL: String)] {
        let freebmd = evidence.filter { $0.sourceID == "freebmd" }
        func key(_ e: EvidenceRecord) -> String? {
            let (vol, page) = volPage(e.record)
            guard let vol = vol?.trimmingCharacters(in: .whitespaces), !vol.isEmpty,
                  let page = page?.trimmingCharacters(in: .whitespaces), !page.isEmpty
            else { return nil }
            return "\(e.recordType.rawValue)|\(vol)|\(page)"
        }
        func linked(_ e: EvidenceRecord) -> Bool {
            !(e.citationURL?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
        // First non-empty link per GRO entry becomes the donor.
        var donor: [String: String] = [:]
        for e in freebmd where linked(e) {
            if let k = key(e), donor[k] == nil { donor[k] = e.citationURL }
        }
        // Recipients: applied records for that entry that still have no link.
        var updates: [(evidenceID: String, citationURL: String)] = []
        for e in freebmd where !linked(e) && e.userStatus == .savedAsLead {
            if let k = key(e), let url = donor[k] { updates.append((e.id, url)) }
        }
        return updates
    }

    // MARK: - Change 5 — targeted enrichment from a fresh FreeBMD lookup

    /// One record's enrichment from a targeted FreeBMD re-lookup: the citation
    /// link and, for births, the mother's maiden name.
    struct EnrichmentUpdate: Equatable, Sendable {
        let evidenceID: String
        let citationURL: String
        /// The MMN the freshly-fetched birth row carried — feeds parent
        /// inference. nil for non-births or when the row had none.
        let mothersMaidenName: String?
    }

    /// The heart of the targeted backfill (Change 5): given a profile's
    /// link-less applied FreeBMD records and the `[SourceRecord]` a *narrow*
    /// FreeBMD re-lookup returned (parsed by the current source, so each carries
    /// `detailURL` + MMN), match each flagged record to its fresh sibling by GRO
    /// entry (recordType + vol + page) and produce the updates. Pure — no I/O;
    /// the caller runs the query and persists. Because we already hold the exact
    /// record, the query is a re-location, not a fan-out discovery.
    static func enrichmentUpdates(
        flagged: [EvidenceRecord],
        results: [SourceRecord]
    ) -> [EnrichmentUpdate] {
        func groKey(type: String, _ record: SourceRecord) -> String? {
            let (vol, page) = volPage(record)
            guard let vol = vol?.trimmingCharacters(in: .whitespaces), !vol.isEmpty,
                  let page = page?.trimmingCharacters(in: .whitespaces), !page.isEmpty
            else { return nil }
            return "\(type)|\(vol)|\(page)"
        }

        // Index the fresh results that actually carry a link, by GRO entry.
        var link: [String: (url: String, mmn: String?)] = [:]
        for r in results {
            guard let url = r.common.detailURL?.trimmingCharacters(in: .whitespaces), !url.isEmpty,
                  let k = groKey(type: r.recordType.rawValue, r) else { continue }
            if link[k] == nil {
                let mmn: String? = { if case .birth(let b) = r { return b.mothersMaidenName }; return nil }()
                link[k] = (url, mmn)
            }
        }

        var updates: [EnrichmentUpdate] = []
        for e in flagged
        where e.sourceID == "freebmd"
            && e.userStatus == .savedAsLead
            && (e.citationURL?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
            guard let k = groKey(type: e.recordType.rawValue, e.record), let hit = link[k] else { continue }
            updates.append(EnrichmentUpdate(
                evidenceID: e.id, citationURL: hit.url, mothersMaidenName: hit.mmn))
        }
        return updates
    }
}
