import Foundation
import AncestorKit

/// FREEBMD_CITATION_BACKFILL_SPEC Change 5 — the targeted, budget-light backfill.
///
/// For one profile's link-less applied FreeBMD records it runs **one narrow,
/// vol/page-scoped FreeBMD query per record** — a *re-location* of a record we
/// already fully hold, not a fan-out *discovery* — matches the fresh result by
/// GRO entry (the tested `FreeBMDCitationAudit.enrichmentUpdates`), and applies
/// the citation link + mother's maiden name. ~1 request/record vs full
/// research's ~4/profile: the 3–4× budget saving that clears the flagged set in
/// one daily window. Stops the instant FreeBMD 429s.
///
/// LIVE-VERIFY: the query construction is exercised against FreeBMD's live form —
/// confirm against a real 200 before relying on it (blind scraper code is what
/// this spec exists to undo). The `volume`/`page` params may be server-honoured
/// or ignored; either way the **client-side vol/page match is the safety net**,
/// so a widened result set still enriches the right record.
@MainActor
enum FreeBMDCitationEnricher {

    struct Outcome: Sendable {
        var enriched: Int
        /// FreeBMD pushed back (429 / breaker) mid-run — caller should stop and
        /// resume in the next window.
        var throttled: Bool
    }

    /// Enrich one profile's link-less applied FreeBMD records.
    static func enrich(profileID: String, registry: SourceRegistry,
                       db: ProjectDatabase) async -> Outcome {
        guard let source = registry.source(for: "freebmd") else {
            return Outcome(enriched: 0, throttled: false)
        }
        let evidence = (try? db.loadEvidenceForProfile(profileID)) ?? []
        let flagged = evidence.filter {
            $0.sourceID == "freebmd"
                && $0.userStatus == .savedAsLead
                && ($0.citationURL?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
        guard !flagged.isEmpty else { return Outcome(enriched: 0, throttled: false) }

        var results: [SourceRecord] = []
        var throttled = false
        for record in flagged {
            guard let query = targetedQuery(for: record) else { continue }
            switch await source.search(query) {
            case .results(let fresh): results.append(contentsOf: fresh)
            case .throttled: throttled = true
            default: break
            }
            if throttled { break }   // the moment FreeBMD pushes back, stop
        }

        let updates = FreeBMDCitationAudit.enrichmentUpdates(flagged: flagged, results: results)
        for update in updates {
            try? db.applyFreeBMDEnrichment(
                evidenceID: update.evidenceID,
                citationURL: update.citationURL,
                mothersMaidenName: update.mothersMaidenName)
        }
        return Outcome(enriched: updates.count, throttled: throttled)
    }

    /// A single narrow query that RE-LOCATES a known GRO entry: surname + given +
    /// exact year + type, scoped to the record's own vol/page. No variants, no
    /// family axes, no year-window — we already hold the record. nil when the
    /// stored record lacks a surname or vol/page (nothing to re-locate on).
    private static func targetedQuery(for record: EvidenceRecord) -> RecordQuery? {
        let (vol, page) = FreeBMDCitationAudit.volPage(record.record)
        guard let vol, let page,
              let surname = record.record.common.surname?.trimmingCharacters(in: .whitespaces),
              !surname.isEmpty else { return nil }
        let year = yearOf(record.record)
        return RecordQuery(
            surname: surname,
            givenName: record.record.common.givenName,
            recordType: record.recordType,
            yearFrom: year, yearTo: year,
            gender: nil,
            region: .englandAndWales,
            sourceParams: .freeBMD(FreeBMDParams(wildcardSurname: false, volume: vol, page: page)),
            strictness: .strict)
    }

    private static func yearOf(_ record: SourceRecord) -> Int? {
        switch record {
        case .birth(let r): return r.birthYear
        case .death(let r): return r.deathYear
        case .marriage(let r): return r.marriageYear
        default: return nil
        }
    }
}
