import Foundation
import os

/// Enriches surname-only parent proposals with given names by matching them
/// against BMD marriage records.
///
/// The BMD marriage index entries each year are written TWICE — once under
/// the groom's name (with the bride's surname as the spouse field), and once
/// under the bride's name (with the groom's surname as the spouse field).
/// Matching by `(year, quarter, district, volume, page)` reunites the pair
/// and yields both given names.
///
/// Pipeline calls this after `ParentInferenceEngine` produces a surname-only
/// (mother, father) pair. The pure matching logic is testable in isolation;
/// the dispatch + scoring lives in the pipeline.
nonisolated enum MarriageEnrichmentEngine {

    /// One BMD marriage index entry as seen from one side (groom or bride).
    struct MarriageEntry: Sendable {
        let surname: String
        let givenName: String
        let spouseSurname: String        // the other party — used to pair groom-side with bride-side
        let year: Int
        let quarter: String?             // "Mar" / "Jun" / "Sep" / "Dec"
        let district: String?
        let volume: String?
        let page: String?
        /// Originating scored record — preserved so the UI can show the citation
        /// and we can attach it as evidence on the enriched ProposedRelative.
        let scored: ScoredRecord?
    }

    /// Result of matching one parent pair against marriage-record hits.
    enum MatchOutcome: Sendable {
        /// Exactly one candidate marriage. Given names are optional because
        /// FreeBMD sometimes returns the marriage on only one side of the
        /// index — we enrich whatever side(s) we have, leaving the missing
        /// side surname-only rather than discarding the whole match.
        case unique(fatherGiven: String?, motherGiven: String?, fatherEvidence: ScoredRecord?, motherEvidence: ScoredRecord?)
        /// More than one candidate marriage. User picks during accept.
        case ambiguous(candidates: [ScoredRecord])
        /// No candidate marriage in the year window.
        case none
    }

    /// Group groom-indexed and bride-indexed entries by the BMD reference
    /// tuple `(year, quarter, district, vol, page)`. Each unique reference
    /// tuple represents one candidate marriage. We enrich whichever side(s)
    /// reported it — previously the matcher required **both** sides to
    /// agree at the same key, so a single FreeBMD-side returning an
    /// incomplete result set (observed in practice: bride-side query for
    /// Cauldwell × Holmes in BELPER 1946-1977 sometimes omits the 1969
    /// hit even when the groom-side returns it cleanly) silently produced
    /// `.none`. One-sided enrichment turns that into a partial win:
    /// father's given name from groom-side, mother stays surname-only,
    /// rather than no enrichment at all.
    ///
    /// **Year window**: FreeBMD's year filter is loose — searches for 1946-1977
    /// can return out-of-window context rows (e.g. an 1896 Cauldwell at the same
    /// vol/page accidentally matches the same reference tuple as an unrelated
    /// 1896 Holmes). We filter defensively to the plausible parent window.
    ///
    /// - Parameters:
    ///   - grooms: marriages where surname = father's surname, spouse = mother's surname
    ///   - brides: marriages where surname = mother's surname, spouse = father's surname
    ///   - yearWindow: plausible parent-marriage years (subject birth − 30 to + 1).
    ///     Entries outside this window are discarded before grouping.
    /// - Returns: `unique` if exactly one candidate marriage (across either
    ///   side), `ambiguous` if more than one, `none` otherwise.
    static func match(
        grooms: [MarriageEntry],
        brides: [MarriageEntry],
        yearWindow: ClosedRange<Int>? = nil
    ) -> MatchOutcome {
        let logger = os.Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "MarriageEnrichment")

        // Filter to the parent-marriage year window if provided. Out-of-window
        // records are noise (FreeBMD often returns context rows around the query year).
        let filteredGrooms: [MarriageEntry]
        let filteredBrides: [MarriageEntry]
        if let window = yearWindow {
            filteredGrooms = grooms.filter { window.contains($0.year) }
            filteredBrides = brides.filter { window.contains($0.year) }
            logger.info("matcher window \(window.lowerBound)–\(window.upperBound): \(grooms.count)→\(filteredGrooms.count) grooms, \(brides.count)→\(filteredBrides.count) brides")
        } else {
            filteredGrooms = grooms
            filteredBrides = brides
        }

        for g in filteredGrooms {
            logger.info("groom: \(g.givenName) \(g.surname) × \(g.spouseSurname), \(g.year) \(g.quarter ?? "?") \(g.district ?? "?") vol \(g.volume ?? "?") p \(g.page ?? "?") → key=\(self.referenceKey(g))")
        }
        for b in filteredBrides {
            logger.info("bride: \(b.givenName) \(b.surname) × \(b.spouseSurname), \(b.year) \(b.quarter ?? "?") \(b.district ?? "?") vol \(b.volume ?? "?") p \(b.page ?? "?") → key=\(self.referenceKey(b))")
        }

        // Group both sides by reference key. Each unique key = one candidate
        // marriage. Where both sides agree at a key, we have both given names;
        // where only one side has a key, we still emit a one-sided enrichment.
        var byRef: [String: (groom: MarriageEntry?, bride: MarriageEntry?)] = [:]
        for entry in filteredGrooms {
            byRef[referenceKey(entry), default: (nil, nil)].groom = entry
        }
        for entry in filteredBrides {
            byRef[referenceKey(entry), default: (nil, nil)].bride = entry
        }

        let candidates = Array(byRef.values)

        switch candidates.count {
        case 0:
            return .none
        case 1:
            let c = candidates[0]
            return .unique(
                fatherGiven: c.groom?.givenName,
                motherGiven: c.bride?.givenName,
                fatherEvidence: c.groom?.scored,
                motherEvidence: c.bride?.scored
            )
        default:
            // Multiple plausible marriages. Surface as ambiguous so the user
            // chooses one during accept; pipeline does not pick a winner.
            // Prefer groom evidence if present (carries father's given name),
            // fall back to bride.
            let evidence: [ScoredRecord] = candidates.compactMap {
                $0.groom?.scored ?? $0.bride?.scored
            }
            return .ambiguous(candidates: evidence)
        }
    }

    /// Reference tuple used to join groom-side and bride-side entries for the
    /// same marriage. Falls back gracefully when district/volume/page are
    /// missing — those are required in modern BMD index rows, so missing
    /// values produce a less specific key and may match fuzzily.
    private static func referenceKey(_ entry: MarriageEntry) -> String {
        let year = String(entry.year)
        let q = (entry.quarter ?? "").uppercased()
        let d = (entry.district ?? "").uppercased()
        let v = (entry.volume ?? "").uppercased()
        let p = (entry.page ?? "").uppercased()
        return "\(year)|\(q)|\(d)|\(v)|\(p)"
    }

    /// Map a list of ScoredRecord marriages into MarriageEntry. Skips records
    /// that aren't marriages or have insufficient data to participate in the join.
    static func entries(from scored: [ScoredRecord]) -> [MarriageEntry] {
        scored.compactMap { rec -> MarriageEntry? in
            guard case .marriage(let m) = rec.record,
                  let year = m.marriageYear,
                  let surname = m.common.surname, !surname.isEmpty,
                  let given = m.common.givenName, !given.isEmpty
            else { return nil }
            return MarriageEntry(
                surname: surname,
                givenName: given,
                spouseSurname: m.spouseName ?? "",
                year: year,
                quarter: m.quarter,
                district: m.district,
                volume: m.volume,
                page: m.page,
                scored: rec
            )
        }
    }
}
