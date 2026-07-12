import CryptoKit
import Foundation
import os

/// Wirksworth Parish Records — Ince's Pedigrees and parish register transcriptions
/// http://www.wirksworth.org.uk/
/// Access: GET → HTML pages (narrative pedigrees + structured PRE-formatted registers)
/// Auth: None
/// Coverage: ~1550–1860, Wirksworth/Middleton/Matlock area, Derbyshire
/// Faithfully ported from Python's sources/wirksworth.py
struct WirksworthSource: RecordSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "wirksworth"
    nonisolated let displayName = "Wirksworth Parish Records"
    nonisolated let recordTypes: Set<RecordType> = [.pedigree, .parish]
    // Coverage corrected 2026-05-20: the project's own homepage banner
    // ("WIRKSWORTH Parish Records 1600-1900") and the published CENSUS
    // page (1841-1891 transcriptions) establish the actual range. The
    // prior 1550-1860 window was 50 years too early on the low side
    // (parish registers start ~1600) and 40 years too tight on the high
    // side (missed Edwardian + early-WWI Derbyshire ancestors).
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1600...1900
    nonisolated let coverageRegions: Set<Region> = [.parish("Wirksworth", county: "Derbyshire")]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "parish-registers")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(
        level: .community,
        summary: "Volunteer-contributed pedigrees and register transcriptions"
    )
    /// Conservative daily budget (ENGINE_FOUNDATION #Change5). A tiny
    /// single-area volunteer dataset — low request volume, but still
    /// volunteer-hosted, so a generous daily ceiling parks a runaway
    /// sustained run without ever constraining normal use.
    nonisolated let budgetPolicy = SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)
    nonisolated let kind: SourceKind = .localPlugin

    // MARK: - State

    private let http: any HTTPClient
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Wirksworth")

    init(http: any HTTPClient = SourceHTTPClient.shared) {
        self.http = http
    }

    // MARK: - Constants

    nonisolated private static let baseURL = "http://www.wirksworth.org.uk"
    nonisolated private static let pedigreeIndexURL = "http://www.wirksworth.org.uk/PEDIGREE.htm"
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard recordTypes.contains(query.recordType) else {
            return .outsideCoverage(reason: "Wirksworth provides pedigree and parish records only")
        }
        guard let surname = query.surname, !surname.isEmpty else { return .results([]) }

        let summary = Self.activitySummary(query: query, surname: surname)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        do {
            // First, search the pedigree index for matching surname
            let indexData = try await http.get(url: URL(string: Self.pedigreeIndexURL)!, headers: [
                "User-Agent": Self.userAgent,
            ])
            let indexHTML = String(data: indexData, encoding: .utf8) ?? ""
            let matchingPedigrees = Self.parsePedigreeIndex(indexHTML, forSurname: surname)

            guard !matchingPedigrees.isEmpty else {
                logger.info("Wirksworth: no pedigrees matching \(surname)")
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: 0, strictness: query.strictness))
                return .results([])
            }

            // Fetch and parse each matching pedigree page
            var allRecords: [SourceRecord] = []
            for pedigree in matchingPedigrees.prefix(3) { // Limit to 3 pages
                guard let pageURL = URL(string: pedigree.url) else { continue }
                let pageData = try await http.get(url: pageURL, headers: [
                    "User-Agent": Self.userAgent,
                ])
                let pageHTML = String(data: pageData, encoding: .utf8) ?? ""
                let records = Self.parsePedigreePage(pageHTML, surname: surname, url: pedigree.url)
                allRecords.append(contentsOf: records)
            }

            logger.info("Wirksworth: \(allRecords.count) records for \(surname)")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: allRecords.count, strictness: query.strictness))
            return .results(allRecords)
        } catch {
            logger.error("Wirksworth search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// Build a one-line description of a Wirksworth query for the live activity feed.
    nonisolated static func activitySummary(query: RecordQuery, surname: String) -> String {
        let searchTerms: String = {
            if let given = query.givenName, !given.isEmpty { return "\(given) \(surname)" }
            return surname
        }()
        return "Wirksworth pedigrees: \(searchTerms)"
    }

    // MARK: - Index Parsing

    nonisolated struct PedigreeEntry {
        let surname: String
        let code: String
        let url: String
        let contributor: String
    }

    /// Parse the pedigree index page to find matching surnames.
    nonisolated static func parsePedigreeIndex(_ html: String, forSurname surname: String) -> [PedigreeEntry] {
        let pattern = #"<A\s+HREF=([^>]+\.htm)>([^<]+)</A></TD><TD><H5>([^<]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        let upper = surname.uppercased()

        return matches.compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let contribRange = Range(match.range(at: 3), in: html) else { return nil }

            let href = String(html[hrefRange]).trimmingCharacters(in: .whitespaces)
            let name = String(html[nameRange]).trimmingCharacters(in: .whitespaces)
            let contributor = String(html[contribRange]).trimmingCharacters(in: .whitespaces)

            // Skip non-pedigree entries
            guard !name.isEmpty, name != "most recent", name != "largest" else { return nil }

            // Match if surname appears in pedigree name
            guard name.uppercased().contains(upper) else { return nil }

            let code = href.replacingOccurrences(of: ".htm", with: "").replacingOccurrences(of: ".HTM", with: "")
            return PedigreeEntry(
                surname: name,
                code: code,
                url: "\(baseURL)/\(href)",
                contributor: contributor
            )
        }
    }

    // MARK: - Pedigree Parsing

    /// Parse a pedigree page — auto-detects structured (PRE) vs narrative format.
    nonisolated static func parsePedigreePage(_ html: String, surname: String, url: String) -> [SourceRecord] {
        if html.contains("<PRE>") || html.contains("<pre>") {
            return parseStructuredPedigree(html, surname: surname, url: url)
        } else {
            return parseNarrativePedigree(html, surname: surname, url: url)
        }
    }

    /// Parse structured PRE-formatted pedigree (generation numbers + dates in parentheses).
    nonisolated static func parseStructuredPedigree(_ html: String, surname: String, url: String) -> [SourceRecord] {
        var records: [SourceRecord] = []
        var seen: Set<String> = []

        // Extract PRE blocks
        let prePattern = #"<PRE>(.*?)</PRE>"#
        guard let preRegex = try? NSRegularExpression(pattern: prePattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return []
        }

        let preMatches = preRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        let blocks = preMatches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }

        let text = blocks.isEmpty ? stripHTML(html) : blocks.joined(separator: "\n")

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Match: generation number + name
            let linePattern = #"^(\d+)\s+([A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+)*)"#
            guard let lineRegex = try? NSRegularExpression(pattern: linePattern),
                  let lineMatch = lineRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let genRange = Range(lineMatch.range(at: 1), in: trimmed),
                  let nameRange = Range(lineMatch.range(at: 2), in: trimmed) else { continue }

            let gen = Int(trimmed[genRange]) ?? 0
            let name = String(trimmed[nameRange])

            let birthYear = extractDateFromLine(trimmed, keywords: ["bpt", "bp", "b"])
            let deathYear = extractDateFromLine(trimmed, keywords: ["d"])
            let marriageYear = extractDateFromLine(trimmed, keywords: ["m"])
            let spouse = extractSpouse(from: trimmed)

            let key = "\(name.lowercased())_\(birthYear ?? 0)_\(gen)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let common = RecordCommon(
                id: stableRecordID(pageURL: url, rowKey: key),
                sourceID: "wirksworth",
                name: name, surname: surname, givenName: name.components(separatedBy: " ").first,
                detailURL: url,
                rawFields: ["generation": String(gen), "source_line": String(trimmed.prefix(200))]
            )

            records.append(.pedigree(PedigreeRecord(
                common: common,
                birthYear: birthYear,
                deathYear: deathYear,
                spouse: spouse,
                marriageYear: marriageYear,
                occupation: nil,
                location: "Wirksworth, Derbyshire",
                generation: gen
            )))
        }

        return records
    }

    /// Parse narrative-style pedigree — best-effort pattern matching.
    nonisolated static func parseNarrativePedigree(_ html: String, surname: String, url: String) -> [SourceRecord] {
        let text = stripHTML(html)
        var records: [SourceRecord] = []
        var seen: Set<String> = []

        // "Name born YEAR" pattern
        let bornPattern = #"([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\s+born?\s+(?:\w+\s+\d+\w*\s+)?(\d{4})"#
        if let regex = try? NSRegularExpression(pattern: bornPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let nameRange = Range(match.range(at: 1), in: text),
                      let yearRange = Range(match.range(at: 2), in: text) else { continue }

                let name = String(text[nameRange])
                let birthYear = Int(text[yearRange])

                let key = "\(name.lowercased())_\(birthYear ?? 0)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                let common = RecordCommon(
                    id: stableRecordID(pageURL: url, rowKey: key),
                    sourceID: "wirksworth",
                    name: name, surname: surname, givenName: name.components(separatedBy: " ").first,
                    detailURL: url, rawFields: [:]
                )

                records.append(.pedigree(PedigreeRecord(
                    common: common,
                    birthYear: birthYear,
                    deathYear: nil, spouse: nil, marriageYear: nil,
                    occupation: nil, location: "Wirksworth, Derbyshire", generation: nil
                )))
            }
        }

        return records
    }

    // MARK: - Helpers

    /// Stable record ID (connector-audit FT-16). Record IDs are load-bearing
    /// across app launches — `record_rejections` and `evidence_records.user_status`
    /// are keyed on them — so they must never be built from `String.hashValue`,
    /// which is SipHash with a per-process random seed (a different ID every
    /// launch silently orphans user discard decisions).
    ///
    /// Wirksworth is a static site with stable page URLs, so the ID combines
    /// the pedigree page code (URL filename sans extension, for debuggability)
    /// with a SHA256 digest of `pageURL|rowKey`, truncated to 16 hex chars.
    /// Including the page URL in the digest keeps identical rows on two
    /// different pedigree pages distinct — they are separate evidence pages.
    nonisolated static func stableRecordID(pageURL: String, rowKey: String) -> String {
        let digest = SHA256.hash(data: Data("\(pageURL)|\(rowKey)".utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: pageURL) else { return "wirksworth_\(hex)" }
        let pageCode = url.deletingPathExtension().lastPathComponent
        return pageCode.isEmpty || pageCode == "/"
            ? "wirksworth_\(hex)"
            : "wirksworth_\(pageCode)_\(hex)"
    }

    nonisolated private static func stripHTML(_ text: String) -> String {
        var result = text
        // Remove HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&#160;", with: " ")
        // Collapse whitespace
        if let regex = try? NSRegularExpression(pattern: "\\s+") {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Extract a year from a line following keywords like bpt, b, d, m.
    nonisolated private static func extractDateFromLine(_ line: String, keywords: [String]) -> Int? {
        for kw in keywords {
            // Try "kw (date)" or "kw YEAR"
            let fullPattern = "\\b\(kw)\\s*(?:\\(([^)]+)\\)|(\\d{4}))"
            if let regex = try? NSRegularExpression(pattern: fullPattern),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                if let range = Range(match.range(at: 1), in: line) {
                    let dateStr = String(line[range])
                    if let year = extractFourDigitYear(from: dateStr) { return year }
                }
                if let range = Range(match.range(at: 2), in: line) {
                    return Int(line[range])
                }
            }
        }
        return nil
    }

    nonisolated private static func extractFourDigitYear(from text: String) -> Int? {
        let pattern = #"(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    /// Extract spouse name from "m SpouseName" pattern.
    nonisolated private static func extractSpouse(from line: String) -> String? {
        let pattern = #"\bm\s+(?:\([^)]+\)\s+)?([A-Z][a-z]+(?:\s+[A-Z][A-Za-z]+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}
