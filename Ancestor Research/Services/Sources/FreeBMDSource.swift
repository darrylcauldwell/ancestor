import Foundation
import os

/// FreeBMD — volunteer transcription of England & Wales civil registration indexes 1837–1983
/// https://www.freebmd.org.uk
/// Access: POST form with session cookie + hidden form tokens
/// Auth: None (session cookie obtained automatically)
/// Coverage: Birth/death/marriage registrations, England & Wales, 1837–1983
///
/// Data notes (from Python):
///   - Mother's maiden name (births) only from Sep 1911
///   - Spouse surname (marriages) only from Sep 1912
///   - Bakewell district has no coverage before 1941
///   - Coverage is incomplete, especially pre-1865
actor FreeBMDSource: RecordSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "freebmd"
    nonisolated let displayName = "FreeBMD"
    nonisolated let descriptiveName = "UK Births, Deaths & Marriages Index (FreeBMD)"
    nonisolated let recordTypes: Set<RecordType> = [.birth, .death, .marriage]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1837...1983
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "GRO-indexes")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(
        level: .community,
        summary: "Volunteer project — no documented API, no prohibition of programmatic access"
    )

    // MARK: - State

    private let http: any HTTPClient

    init(http: any HTTPClient = SourceHTTPClient.shared) {
        self.http = http
    }
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FreeBMD")
    /// Scheduled time for the next allowable request. Each caller synchronously
    /// (without await) advances this and reads its own slot — guarantees serial
    /// timing even when many search() calls arrive at the actor concurrently.
    /// The previous lastRequestTime-then-await pattern was racy under actor
    /// reentrancy: many callers read the same stale value, all slept ~500ms,
    /// then woke nearly simultaneously and fired together.
    private var nextRequestSlot: ContinuousClock.Instant?
    private let requestDelay: Duration = .milliseconds(500)

    /// 429 circuit-breaker state. FreeBMD is a single-volunteer source;
    /// when they throttle us, the right thing is to stop hitting them for
    /// a while — not retry harder. After `circuit429Threshold` consecutive
    /// queries fail with throttling (each having already exhausted their
    /// in-request retries), the breaker opens for `circuitOpenDuration`
    /// and *all* subsequent queries park at `awaitCircuitClosed()` until
    /// the cool-down expires. The first successful query closes the
    /// breaker and resets the counter.
    private var consecutive429s: Int = 0
    private var circuitOpenUntil: ContinuousClock.Instant?
    private let circuit429Threshold: Int = 3
    /// Exponential cool-down ladder. First circuit-trip pauses 60s, second
    /// 5min, third 15min — then `giveUpRequests = true` marks the source
    /// dead for the rest of the process so subsequent queries fail fast
    /// rather than feed an obviously hostile throttle window. Designed for
    /// the daily-quota case where FreeBMD won't recover in seconds.
    private let circuitCooldownLadder: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]
    private var circuitTripCount: Int = 0
    private var giveUpRequests: Bool = false

    // Session state (CSRF tokens)
    private var sessionCookie: String?
    private var formTokenDB: String?
    private var formTokenV: String?
    /// In-flight session-establishment task. Multiple concurrent search() calls
    /// all hit ensureSession() before any one has cached the cookie. Without
    /// this latch they'd each fetch the form HTML in parallel (12+ duplicate
    /// requests per pipeline iteration), occasionally exhausting connection
    /// pools and causing timeouts. Concurrent callers now await the same task.
    private var sessionEstablishmentTask: Task<Void, Error>?

    private var lastSuccessfulSearch: Date?
    private var lastError: String?

    // MARK: - Constants

    nonisolated private static let searchFormURL = URL(string: "https://www.freebmd.org.uk/search")!
    nonisolated private static let searchURL = URL(string: "https://www.freebmd.org.uk/cgi/search.pl")!
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"
    nonisolated private static let quarterNames = ["1": "Mar", "2": "Jun", "3": "Sep", "4": "Dec"]

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard recordTypes.contains(query.recordType) else { return .outsideCoverage(reason: "FreeBMD does not cover \(query.recordType.rawValue)") }
        guard let surname = query.surname, !surname.isEmpty else { return .results([]) }

        // Park behind the circuit breaker if 429s have been piling up.
        // Better cooperative behaviour than retrying into an already-
        // throttled source — see the consecutive429s + circuitOpenUntil
        // state defined above. When the cool-down ladder runs out,
        // subsequent queries short-circuit to `.unavailable` so this run
        // doesn't keep poking a source that's plainly told us to stop.
        if giveUpRequests {
            return .unavailable(reason: "FreeBMD throttle exhausted; giving up for this process")
        }
        await awaitCircuitClosed()

        // Build a human-readable summary like "FreeBMD Belper marriages:
        // Cauldwell × Holmes 1946–1977" for the activity feed.
        let summary = Self.activitySummary(query: query, surname: surname)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        do {
            try await ensureSession()

            let recordType: String = switch query.recordType {
            case .birth: "Births"
            case .death: "Deaths"
            case .marriage: "Marriages"
            default: "All"
            }

            // Pull source-specific params. The wire field `s_surname` is
            // overloaded by record type: spouse surname for marriages
            // (Cauldwell × Holmes), mother's maiden name for births
            // (post-Sep-1911 only — pre-1912 GRO indexes don't carry MMN),
            // and unused for deaths. Dispatcher decides which axis to fill
            // and only one is non-nil for any given record type.
            let params: FreeBMDParams? = {
                if case .freeBMD(let p) = query.sourceParams { return p } else { return nil }
            }()
            let sSurnameValue: String = {
                switch query.recordType {
                case .marriage: return params?.spouseSurname ?? ""
                case .birth:    return params?.motherSurname ?? ""
                default:        return ""
                }
            }()
            // s_given: spouse first-given for marriages (Cauldwell × Mary
            // Holmes narrows tighter than just × Holmes). FreeBMD's column
            // is first-given only — same first-token rule as `given`.
            // Unused for births/deaths.
            let sGivenValue: String = {
                guard query.recordType == .marriage else { return "" }
                return Self.firstGivenName(query.spouseGivenName) ?? ""
            }()
            // Strictness: .loose enables FreeBMD's Phonetic flag for
            // server-side soundex matching. .variant is the dispatcher's
            // tier marker — the surname has already been substituted to a
            // variant before arriving here, so the variant probe itself is
            // exact-match (Phonetic=false). See RESEARCH_AXES_SPEC §7.
            let phoneticFlag = query.strictness == .loose ? "true" : "false"
            // FreeBMD's `given` field does literal/prefix matching against
            // only the first given name in the registered record (the row
            // format is `…;FIRST_GIVEN;…`, multi-given records like
            // "Ernest V" don't surface to multi-token queries). Sending
            // "Ernest Victor" returns zero matches even when the record
            // exists; sending "Ernest" matches "Ernest V" / "Ernest Victor"
            // alike via prefix. Strip to the first whitespace-separated
            // token so the dispatcher's `subject.givenName` ("Ernest
            // Victor") becomes a usable FreeBMD query.
            //
            // Year filter only engages when `sq` (start quarter) and `eq`
            // (end quarter) are also present — without them FreeBMD
            // silently widens to "all years" and the multi-thousand result
            // set then fails downstream filters. Default to the full year
            // (Q1–Q4). See diagnostic notes in commit message.
            let fields: [String: String] = [
                "type": recordType,
                "surname": surname,
                "given": Self.firstGivenName(query.givenName) ?? "",
                "s_surname": sSurnameValue,
                "s_given": sGivenValue,
                "sq": "1",
                "start": query.yearFrom.map(String.init) ?? "",
                "eq": "4",
                "end": query.yearTo.map(String.init) ?? "",
                "districtid": params?.districtCode ?? "",
                "Phonetic": phoneticFlag,
                "db": formTokenDB ?? "",
                "v": formTokenV ?? "",
                "find.x": "1",
                "find.y": "1",
            ]

            let data = try await postSearchWithRetry(fields: fields)

            guard let html = String(data: data, encoding: .utf8) else {
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "Invalid encoding", strictness: query.strictness))
                return .unavailable(reason: "Invalid encoding")
            }
            let results = Self.parseSearchResults(html, recordType: query.recordType, querySurname: surname)
            lastSuccessfulSearch = Date()
            lastError = nil
            recordSuccess()
            logger.info("Search returned \(results.count) results for \(surname)")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: results.count, strictness: query.strictness))
            return .results(results)

        } catch is CancellationError {
            // Intentional pipeline shutdown — preserve session tokens (they
            // remain valid for subsequent runs in the same process) and
            // don't surface as an error on the activity feed.
            return .unavailable(reason: "cancelled")
        } catch let httpError as HTTPError where httpError.isThrottled {
            // 429 reached us *after* `postSearchWithRetry` already burned
            // its 3 in-request retries. Treat it as a clean throttling
            // signal: preserve session tokens (the session is still valid,
            // FreeBMD just wants us to back off), advance the circuit-
            // breaker counter, and surface a polite "throttled" reason.
            recordThrottle()
            lastError = "HTTP 429 (throttled)"
            logger.warning("Search throttled after retries — preserving session, advancing circuit breaker")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "throttled", strictness: query.strictness))
            return .unavailable(reason: "throttled")
        } catch HTTPError.unauthorized {
            // Genuine auth failure — session is bad, clear it so the next
            // query re-establishes. This is the only case where clearing
            // tokens is correct; previously every error cleared them,
            // turning every transient throttle / timeout into an extra
            // re-auth round-trip that fed the throttle storm.
            sessionCookie = nil
            formTokenDB = nil
            formTokenV = nil
            lastError = "unauthorized"
            logger.warning("Search failed: unauthorized — session cleared")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "unauthorized", strictness: query.strictness))
            return .unavailable(reason: "unauthorized")
        } catch {
            // Other transient failures (timeouts, 5xx, network blips,
            // parse errors). Preserve session tokens — they're still valid;
            // the next attempt will use them and likely succeed.
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription) — session preserved")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return .unavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Circuit breaker

    /// Block the current task until the 429 circuit breaker closes. While
    /// the breaker is open, all in-flight queries park here instead of
    /// piling on more requests to an already-throttled source. The first
    /// query past the closed breaker uses preserved tokens (no extra
    /// re-auth) and the rate limiter resumes its 500ms slot pacing.
    private func awaitCircuitClosed() async {
        while let openUntil = circuitOpenUntil {
            let now = ContinuousClock.now
            if openUntil <= now {
                circuitOpenUntil = nil
                consecutive429s = 0
                logger.info("FreeBMD circuit breaker closed — resuming")
                return
            }
            let remaining = openUntil - now
            let remainingSec = max(1, Int(Double(remaining.components.seconds)))
            logger.info("FreeBMD circuit open — parking query for ~\(remainingSec)s")
            try? await Task.sleep(until: openUntil, clock: .continuous)
        }
    }

    /// Count a 429 and trip the breaker once `circuit429Threshold` queries
    /// in a row have failed to throttling. The cool-down extends with each
    /// re-trip via `circuitCooldownLadder` — first trip 60s, second 5min,
    /// third 15min — and once the ladder is exhausted the source flags
    /// `giveUpRequests` so future queries short-circuit instead of feeding
    /// an apparently long-lived throttle window.
    private func recordThrottle() {
        consecutive429s += 1
        guard consecutive429s >= circuit429Threshold && circuitOpenUntil == nil else { return }
        if circuitTripCount >= circuitCooldownLadder.count {
            giveUpRequests = true
            logger.warning("FreeBMD throttle ladder exhausted after \(self.circuitTripCount) trips — giving up on FreeBMD for this process")
            return
        }
        let cooldown = circuitCooldownLadder[circuitTripCount]
        circuitOpenUntil = ContinuousClock.now.advanced(by: cooldown)
        circuitTripCount += 1
        logger.warning("FreeBMD circuit breaker trip #\(self.circuitTripCount) — pausing source for \(cooldown.components.seconds)s")
    }

    /// Successful response resets the breaker counter and the trip ladder,
    /// and closes any open circuit. One good response is the strongest
    /// signal we have that FreeBMD is talking to us again.
    private func recordSuccess() {
        if consecutive429s > 0 {
            consecutive429s = 0
        }
        if circuitTripCount > 0 {
            circuitTripCount = 0
        }
        if circuitOpenUntil != nil {
            circuitOpenUntil = nil
            logger.info("FreeBMD circuit breaker closed early — successful response")
        }
    }

    /// True when the breaker is currently open OR when the source has
    /// given up entirely for this process. `postSearchWithRetry` checks
    /// this between attempts so retries park instead of firing into an
    /// already-hostile throttle.
    private var isCircuitBlocked: Bool {
        if giveUpRequests { return true }
        if let openUntil = circuitOpenUntil, openUntil > ContinuousClock.now { return true }
        return false
    }

    /// Up-to-3-attempt wrapper for the search POST. Retries transient HTTP
    /// failures (timeouts, dropped connections, 5xx, 429) with increasing
    /// backoff so a single district-query flake during marriage enrichment
    /// doesn't silently break the matcher join. Bails immediately on
    /// `CancellationError` — caller handles cancellation specially so the
    /// session tokens survive normal shutdown.
    private func postSearchWithRetry(fields: [String: String]) async throws -> Data {
        // Retry budgets — throttled (429) gets *fewer* attempts than
        // network blips. 429s don't usually recover in seconds, and each
        // retry feeds the throttle window; non-throttle transients
        // (timeouts, 5xx, DNS) reasonably do.
        let maxAttemptsTransient = 3
        let maxAttemptsThrottled = 2
        var attempt = 0
        while true {
            // If the breaker has tripped since the last attempt (e.g.
            // another in-flight query advanced consecutive429s past the
            // threshold), park here rather than fire another request.
            // Pre-loop entry into search() also calls awaitCircuitClosed,
            // but a long retry path needs the same check mid-stream.
            if isCircuitBlocked {
                await awaitCircuitClosed()
                if giveUpRequests {
                    throw HTTPError.throttled
                }
            }
            attempt += 1
            do {
                return try await rateLimitedRequest {
                    try await self.http.postForm(
                        url: Self.searchURL,
                        fields: fields,
                        headers: [
                            "User-Agent": Self.userAgent,
                            "Cookie": self.sessionCookie ?? "",
                        ]
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let err where Self.isTransient(err) {
                let throttled = (err as? HTTPError)?.isThrottled ?? false
                let cap = throttled ? maxAttemptsThrottled : maxAttemptsTransient
                guard attempt < cap else { throw err }
                let backoff: Duration = throttled
                    ? .seconds(2)
                    : .milliseconds(500 * attempt)
                logger.warning("FreeBMD retryable error (attempt \(attempt)/\(cap), throttled=\(throttled)): \(err.localizedDescription); backing off")
                try await Task.sleep(for: backoff)
                continue
            }
        }
    }

    /// A FreeBMD request error worth retrying. Covers HTTPError's own
    /// `isRetryable` (5xx, 429), plain timeouts, and the URLError codes that
    /// represent transport-layer transients (dropped connection, DNS hiccup,
    /// host unreachable). Hard 4xx and parse errors are deliberately excluded
    /// — those won't change on a retry.
    nonisolated private static func isTransient(_ error: Error) -> Bool {
        if let http = error as? HTTPError {
            if http.isRetryable { return true }
            if case .timeout = http { return true }
            if case .transport(let inner) = http, let url = inner as? URLError {
                switch url.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                     .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                     .resourceUnavailable, .badServerResponse:
                    return true
                default:
                    return false
                }
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable, .badServerResponse:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Build a one-line description of a FreeBMD query for the live activity feed.
    /// Resolves the district code to its display name when possible (catalogue
    /// covers all 1125 UK districts) and includes the search terms so the user
    /// can tell what each line means.
    /// First whitespace-separated token of a given-name string, trimmed.
    /// `nil` / empty input returns `nil`. Used to coerce multi-given names
    /// (e.g. "Ernest Victor") to FreeBMD's first-given-only filter.
    nonisolated static func firstGivenName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let first = raw.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let trimmed = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func activitySummary(query: RecordQuery, surname: String) -> String {
        let recordTypeLabel: String = switch query.recordType {
        case .birth: "births"
        case .death: "deaths"
        case .marriage: "marriages"
        default: query.recordType.rawValue
        }

        var districtName = "national"
        var spouseSurname: String?
        if case .freeBMD(let params) = query.sourceParams {
            if let code = params.districtCode, !code.isEmpty {
                districtName = FreeBMDDistrictCatalogue.shared.all()
                    .first(where: { $0.code == code })?.name ?? "district \(code)"
            }
            if let ss = params.spouseSurname, !ss.isEmpty {
                spouseSurname = ss
            }
        }

        let searchTerms: String = {
            if let spouse = spouseSurname { return "\(surname) × \(spouse)" }
            if let given = query.givenName, !given.isEmpty { return "\(given) \(surname)" }
            return surname
        }()

        let yearLabel: String
        switch (query.yearFrom, query.yearTo) {
        case let (yf?, yt?) where yf == yt:
            yearLabel = " \(yf)"
        case let (yf?, yt?):
            yearLabel = " \(yf)–\(yt)"
        default:
            yearLabel = ""
        }

        return "FreeBMD \(districtName) \(recordTypeLabel): \(searchTerms)\(yearLabel)"
    }

    // MARK: - Session Management

    /// Fetch a fresh session cookie and hidden form tokens from FreeBMD.
    /// Concurrent callers all await the same establishment task — only one
    /// network fetch ever happens at a time even when 12+ search() calls
    /// queue at the actor.
    private func ensureSession() async throws {
        if sessionCookie != nil { return }
        if let inFlight = sessionEstablishmentTask {
            try await inFlight.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            try await self?.performSessionEstablishment()
        }
        sessionEstablishmentTask = task
        defer { sessionEstablishmentTask = nil }
        try await task.value
    }

    /// The actual fetch. Only ever called from inside the single in-flight task.
    private func performSessionEstablishment() async throws {
        let data = try await http.get(url: Self.searchFormURL, headers: ["User-Agent": Self.userAgent])
        guard let html = String(data: data, encoding: .utf8) else {
            throw HTTPError.status(code: 0, body: nil)
        }

        // Extract hidden form tokens
        formTokenDB = Self.extractFormValue(named: "db", from: html)
        formTokenV = Self.extractFormValue(named: "v", from: html)

        // Session cookie — FreeBMD sets it on the search form page
        // The HTTP client follows redirects, so we get the cookie via URLSession's cookie storage
        if let cookies = HTTPCookieStorage.shared.cookies(for: Self.searchFormURL) {
            sessionCookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        logger.info("Session established (db=\(self.formTokenDB ?? "nil"), v=\(self.formTokenV ?? "nil"))")
    }

    // MARK: - Rate Limiting

    /// Serializes requests with a strict 500ms gap between consecutive calls.
    ///
    /// Slot-reservation pattern: each caller atomically advances `nextRequestSlot`
    /// to its scheduled wall-clock time, then sleeps until that moment before
    /// firing. Because the slot advancement happens entirely synchronously on
    /// the actor (no `await` between read and write), 12 concurrent search()
    /// calls each get a unique slot 500ms apart — they don't pile up and hit
    /// the volunteer source simultaneously.
    ///
    /// FreeBMD is a single-volunteer transcription project; we deliberately do
    /// not run requests in parallel. 12 districts × 0.5s = ~6s per record type
    /// per pipeline iteration. That's well-behaved (2 req/sec, similar to a
    /// human browsing).
    private func rateLimitedRequest(_ operation: () async throws -> Data) async throws -> Data {
        let scheduledFor = reserveNextSlot()
        let now = ContinuousClock.now
        if scheduledFor > now {
            try await Task.sleep(until: scheduledFor, clock: .continuous)
        }
        return try await operation()
    }

    /// Atomically (within the actor's serial section, no await) compute the
    /// next available slot and advance `nextRequestSlot` past it.
    private func reserveNextSlot() -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        let scheduledFor: ContinuousClock.Instant
        if let nextSlot = nextRequestSlot, nextSlot > now {
            // Queue forms — schedule after the previous reservation.
            scheduledFor = nextSlot
        } else {
            // No queue — go now.
            scheduledFor = now
        }
        nextRequestSlot = scheduledFor.advanced(by: requestDelay)
        return scheduledFor
    }

    // MARK: - Parsing (static, testable)

    /// Parse the searchData JavaScript array from a FreeBMD results page.
    /// Ported faithfully from Python's _parse_html().
    ///
    /// `querySurname` is the surname we asked for. FreeBMD's response
    /// compresses by blanking the surname column when a row's surname
    /// equals the search query — for our Cauldwell search every row in
    /// `searchData` IS a Cauldwell record, but rows render as
    /// `40;;David N;Wheeldon;;Ashbourne;3a;12;...` with `parts[1]` empty.
    /// Reading that literally gives the record `surname = ""`, which
    /// fails the name gate and silently drops every record. Filling
    /// `parts[1]` from the query when it's blank is safe because the
    /// query constrains the result set to that surname (only loose-mode
    /// phonetic / variant searches can return foreign surnames, and
    /// those bypass this code path — they're handled by the dispatcher's
    /// variant fan-out before parsing).
    nonisolated static func parseSearchResults(_ html: String, recordType: RecordType, querySurname: String = "") -> [SourceRecord] {
        // Extract JavaScript array: var searchData = new Array ("row1","row2",...);
        let arrayPattern = #"var searchData = new Array \((.*?)\);"#
        guard let regex = try? NSRegularExpression(pattern: arrayPattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return []
        }

        let arrayContent = String(html[range])

        // Extract individual quoted strings
        let rowPattern = #""([^"]*)""#
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern) else { return [] }
        let rowMatches = rowRegex.matches(in: arrayContent, range: NSRange(arrayContent.startIndex..., in: arrayContent))

        var records: [SourceRecord] = []
        var currentYear: Int?
        var currentQuarter: String?

        for rowMatch in rowMatches {
            guard let rowRange = Range(rowMatch.range(at: 1), in: arrayContent) else { continue }
            let row = String(arrayContent[rowRange])
            let parts = row.components(separatedBy: ";")

            // Separator rows: parts[1] in ("0","1","2"), parts[2] is quarter (1-4), parts[3] is year
            if parts.count >= 4,
               ["0", "1", "2"].contains(parts[1]),
               ["1", "2", "3", "4"].contains(parts[2]) {
                currentQuarter = quarterNames[parts[2]]
                currentYear = Int(parts[3])
                continue
            }

            // Data rows: confidence;surname;firstname;spouse_or_mother;flag;district;vol;page;id
            if parts.count >= 8,
               !parts[2].isEmpty,
               parts[2] != "Q",
               !parts[2].hasPrefix("/") {

                // Blank surname → FreeBMD compression: row's surname equals
                // the search query. Fill from `querySurname` so the name
                // gate sees the correct value. Without this every
                // post-1900-ish record drops silently because FreeBMD
                // started eliding the duplicate surname column.
                let rawSurname = parts[1]
                let surname = rawSurname.isEmpty ? querySurname : rawSurname
                let firstname = parts[2].removingPercentEncoding ?? parts[2]
                let spouseOrMother = (parts[3].removingPercentEncoding ?? parts[3]).trimmingCharacters(in: .whitespaces)
                let district = parts[5]
                let vol = parts[6]
                let page = parts[7]
                let recordID = parts.count > 8 ? parts[8].components(separatedBy: ":").first ?? "" : ""

                let common = RecordCommon(
                    id: "freebmd_\(recordType.rawValue)_\(vol)_\(page)_\(recordID)",
                    sourceID: "freebmd",
                    name: "\(firstname) \(surname)",
                    surname: surname,
                    givenName: firstname,
                    detailURL: nil,
                    rawFields: [
                        "quarter": currentQuarter ?? "",
                        "year": currentYear.map(String.init) ?? "",
                        "spouse_or_mother": spouseOrMother,
                        "district": district,
                        "vol": vol,
                        "page": page,
                    ]
                )

                let record: SourceRecord = switch recordType {
                case .birth:
                    .birth(BirthRecord(
                        common: common,
                        birthYear: currentYear,
                        birthDate: nil,
                        birthPlace: nil,
                        quarter: currentQuarter,
                        district: district,
                        volume: vol,
                        page: page,
                        mothersMaidenName: spouseOrMother.isEmpty ? nil : spouseOrMother
                    ))
                case .death:
                    .death(DeathRecord(
                        common: common,
                        deathYear: currentYear,
                        deathDate: nil,
                        deathPlace: nil,
                        age: Int(spouseOrMother),  // FreeBMD puts age in spouse_or_mother for deaths
                        quarter: currentQuarter,
                        district: district,
                        volume: vol,
                        page: page,
                        spouseSurname: Int(spouseOrMother) == nil ? spouseOrMother : nil
                    ))
                case .marriage:
                    .marriage(MarriageRecord(
                        common: common,
                        marriageYear: currentYear,
                        marriageDate: nil,
                        marriagePlace: nil,
                        quarter: currentQuarter,
                        district: district,
                        volume: vol,
                        page: page,
                        spouseName: spouseOrMother.isEmpty ? nil : spouseOrMother
                    ))
                default:
                    .birth(BirthRecord(
                        common: common,
                        birthYear: currentYear,
                        birthDate: nil, birthPlace: nil,
                        quarter: currentQuarter, district: district,
                        volume: vol, page: page, mothersMaidenName: nil
                    ))
                }

                records.append(record)
            }
        }

        return records
    }

    /// Extract a hidden form field value by name.
    nonisolated private static func extractFormValue(named name: String, from html: String) -> String? {
        let pattern = "name=\"\(name)\"\\s+value=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
}
