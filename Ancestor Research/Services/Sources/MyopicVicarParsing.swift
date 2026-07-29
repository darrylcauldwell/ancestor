import Foundation

/// Shared parsing machinery for the two connectors whose live sites run
/// the SAME open-source Rails engine — FreeUKGen/MyopicVicar (FreeREG at
/// freereg.org.uk, FreeCEN at freecen.org.uk). Both render Rails CSRF
/// meta tags, kaminari/will_paginate pagination navs, "error prohibited"
/// validation banners, and header-keyed HTML tables — so the extraction
/// primitives live once here and the sources delegate.
///
/// FreeBMD is NOT in this family: freebmd.org.uk is the classic Perl CGI
/// system (MyopicVicar powers only the unreleased FreeBMD2), so
/// `FreeBMDSource` deliberately does not use these helpers.
///
/// Everything here is pure (String in, values out) — no networking, no
/// actor state. See `FREEREG_INTEGRATION_SPEC.md` §3.6.
nonisolated enum MyopicVicarParsing {

    // MARK: - CSRF

    /// Rails CSRF token from a form page: the `<meta name="csrf-token">`
    /// tag first, then the hidden `authenticity_token` input as the
    /// fallback (some render paths omit the meta tag). Whitespace-tolerant
    /// — the union of the two sources' previously-divergent patterns.
    static func csrfToken(fromHTML html: String) -> String? {
        let metaPattern = #"<meta\s+name="csrf-token"\s+content="([^"]+)""#
        if let token = firstGroup(metaPattern, in: html, options: .caseInsensitive) {
            return token
        }
        let inputPattern = #"<input[^>]+name="authenticity_token"[^>]+value="([^"]+)""#
        return firstGroup(inputPattern, in: html)
    }

    // MARK: - Pagination

    /// Next-page href from a kaminari/will_paginate nav (`rel="next"` or a
    /// `next`-classed anchor, either attribute order). Relative hrefs are
    /// resolved against `base`; absolute http(s) pass through; anything
    /// else is nil.
    static func nextPaginationHref(in html: String, base: String) -> String? {
        let patterns = [
            #"<a\b[^>]*rel="next"[^>]*href="([^"]+)""#,
            #"<a\b[^>]*href="([^"]+)"[^>]*rel="next""#,
            #"<a\b[^>]*class="[^"]*next[^"]*"[^>]*href="([^"]+)""#,
            #"<a\b[^>]*href="([^"]+)"[^>]*class="[^"]*next[^"]*""#,
        ]
        for pattern in patterns {
            if let raw = firstGroup(pattern, in: html) {
                let href = raw.replacingOccurrences(of: "&amp;", with: "&")
                if href.hasPrefix("http") { return href }
                if href.hasPrefix("/") { return base + href }
                return nil
            }
        }
        return nil
    }

    // MARK: - Validation banners

    /// True when the page carries a Rails validation-rejection banner
    /// ("error prohibited …" / "… prohibited this …") — a rejected POST,
    /// which must NEVER be read as a genuine empty result (FT-20/FT-26).
    static func hasValidationBanner(_ html: String) -> Bool {
        html.range(of: #"error prohibited|prohibited this"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The first error `<li>` inside an error-classed list, when the
    /// banner carries one — the human-readable rejection reason.
    static func validationErrorDetail(in html: String) -> String? {
        let liPattern = #"<ul[^>]*class="[^"]*error[^"]*"[^>]*>.*?<li[^>]*>(.*?)</li>"#
        guard let raw = firstGroup(liPattern, in: html, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return nil
        }
        let detail = stripTags(raw)
        return detail.isEmpty ? nil : detail
    }

    // MARK: - Tables

    /// Every `<table>` in the page as rows of tag-stripped cell strings —
    /// the primitive under header-keyed table parsing (search results,
    /// census dwelling/household, record detail). Empty rows/tables are
    /// dropped.
    static func tables(in html: String) -> [[[String]]] {
        let tablePattern = #"<table[^>]*>(.*?)</table>"#
        guard let tableRegex = try? NSRegularExpression(pattern: tablePattern, options: .dotMatchesLineSeparators) else {
            return []
        }
        var tables: [[[String]]] = []
        for match in tableRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let rows = rows(inTableHTML: String(html[range]))
            if !rows.isEmpty { tables.append(rows) }
        }
        return tables
    }

    /// Rows of an HTML table fragment as tag-stripped cell strings.
    ///
    /// Live MyopicVicar VLD partials render `<thead>` header cells with
    /// NO wrapping `<tr>` (`<thead><th>Surname</th>…</thead>`) — a
    /// tr-only scan misses the header row entirely, the first DATA row
    /// gets read as headers, and the roster is misclassified (verify
    /// finding 2026-07-29). So: a tr-less `<thead>` block's cells form
    /// the first row, then `<tr>`-wrapped rows follow as normal (a
    /// tr-wrapped thead is covered by the tr scan — no double-count).
    static func rows(inTableHTML table: String) -> [[String]] {
        let rowPattern = #"<tr[^>]*>(.*?)</tr>"#
        let theadPattern = #"<thead[^>]*>(.*?)</thead>"#
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: .dotMatchesLineSeparators),
              let theadRegex = try? NSRegularExpression(pattern: theadPattern, options: .dotMatchesLineSeparators) else {
            return []
        }
        var rows: [[String]] = []
        if let theadMatch = theadRegex.firstMatch(in: table, range: NSRange(table.startIndex..., in: table)),
           let theadRange = Range(theadMatch.range(at: 1), in: table) {
            let thead = String(table[theadRange])
            if thead.range(of: #"<tr\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
                let headerCells = cells(inRowHTML: thead)
                if !headerCells.isEmpty { rows.append(headerCells) }
            }
        }
        for match in rowRegex.matches(in: table, range: NSRange(table.startIndex..., in: table)) {
            guard let range = Range(match.range(at: 1), in: table) else { continue }
            let cells = cells(inRowHTML: String(table[range]))
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows
    }

    /// `<td>`/`<th>` cells of a row fragment, tag-stripped and trimmed.
    static func cells(inRowHTML row: String) -> [String] {
        let cellPattern = #"<t[dh][^>]*>(.*?)</t[dh]>"#
        guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: .dotMatchesLineSeparators) else {
            return []
        }
        return cellRegex.matches(in: row, range: NSRange(row.startIndex..., in: row)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: row) else { return nil }
            return stripTags(String(row[range]))
        }
    }

    // MARK: - Primitives

    /// Tag-strip + entity-decode + trim. MUST trim `.whitespacesAndNewlines`
    /// and decode entities — live ERB templates pad every cell with
    /// newlines (`<th>\n  Surname\n</th>`) and emit `&amp;`/`&#39;`; a
    /// whitespace-only trim leaves "\n  Surname\n", the exact-match header
    /// lookups fail, and household parsing dies on EVERY live page
    /// (verify finding 2026-07-29). Interior whitespace is preserved —
    /// the search-target marker split relies on the interior newline.
    static func stripTags(_ html: String) -> String {
        var result = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstGroup(
        _ pattern: String, in html: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
}
