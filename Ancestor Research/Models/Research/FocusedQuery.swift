import Foundation

/// A single targeted query proposed by the Level-2 query strategist
/// (`ResearchInterpreter.suggestNextFocusedQuery`).
///
/// Distinct from `RecordQuery` (the dispatcher's per-source query
/// builder) by intent: a `FocusedQuery` is a **research direction**
/// chosen by the strategist after seeing what the deterministic
/// iteration loop produced. The dispatcher's existing fan-out
/// addresses "search broadly across every source"; `FocusedQuery`
/// addresses "given what we just learned, ask THIS specific question
/// of THIS specific source".
///
/// **Determinism contract.** The strategist (MLX-backed) emits a
/// `FocusedQuery`. The dispatcher runs it deterministically. The
/// scorer classifies results deterministically. The verdict, the
/// hypothesis grading, and the §14.3 auto-approval gate all remain
/// rule-driven. MLX never participates in deciding what's true —
/// only what's worth asking next.
///
/// **Audit trail.** `rationale` is the strategist's one-line
/// justification ("Pre-1911 birth pattern → census is the path to
/// MMN"). Persisted in `searchHistory` alongside the query itself so
/// every focused dispatch carries a human-readable explanation of
/// why it ran.
nonisolated struct FocusedQuery: Sendable {

    /// The single source to query. The strategist's job is to pick
    /// the *right* source for the question — not fan out to all of
    /// them. Maps to the sourceID strings in `SourceRegistry`.
    let sourceID: String

    /// The record type to search for. The strategist picks one — if
    /// the question is "where's the household?" the answer is census,
    /// not birth+death+marriage+probate at once.
    let recordType: RecordType

    /// Surname to search. Empty string treated as "no constraint" by
    /// the dispatcher; the strategist should rarely emit empty.
    let surname: String

    /// Optional given name (or initial). The dispatcher narrows the
    /// query when present; absent means the strategist is intentionally
    /// surname-only (e.g. searching for ALL Brooks marriages in a
    /// district to enumerate page 943's couples).
    let givenName: String?

    /// Year window — inclusive bounds. The strategist may pass nil
    /// for open-ended (e.g. all years for a parish-register sweep)
    /// but is encouraged to narrow to 5-10 years per the Python
    /// `strategist.py` constraint ("wide searches return thousands
    /// of irrelevant results").
    let yearFrom: Int?
    let yearTo: Int?

    /// District constraint at the FreeBMD district granularity, or
    /// nil for source-wide search. The strategist should prefer a
    /// district name when one applies — the dispatcher will resolve
    /// it to the right district code per source.
    let district: String?

    /// One-line justification for this query. Carries the strategist's
    /// reasoning ("Census 1891 should show George ~age 7 with his
    /// parents"). Required field — every FocusedQuery must explain
    /// itself so the audit trail in `searchHistory` is meaningful.
    let rationale: String

    /// Convert to a `RecordQuery` for the existing dispatcher. The
    /// per-source `Params` structs are intentionally narrow — most
    /// of `FocusedQuery`'s information (surname, given, year window)
    /// lives at the top-level `RecordQuery` fields, which every
    /// source plugin reads. The `Params` payload only carries source-
    /// specific axes the strategist is allowed to set (e.g. FreeBMD
    /// district code, FreeCen census year + Chapman code).
    /// `homeChapmanCode` is the subject's county anchor — the strategist's
    /// model output carries no county, so chapman-coded sources (FreeCen,
    /// FreeREG) take it from the subject. Empty string = no anchor; the
    /// source then reports `.outsideCoverage` rather than guessing.
    func toRecordQuery(homeChapmanCode: String) -> RecordQuery {
        let chapman: String? = homeChapmanCode.isEmpty ? nil : homeChapmanCode
        let sourceParams: SourceQueryParams = {
            switch sourceID.lowercased() {
            case "freebmd":
                return .freeBMD(FreeBMDParams(
                    districtCode: district ?? "",
                    wildcardSurname: false,
                    motherSurname: nil,
                    spouseSurname: nil
                ))
            case "freecen":
                return .freeCen(FreeCenParams(
                    chapmanCode: chapman,
                    censusYear: yearFrom,
                    birthYearRange: nil
                ))
            case "freereg":
                return .freeREG(FreeREGParams(
                    registerType: nil,
                    parish: district,
                    chapmanCode: chapman
                ))
            case "findagrave":
                return .findAGrave(FindAGraveParams(
                    yearRangeWidth: 5,
                    location: district
                ))
            case "cwgc":
                return .cwgc(CWGCParams(conflict: nil))
            case "probate":
                return .probate(ProbateParams(courtType: nil))
            case "wirksworth":
                return .wirksworth(WirksworthParams(parishHint: district))
            default:
                return .generic
            }
        }()

        return RecordQuery(
            surname: surname,
            givenName: givenName,
            recordType: recordType,
            yearFrom: yearFrom,
            yearTo: yearTo,
            gender: nil,
            region: nil,
            sourceParams: sourceParams,
            strictness: .strict
        )
    }
}
