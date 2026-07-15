import Foundation
import os

/// Commonwealth War Graves Commission — military casualty records
/// https://www.cwgc.org/
/// Access: GET with query params → CSV response
/// Auth: None
/// Coverage: WWI (1914-1918) and WWII (1939-1945), Commonwealth forces
/// ToS: https://www.cwgc.org/about-us/terms-and-conditions/
struct CWGCSource: RecordSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "cwgc"
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(
        reason: "War-grave registry: casualties have no UK locality axis; every search spans the global register")
    nonisolated let displayName = "CWGC"
    nonisolated let descriptiveName = "Commonwealth War Graves Commission (CWGC)"
    /// T1-12 — `.death` only. The source previously declared
    /// `[.death, .burial]`, but `buildQueries` always emitted `.death`
    /// and both record types share a year window, so the two targets
    /// produced byte-identical queries that raced past the per-run
    /// cache — two identical HTTP requests per military-eligible
    /// subject on iteration 1, deduplicated after the fact. The CSV
    /// rows are the same either way; one registration, one request.
    nonisolated let recordTypes: Set<RecordType> = [.death]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1914...1947
    nonisolated let coverageRegions: Set<Region> = [.commonwealthMilitary]
    nonisolated let dataLineage: SourceLineage = .primaryRecord
    nonisolated let trustTier: SourceTrustTier = .primary
    nonisolated let evidenceDirectness: EvidenceDirectness = .primary
    nonisolated let tosStatus = SourceToSStatus(
        level: .restricted,
        summary: "Terms ban scrapers/automated access (compliance review 2026-07) — casualty CSV export used at low volume; permission request pending, ADR-008"
    )

    // MARK: - State

    private let http: any HTTPClient
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "CWGC")
    nonisolated private static let parseLogger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "CWGC")

    init(http: any HTTPClient = SourceHTTPClient.shared) {
        self.http = http
    }

    // MARK: - Constants

    // Trailing slash is canonical — without it the server replies 301 to
    // the slashed form. URLSession follows the redirect, but going direct
    // removes a round-trip and a class of redirect-handling failure modes.
    nonisolated private static let exportURL = "https://www.cwgc.org/ExportCasualtySearch/"
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"

    /// CWGC's corpus spans the two world wars plus post-war casualties
    /// administered by the Commission. Death-year wire bounds are clamped
    /// into this range (T1-07) so a wide subject window never asks the
    /// server for years it cannot hold.
    nonisolated static let corpusYearRange: ClosedRange<Int> = 1914...1947
    /// War spans for the WarSelect overlap test (T1-07). WW1 runs to 1921
    /// (post-armistice deaths from wounds are WW1-administered); WW2 runs
    /// to 1947 for the same reason.
    nonisolated static let ww1Span: ClosedRange<Int> = 1914...1921
    nonisolated static let ww2Span: ClosedRange<Int> = 1939...1947

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard recordTypes.contains(query.recordType) else {
            return .outsideCoverage(reason: "CWGC only provides death records")
        }
        guard let surname = query.surname, !surname.isEmpty else { return .results([]) }

        let summary = Self.activitySummary(query: query, surname: surname)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        do {
            let primaryItems = Self.exportQueryItems(
                query: query, surname: surname,
                forename: query.givenName, initials: nil
            )
            let primary = try await fetchCasualties(queryItems: primaryItems, surname: surname)

            switch primary {
            case .notCSV(let reason):
                // T1-13 — a 200-status body that is not the casualty CSV
                // (maintenance page, moved endpoint, empty body) must not
                // read as a genuine zero. Honesty envelope (T1-01) carries
                // it as unavailable.
                logger.warning("CWGC response failed the CSV sanity check for \(surname): \(reason)")
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: reason, strictness: query.strictness))
                return .unavailable(reason: reason)

            case .casualties(let records):
                // T1-06 (query side) — WWI casualties are frequently
                // indexed with Forename empty and only Initials populated,
                // so a Forename query can miss a real casualty. When the
                // forename probe returns zero, retry once with the
                // Forename dropped and Initials set to the given name's
                // first letter. Deterministic per query, so the per-run
                // cache key stays valid.
                if records.isEmpty,
                   query.givenName?.isEmpty == false,
                   let initial = Self.initialsFallbackValue(givenName: query.givenName) {
                    let fallbackItems = Self.exportQueryItems(
                        query: query, surname: surname,
                        forename: nil, initials: initial
                    )
                    let fallback = try await fetchCasualties(queryItems: fallbackItems, surname: surname)
                    if case .casualties(let fallbackRecords) = fallback {
                        logger.info("CWGC initials fallback (\(initial)) returned \(fallbackRecords.count) records for \(surname)")
                        await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: fallbackRecords.count, strictness: query.strictness))
                        return .results(fallbackRecords)
                    }
                    // Fallback body failed the CSV check while the primary
                    // was healthy — trust the primary's genuine zero.
                }
                logger.info("CWGC search returned \(records.count) records for \(surname)")
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: records.count, strictness: query.strictness))
                return .results(records)
            }

        } catch let error as HTTPError {
            logger.warning("CWGC search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return .unavailable(reason: error.localizedDescription)
        } catch {
            logger.warning("CWGC search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// One export request → parsed outcome. The branded empty-results 500
    /// quirk is absorbed here (mapped to zero casualties) so both the
    /// primary probe and the initials fallback share it; genuine HTTP
    /// failures propagate to the caller's catch.
    private func fetchCasualties(queryItems: [URLQueryItem], surname: String) async throws -> ExportOutcome {
        var components = URLComponents(string: Self.exportURL)!
        components.queryItems = queryItems
        guard let url = components.url else {
            return .notCSV(reason: "Could not build CWGC export URL")
        }
        do {
            let data = try await http.get(url: url, headers: ["User-Agent": Self.userAgent])
            guard let csv = String(data: data, encoding: .utf8) else {
                return .notCSV(reason: "Invalid encoding in CSV response")
            }
            return Self.parseExport(csv)
        } catch let error as HTTPError {
            // CWGC server bug (observed 2026-05): Tab=exact + Forename with
            // zero matches returns HTTP 500 serving the site's branded error
            // page instead of an empty CSV. The signature `<title>500 | CWGC</title>`
            // is unique enough to distinguish this from a genuine outage.
            // Treat it as a successful empty result.
            if case .status(500, let body?) = error,
               let html = String(data: body, encoding: .utf8),
               html.contains("<title>500 | CWGC</title>") {
                logger.info("CWGC returned its empty-results 500 page for \(surname) — treating as zero matches")
                return .casualties([])
            }
            throw error
        }
    }

    /// Parse outcome for one export response — distinguishes "the casualty
    /// CSV with N rows" from "not the CSV at all" (T1-13).
    nonisolated enum ExportOutcome {
        case casualties([SourceRecord])
        case notCSV(reason: String)
    }

    // MARK: - Query construction (static, testable)

    /// Build the export query items for one probe. Ported from cwgc.py's
    /// param construction (T1-07):
    ///
    /// * `DateDeathFromYear`/`DateDeathToYear` carry the search window,
    ///   clamped to the 1914–1947 corpus — previously the year window fed
    ///   only WarSelect and most queries fetched every same-surname
    ///   casualty across both wars.
    /// * `WarSelect` uses an overlap test: window intersects WW1 span
    ///   only → 1, WW2 span only → 2, both/neither → omitted. The old
    ///   threshold test (`yearTo <= 1918` / `yearFrom >= 1939`) was
    ///   defeated by the dispatcher's ±2 padding — a known 1917 death
    ///   (window 1915–1919) got no filter at all.
    /// * `Initials` rides the T1-06 fallback probe (forename dropped).
    ///
    /// Day/month death bounds (cwgc.py sends none either) are not
    /// possible here — `RecordQuery` carries years only.
    nonisolated static func exportQueryItems(
        query: RecordQuery,
        surname: String,
        forename: String?,
        initials: String?
    ) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "Surname", value: surname)]
        // Strictness: .strict keeps Tab=exact (canonical match);
        // .loose and .variant both drop Tab so CWGC's server-side
        // soundex fires. CWGC has no distinct .variant axis — per
        // RESEARCH_AXES_SPEC §7 it falls back to .loose.
        if query.strictness == .strict {
            items.append(URLQueryItem(name: "Tab", value: "exact"))
        }
        if let forename, !forename.isEmpty {
            items.append(URLQueryItem(name: "Forename", value: forename))
        }
        if let initials, !initials.isEmpty {
            items.append(URLQueryItem(name: "Initials", value: initials))
        }
        // T1-14 — an explicit conflict from CWGCParams (populated by the
        // MLX strategist / FocusedQuery when its rationale is war-specific)
        // wins over the year-derived WarSelect. Previously CWGCParams.conflict
        // was dead plumbing — always constructed nil, never read here — so a
        // strategist that knew "this is a WW1 casualty" could not pin the war
        // and fell back on the year window's overlap heuristic. When conflict
        // is nil/unrecognised the year-derived value stands.
        if let war = warSelect(for: query) {
            items.append(URLQueryItem(name: "WarSelect", value: war))
        }
        if let yearFrom = query.yearFrom {
            items.append(URLQueryItem(name: "DateDeathFromYear", value: String(clampToCorpus(yearFrom))))
        }
        if let yearTo = query.yearTo {
            items.append(URLQueryItem(name: "DateDeathToYear", value: String(clampToCorpus(yearTo))))
        }
        return items
    }

    /// Resolve the WarSelect wire value for a query. An explicit conflict
    /// pinned in `CWGCParams` (T1-14) takes precedence over the year-derived
    /// overlap test (T1-07); an absent/unrecognised conflict falls back to
    /// the year window.
    nonisolated static func warSelect(for query: RecordQuery) -> String? {
        if case .cwgc(let params) = query.sourceParams,
           let explicit = conflictWarSelect(params.conflict) {
            return explicit
        }
        return warSelect(yearFrom: query.yearFrom, yearTo: query.yearTo)
    }

    /// T1-14 — map an explicit `CWGCParams.conflict` string to a WarSelect
    /// wire value. Accepts the wire values themselves ("1"/"2") and the
    /// common human-readable synonyms a strategist might emit; returns nil
    /// for nil/blank/unrecognised so the caller falls back to the year window
    /// rather than silently pinning the wrong war.
    nonisolated static func conflictWarSelect(_ conflict: String?) -> String? {
        guard let raw = conflict?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "1", "ww1", "wwi", "ww 1", "world war 1", "world war i",
             "first world war", "great war":
            return "1"
        case "2", "ww2", "wwii", "ww 2", "world war 2", "world war ii",
             "second world war":
            return "2"
        default:
            return nil
        }
    }

    /// T1-07 — WarSelect from window overlap. Returns "1" when the window
    /// intersects only the WW1 span, "2" for only WW2, nil when it spans
    /// both or neither (no filter — the death-year bounds still constrain).
    nonisolated static func warSelect(yearFrom: Int?, yearTo: Int?) -> String? {
        guard let yearFrom, let yearTo, yearFrom <= yearTo else { return nil }
        let intersectsWW1 = yearFrom <= ww1Span.upperBound && yearTo >= ww1Span.lowerBound
        let intersectsWW2 = yearFrom <= ww2Span.upperBound && yearTo >= ww2Span.lowerBound
        if intersectsWW1 && !intersectsWW2 { return "1" }
        if intersectsWW2 && !intersectsWW1 { return "2" }
        return nil
    }

    nonisolated private static func clampToCorpus(_ year: Int) -> Int {
        min(max(year, corpusYearRange.lowerBound), corpusYearRange.upperBound)
    }

    // MARK: - Military eligibility (T1-08)

    /// T1-08 — decide whether a subject is military-eligible enough to reach
    /// CWGC, using **interval** semantics over the birth and death windows.
    ///
    /// The prior gate (`SearchDispatcher` → `ScoringRules.militaryEligible`)
    /// tested `birthYearFrom` as a single point against the eligibility
    /// ranges, so two real cases never reached CWGC:
    ///
    ///  1. A **straddling birth window** — 'ABT 1879' widened to 1876–1882
    ///     has `birthYearFrom == 1876`, outside WW1 eligibility (1880–1900),
    ///     even though 1880–1882 lies squarely inside it.
    ///  2. A **war-years death with no birth year** — a subject known to have
    ///     died 1916 but with no birth year was skipped entirely, though a
    ///     death squarely in war years is the single strongest CWGC trigger.
    ///
    /// This replaces the point test with an overlap test on the birth window
    /// against the eligibility ranges, PLUS an independent trigger when the
    /// death window overlaps the war-death spans regardless of birth-year
    /// knowledge. Gender gate is unchanged — CWGC coverage stays male-only
    /// (nil gender falls through, matching the dispatcher's existing
    /// `gender == .male || gender == nil` predicate and the spec-pinned
    /// male military scope; the women/Civilian-War-Dead widening in §7 is
    /// explicitly out of scope). Pure and side-effect-free so the dispatcher
    /// can call it directly (follow-up) and it can be unit-tested in isolation.
    nonisolated static func isMilitaryEligible(
        gender: Gender?,
        birthYearFrom: Int?,
        birthYearTo: Int?,
        deathYearFrom: Int?,
        deathYearTo: Int?
    ) -> Bool {
        // A positive female signal excludes; nil gender is permitted (a male
        // profile imported without explicit gender must not silently miss
        // CWGC).
        guard gender != .female else { return false }

        // Birth-window overlap against the WW1/WW2 eligibility ranges.
        if let bf = birthYearFrom {
            let bt = max(birthYearTo ?? bf, bf)
            if intervalsOverlap(bf, bt, ScoringRules.ww1Eligibility)
                || intervalsOverlap(bf, bt, ScoringRules.ww2Eligibility) {
                return true
            }
        }

        // Independent death-window trigger — a death in the war-death spans
        // is a CWGC trigger even with no birth year at all.
        if let df = deathYearFrom {
            let dt = max(deathYearTo ?? df, df)
            if intervalsOverlap(df, dt, ww1Span) || intervalsOverlap(df, dt, ww2Span) {
                return true
            }
        }

        return false
    }

    /// Closed-interval overlap: [aFrom, aTo] intersects `range`.
    nonisolated private static func intervalsOverlap(
        _ aFrom: Int, _ aTo: Int, _ range: ClosedRange<Int>
    ) -> Bool {
        aFrom <= range.upperBound && aTo >= range.lowerBound
    }

    /// T1-06 — the Initials value for the fallback probe: first letter of
    /// the given name's first token. Nil when no letter is derivable.
    nonisolated static func initialsFallbackValue(givenName: String?) -> String? {
        guard let first = givenName?
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first?.first,
            first.isLetter
        else { return nil }
        return String(first).uppercased()
    }

    /// Build a one-line description of a CWGC query for the live activity feed.
    /// Surfaces the war filter (WWI / WWII / both) so the user can tell which
    /// casualty database each line probed. Uses the same overlap test as the
    /// wire's WarSelect (T1-07) so the label matches what was actually sent.
    nonisolated static func activitySummary(query: RecordQuery, surname: String) -> String {
        let warLabel: String
        switch warSelect(for: query) {
        case "1": warLabel = "WWI "
        case "2": warLabel = "WWII "
        default: warLabel = ""
        }
        let searchTerms: String = {
            if let given = query.givenName, !given.isEmpty { return "\(given) \(surname)" }
            return surname
        }()
        return "CWGC \(warLabel)casualties: \(searchTerms)"
    }

    // MARK: - CSV Parsing (static, testable)

    /// Expected export header names (Python cwgc.py's documented columns).
    /// `Id` and `Surname` are load-bearing — their absence means the body
    /// is not the casualty CSV (T1-13). The rest are looked up by name so
    /// a column insert/reorder shifts nothing (T1-09); a missing optional
    /// column logs loudly instead of silently corrupting fields.
    nonisolated private static let requiredHeaders = ["id", "surname"]
    nonisolated private static let expectedHeaders = [
        "id", "surname", "forename", "initials", "ageatdeath", "honours",
        "dateofdeath", "rank", "regiment", "secondaryregiment", "unit",
        "secondaryunit", "countryofservice", "servicenumber", "burial",
        "cemetery", "graveref", "additionalinfo",
    ]

    /// Parse CWGC CSV export into SourceRecords.
    /// Ported faithfully from Python's cwgc.py `_parse_csv`, which uses a
    /// header-keyed `csv.DictReader` (T1-09) — the previous Swift version
    /// split on newlines and indexed fixed positions, so a quoted
    /// AdditionalInfo containing an embedded newline split one record into
    /// two silently-dropped lines, and a column reorder shifted every
    /// field without failing.
    nonisolated static func parseCSV(_ csv: String) -> [SourceRecord] {
        if case .casualties(let records) = parseExport(csv) { return records }
        return []
    }

    /// Full parse outcome — `notCSV` when the body fails the header sanity
    /// check (T1-13: maintenance pages and moved endpoints must not read
    /// as genuine zeros).
    nonisolated static func parseExport(_ csv: String) -> ExportOutcome {
        let rows = parseCSVRows(csv)
        guard let header = rows.first else {
            return .notCSV(reason: "CWGC response is empty — expected the casualty CSV export")
        }

        var columnIndex: [String: Int] = [:]
        for (index, rawName) in header.enumerated() {
            let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
            if columnIndex[name] == nil { columnIndex[name] = index }
        }

        let missingRequired = requiredHeaders.filter { columnIndex[$0] == nil }
        guard missingRequired.isEmpty else {
            parseLogger.error("CWGC body is not the casualty CSV — missing required header(s) \(missingRequired.joined(separator: ", ")); first line: \(String(header.joined(separator: ",").prefix(120)))")
            return .notCSV(reason: "CWGC response is not the casualty CSV export (missing \(missingRequired.joined(separator: "/")) column) — maintenance page or moved endpoint?")
        }

        let missingExpected = expectedHeaders.filter { columnIndex[$0] == nil }
        if !missingExpected.isEmpty {
            // Loud but non-fatal — schema drift on optional columns loses
            // those fields only, never shifts the others (T1-09).
            parseLogger.warning("CWGC CSV header is missing expected column(s): \(missingExpected.joined(separator: ", ")) — fields will be empty")
        }

        func field(_ row: [String], _ name: String) -> String {
            guard let index = columnIndex[name], index < row.count else { return "" }
            return row[index]
        }

        var records: [SourceRecord] = []

        for row in rows.dropFirst() {
            let casualtyID = field(row, "id")
            guard !casualtyID.isEmpty else { continue }

            let surname = field(row, "surname")
            let forename = field(row, "forename")
            let initials = field(row, "initials")
            let ageRaw = Int(field(row, "ageatdeath")) ?? 0
            let age = ageRaw > 0 ? ageRaw : nil
            let honours = field(row, "honours")
            let dateOfDeath = reformatDate(field(row, "dateofdeath"))
            let rank = field(row, "rank")
            let regiment = [field(row, "regiment"), field(row, "secondaryregiment")]
                .filter { !$0.isEmpty }.joined(separator: " / ")
            let unit = [field(row, "unit"), field(row, "secondaryunit")]
                .filter { !$0.isEmpty }.joined(separator: " / ")
            let countryOfService = field(row, "countryofservice")
            let serviceNumber = field(row, "servicenumber").replacingOccurrences(of: "'", with: "")
            let burialCountry = field(row, "burial")
            let cemetery = field(row, "cemetery")
            let graveRef = field(row, "graveref")
            let additionalInfo = field(row, "additionalinfo")

            let name = "\(forename) \(surname)".trimmingCharacters(in: .whitespaces)
            let deathYear = ScoringRules.extractYear(from: dateOfDeath ?? "")

            let common = RecordCommon(
                id: "cwgc_\(casualtyID)",
                sourceID: "cwgc",
                name: name,
                surname: surname,
                givenName: forename.isEmpty ? nil : forename,
                detailURL: "https://www.cwgc.org/find-records/find-war-dead/casualty-details/\(casualtyID)/",
                rawFields: [
                    "casualty_id": casualtyID,
                    "initials": initials,
                    "honours": honours,
                    "rank": rank,
                    "regiment": regiment,
                    "unit": unit,
                    "service_number": serviceNumber,
                    "country_of_service": countryOfService,
                    "burial_country": burialCountry,
                    "cemetery": cemetery,
                    "grave_ref": graveRef,
                    "additional_info": additionalInfo,
                    "date_of_death": dateOfDeath ?? "",
                ].filter { !$0.value.isEmpty }
            )

            records.append(.military(MilitaryRecord(
                common: common,
                rank: rank.isEmpty ? nil : rank,
                regiment: regiment.isEmpty ? nil : regiment,
                unit: unit.isEmpty ? nil : unit,
                serviceNumber: serviceNumber.isEmpty ? nil : serviceNumber,
                dateOfDeath: dateOfDeath,
                deathYear: deathYear,
                age: age,
                cemetery: cemetery.isEmpty ? nil : cemetery,
                graveRef: graveRef.isEmpty ? nil : graveRef,
                additionalInfo: additionalInfo.isEmpty ? nil : additionalInfo
            )))
        }

        return .casualties(records)
    }

    /// Quote-aware CSV tokeniser over the whole body (T1-09) — RFC-4180
    /// semantics: newlines inside quoted fields are data, doubled quotes
    /// unescape to a literal quote. Returns one array of fields per row;
    /// blank rows are dropped. Fields are whitespace-trimmed (parity with
    /// the previous parser).
    nonisolated static func parseCSVRows(_ body: String) -> [[String]] {
        // Normalise line endings to LF first. Swift iterates `Character`
        // (grapheme clusters), and a CRLF is ONE Character — so a
        // per-character `case "\n"` never fires on a CRLF-delimited body
        // and every row merges into one. CWGC serves CRLF. Collapsing
        // CRLF and bare CR to LF up front sidesteps the grapheme trap;
        // CRs inside quoted fields aren't part of CWGC's data.
        let normalised = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        func endField() {
            row.append(field.trimmingCharacters(in: .whitespaces))
            field = ""
        }
        func endRow() {
            endField()
            let isBlank = row.count == 1 && row[0].isEmpty
            if !isBlank { rows.append(row) }
            row = []
        }

        var index = normalised.startIndex
        while index < normalised.endIndex {
            let char = normalised[index]
            if inQuotes {
                if char == "\"" {
                    let next = normalised.index(after: index)
                    if next < normalised.endIndex && normalised[next] == "\"" {
                        field.append("\"")   // RFC-4180 escaped quote
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"": inQuotes = true
                case ",": endField()
                case "\n": endRow()
                default: field.append(char)
                }
            }
            index = normalised.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Reformat CWGC date from DD/MM/YYYY to "DD Month YYYY".
    nonisolated private static func reformatDate(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "/")
        guard parts.count == 3,
              let day = Int(parts[0]),
              let monthNum = Int(parts[1]),
              let year = Int(parts[2]) else { return raw }

        let months = ["", "January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        guard monthNum >= 1 && monthNum <= 12 else { return raw }

        return "\(day) \(months[monthNum]) \(year)"
    }
}

// MARK: - Next-of-kin line parsing (T1-10)

/// Structured parse of CWGC's `additional_info` next-of-kin line —
/// "Son of John and Mary Cauldwell, of 5 Mill St., Belper; husband of
/// Sarah Ann Cauldwell, of Derby." The format is highly regular, so a
/// deterministic parse suffices (no LLM — stays inside the deterministic
/// sandwich).
///
/// Consumers: the geography gate reads `residence` (T1-05 feed);
/// `parents`/`spouseName` are extracted ready for the hypothesis engine's
/// relationship proposals (pipeline wiring is a separate change — the
/// parent names are literally printed in the record).
nonisolated struct CWGCNextOfKin: Equatable, Sendable {
    /// Parent names from a "Son of …"/"Daughter of …" clause. One or two
    /// entries; a shared surname is expanded ("John and Mary Cauldwell" →
    /// ["John Cauldwell", "Mary Cauldwell"]). Order follows the record.
    var parents: [String] = []
    /// Spouse name from a "Husband of …"/"Wife of …" clause.
    var spouseName: String?
    /// Next-of-kin residence — the "of PLACE" tail of the parents clause,
    /// falling back to the spouse clause's place, then a bare
    /// "of …"/"Native of …" clause.
    var residence: String?

    /// Parse an additional_info line. Returns nil when nothing structured
    /// is recognisable.
    static func parse(_ info: String) -> CWGCNextOfKin? {
        let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var result = CWGCNextOfKin()
        var parentResidence: String?
        var spouseResidence: String?
        var bareResidence: String?

        for rawClause in trimmed.components(separatedBy: ";") {
            let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clause.isEmpty else { continue }

            if let rest = stripping(prefixes: ["son of ", "daughter of "], from: clause) {
                let (names, place) = splitNamesAndPlace(rest)
                let parsed = parentNames(from: names)
                if !parsed.isEmpty { result.parents = parsed }
                if parentResidence == nil { parentResidence = place }
            } else if let rest = stripping(prefixes: ["husband of ", "wife of "], from: clause) {
                let (names, place) = splitNamesAndPlace(rest)
                if result.spouseName == nil, !names.isEmpty { result.spouseName = names }
                if spouseResidence == nil { spouseResidence = place }
            } else if let rest = stripping(prefixes: ["native of ", "of "], from: clause) {
                if bareResidence == nil { bareResidence = cleanFragment(rest) }
            }
        }

        result.residence = parentResidence ?? spouseResidence ?? bareResidence
        guard !result.parents.isEmpty || result.spouseName != nil || result.residence != nil else {
            return nil
        }
        return result
    }

    /// Case-insensitive prefix strip — first matching prefix wins.
    private static func stripping(prefixes: [String], from clause: String) -> String? {
        let lower = clause.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            return String(clause.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Split "John and Mary Cauldwell, of 5 Mill St., Belper" into the
    /// names segment and the place after the FIRST ", of " marker.
    private static func splitNamesAndPlace(_ text: String) -> (names: String, place: String?) {
        if let range = text.range(of: ", of ", options: .caseInsensitive) {
            let names = cleanFragment(String(text[..<range.lowerBound]))
            let place = cleanFragment(String(text[range.upperBound...]))
            return (names, place.isEmpty ? nil : place)
        }
        return (cleanFragment(text), nil)
    }

    /// "John and Mary Cauldwell" → ["John Cauldwell", "Mary Cauldwell"];
    /// "William Brooks" → ["William Brooks"]. Strips a leading "the late ".
    private static func parentNames(from names: String) -> [String] {
        let cleaned = cleanFragment(names)
        guard !cleaned.isEmpty else { return [] }
        let parts = cleaned
            .components(separatedBy: " and ")
            .map { strippingTheLate(cleanFragment($0)) }
            .filter { !$0.isEmpty }
        guard parts.count == 2 else {
            return parts.isEmpty ? [] : [parts.joined(separator: " and ")]
        }
        var first = parts[0]
        let second = parts[1]
        // "John and Mary Cauldwell" — first name has no surname of its
        // own; borrow the second's last token.
        if !first.contains(" "), second.contains(" "),
           let surname = second.split(separator: " ").last {
            first += " \(surname)"
        }
        return [first, second]
    }

    private static func strippingTheLate(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasPrefix("the late ") {
            return String(name.dropFirst("the late ".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// Trim whitespace and a trailing full stop.
    private static func cleanFragment(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(".") {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }
}
