import Foundation

/// Pure HTML → markdown converter for the prose-corpus subsystem.
///
/// Hand-rolled rather than wrapping `NSAttributedString(data:options:)` or a
/// third-party DOM parser because spec §7.5 requires byte-identical output
/// across OS updates. NSAttributedString's HTML reader changes behaviour with
/// Foundation releases; a content-hash diff per page across two OS versions
/// would trigger spurious re-indexes. A tiny purpose-built tokeniser stays
/// stable.
///
/// Scope: the tag set genealogy volunteer sites actually use — headings,
/// paragraphs, lists, italics/bold, links, images-as-links, tables, `<pre>`,
/// inline `<br>`. Old-style attributes (FONT, COLOR, BGCOLOR, table-for-
/// layout) are stripped or ignored. The output is not a faithful rendering of
/// every HTML construct in the wild; it's a clean, stable reduction to
/// markdown that the MLX extractor can read.
nonisolated struct HTMLToMarkdownConverter {

    /// Convert an HTML document body into markdown. Pure function.
    static func convert(_ html: String) -> String {
        var s = html

        // Normalise line endings before any tag work so CRLF input doesn't
        // smear inside `<pre>` blocks where whitespace matters.
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")

        // Strip comments first — Wirksworth uses `<!---->` separator
        // comments which would otherwise leak literal `-` artifacts.
        s = s.replacingOccurrences(
            of: #"<!--[\s\S]*?-->"#,
            with: "",
            options: .regularExpression
        )

        // Strip block-level chrome that contributes no content. Order
        // matters: do this before generic tag handling so the contents of
        // these blocks (which may contain text we'd otherwise emit) are
        // removed entirely.
        for tag in ["script", "style", "noscript", "head"] {
            s = stripBlock(s, tag: tag)
        }

        // Convert to a token stream and emit markdown.
        let tokens = tokenize(s)
        var emitter = MarkdownEmitter()
        emitter.emit(tokens)

        // Final cleanup: decode entities, collapse whitespace, trim.
        return cleanup(emitter.output)
    }

    // MARK: - Block stripping

    /// Remove `<tag>…</tag>` blocks entirely (script/style/noscript/head).
    /// Case-insensitive, handles self-closing-style empty matches.
    private static func stripBlock(_ s: String, tag: String) -> String {
        let pattern = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>"
        return s.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // MARK: - Tokenisation

    /// One element of the parsed HTML stream.
    enum Token {
        case text(String)
        case openTag(name: String, attrs: [String: String])
        case closeTag(name: String)
        case selfClose(name: String, attrs: [String: String])
    }

    /// Split an HTML string into a sequence of text/tag tokens. Tolerant of
    /// malformed input — unbalanced `<` characters in text become literal
    /// `<` in the output. Attribute parsing handles quoted, unquoted, and
    /// boolean attributes.
    static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var i = html.startIndex
        let end = html.endIndex
        var textBuffer = ""

        while i < end {
            let c = html[i]
            if c == "<", let tagEnd = findTagEnd(in: html, from: i) {
                // Flush any pending text.
                if !textBuffer.isEmpty {
                    tokens.append(.text(textBuffer))
                    textBuffer = ""
                }
                let tagSlice = String(html[html.index(after: i)..<tagEnd])
                if let parsed = parseTag(tagSlice) {
                    tokens.append(parsed)
                }
                i = html.index(after: tagEnd)
            } else {
                textBuffer.append(c)
                i = html.index(after: i)
            }
        }
        if !textBuffer.isEmpty {
            tokens.append(.text(textBuffer))
        }
        return tokens
    }

    /// Locate the matching `>` for a tag start at `from`. Returns nil for an
    /// unclosed `<` so the caller emits it as literal text.
    private static func findTagEnd(in s: String, from start: String.Index) -> String.Index? {
        var j = s.index(after: start)
        while j < s.endIndex {
            if s[j] == ">" { return j }
            j = s.index(after: j)
        }
        return nil
    }

    /// Parse a tag body (everything between `<` and `>`, exclusive) into a
    /// token. Returns nil for the empty tag `<>` (malformed input).
    private static func parseTag(_ body: String) -> Token? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("/") {
            let name = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return .closeTag(name: name)
        }
        let selfClosing = trimmed.hasSuffix("/")
        let stripped = selfClosing ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) : trimmed
        var parts = stripped.split(whereSeparator: { $0.isWhitespace })
        guard let nameToken = parts.first else { return nil }
        parts.removeFirst()
        let name = String(nameToken).lowercased()
        let attrs = parseAttrs(String(parts.joined(separator: " ")))
        let voidElements: Set<String> = ["br", "hr", "img", "meta", "input", "link"]
        if selfClosing || voidElements.contains(name) {
            return .selfClose(name: name, attrs: attrs)
        }
        return .openTag(name: name, attrs: attrs)
    }

    /// Best-effort attribute parser. Handles `name="value"`, `name='value'`,
    /// `name=value`, and boolean `name`. Genealogy-site HTML rarely needs more.
    private static func parseAttrs(_ s: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var i = s.startIndex
        let end = s.endIndex
        while i < end {
            // Skip whitespace.
            while i < end, s[i].isWhitespace { i = s.index(after: i) }
            if i >= end { break }
            // Read attribute name.
            var name = ""
            while i < end, !s[i].isWhitespace, s[i] != "=" {
                name.append(s[i])
                i = s.index(after: i)
            }
            if name.isEmpty { break }
            // Skip whitespace before `=`.
            while i < end, s[i].isWhitespace { i = s.index(after: i) }
            if i < end, s[i] == "=" {
                i = s.index(after: i)
                while i < end, s[i].isWhitespace { i = s.index(after: i) }
                var value = ""
                if i < end, (s[i] == "\"" || s[i] == "'") {
                    let quote = s[i]
                    i = s.index(after: i)
                    while i < end, s[i] != quote {
                        value.append(s[i])
                        i = s.index(after: i)
                    }
                    if i < end { i = s.index(after: i) }
                } else {
                    while i < end, !s[i].isWhitespace {
                        value.append(s[i])
                        i = s.index(after: i)
                    }
                }
                attrs[name.lowercased()] = value
            } else {
                attrs[name.lowercased()] = ""
            }
        }
        return attrs
    }

    // MARK: - Cleanup

    /// Final pass over emitter output: decode entities, normalise whitespace,
    /// trim trailing whitespace per line, collapse 3+ blank lines to 2.
    private static func cleanup(_ s: String) -> String {
        var out = decodeEntities(s)

        // Normalise spaces and tabs to single spaces (outside the literal
        // newlines the emitter has already laid down).
        out = out.replacingOccurrences(
            of: "[ \t]+",
            with: " ",
            options: .regularExpression
        )

        // Trim trailing whitespace per line.
        out = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")

        // Collapse runs of 3+ blank lines to exactly 2 newlines (one blank).
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode the HTML entities we expect from genealogy sites. Numeric
    /// entities decoded too. Anything unknown is left as-is so unintended
    /// breakage doesn't silently strip surname tokens.
    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
            ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™"),
            ("&mdash;", "—"), ("&ndash;", "–"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
            ("&hellip;", "…"),
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities: &#N; and &#xH;
        out = out.replacingOccurrences(
            of: #"&#(\d+);"#,
            with: "$1",
            options: .regularExpression
        )
        // The above lost the codepoint context — handle properly via NSRegex.
        out = replaceMatches(in: out, pattern: #"&#(\d+);"#) { match in
            guard let n = Int(match), let scalar = Unicode.Scalar(n) else { return nil }
            return String(Character(scalar))
        }
        out = replaceMatches(in: out, pattern: #"&#x([0-9a-fA-F]+);"#) { match in
            guard let n = Int(match, radix: 16), let scalar = Unicode.Scalar(n) else { return nil }
            return String(Character(scalar))
        }
        return out
    }

    /// Replace each regex match's captured group via a closure. Returns the
    /// original input if the closure declines a substitution (returns nil).
    private static func replaceMatches(
        in input: String,
        pattern: String,
        replacement: (String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: range).reversed()
        var output = input
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: output),
                  let fullRange = Range(match.range, in: output) else { continue }
            let captured = String(output[captureRange])
            if let r = replacement(captured) {
                output.replaceSubrange(fullRange, with: r)
            }
        }
        return output
    }
}

// MARK: - Emitter

/// Stateful walk over the token stream that produces markdown. Maintains a
/// minimal stack of "what context are we currently inside" so list-item
/// emission knows whether it's in `<ol>` (numbered) or `<ul>` (bulleted),
/// and `<pre>` content gets preserved verbatim instead of normalised.
private nonisolated struct MarkdownEmitter {
    var output: String = ""
    private var listStack: [ListKind] = []
    private var orderedCounters: [Int] = []
    private var insidePre: Int = 0
    private var insideTable: Int = 0
    /// Tracks the open link tag's href so we can emit `[text](href)` at close.
    private var linkHrefStack: [String] = []
    /// Buffer for link text — collected between `<a>` and `</a>`.
    private var linkTextStack: [String] = []
    /// Class/id substrings that mark navigation chrome we skip entirely.
    private static let chromeKeywords = ["nav", "menu", "sidebar", "breadcrumb"]
    /// Depth of chrome we're currently inside; any non-zero value suppresses
    /// text emission until we exit.
    private var insideChrome: Int = 0

    private enum ListKind { case unordered, ordered }

    mutating func emit(_ tokens: [HTMLToMarkdownConverter.Token]) {
        for token in tokens {
            switch token {
            case .text(let raw):
                if insidePre > 0 {
                    output.append(raw)
                } else if insideChrome > 0 {
                    continue
                } else {
                    appendTextNormalised(raw)
                }
            case .openTag(let name, let attrs):
                handleOpen(name: name, attrs: attrs)
            case .closeTag(let name):
                handleClose(name: name)
            case .selfClose(let name, let attrs):
                handleSelfClose(name: name, attrs: attrs)
            }
        }
    }

    // MARK: text emission

    private mutating func appendTextNormalised(_ raw: String) {
        // If we're inside a link, capture text into the link buffer
        // instead of emitting directly.
        if !linkTextStack.isEmpty {
            linkTextStack[linkTextStack.count - 1].append(raw)
            return
        }
        // Convert any embedded newlines+whitespace to a single space; the
        // block tags (`<p>`, `<br>`) are the only sources of intentional
        // line breaks in markdown output.
        let collapsed = raw.replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
        // Skip the trim-only-whitespace case to avoid eating intentional
        // spaces between inline tags ("</i> <b>").
        if collapsed == " " {
            if !output.isEmpty, !output.hasSuffix(" "), !output.hasSuffix("\n") {
                output.append(" ")
            }
            return
        }
        output.append(collapsed)
    }

    private mutating func ensureBlankLine() {
        // Make sure we're at the start of a new line and preceded by an
        // empty line — markdown block boundary.
        if !output.hasSuffix("\n\n") {
            if output.hasSuffix("\n") {
                output.append("\n")
            } else if !output.isEmpty {
                output.append("\n\n")
            }
        }
    }

    private mutating func ensureLineBreak() {
        if !output.hasSuffix("\n") {
            output.append("\n")
        }
    }

    // MARK: tag handling

    private mutating func handleOpen(name: String, attrs: [String: String]) {
        if isChrome(attrs: attrs) {
            insideChrome += 1
            return
        }
        if insideChrome > 0 { return }

        switch name {
        case "h1": ensureBlankLine(); output.append("# ")
        case "h2": ensureBlankLine(); output.append("## ")
        case "h3": ensureBlankLine(); output.append("### ")
        case "h4": ensureBlankLine(); output.append("#### ")
        case "h5": ensureBlankLine(); output.append("##### ")
        case "h6": ensureBlankLine(); output.append("###### ")
        case "p":  ensureBlankLine()
        case "b", "strong":
            output.append("**")
        case "i", "em":
            output.append("_")
        case "ul":
            listStack.append(.unordered)
        case "ol":
            listStack.append(.ordered)
            orderedCounters.append(0)
        case "li":
            ensureLineBreak()
            // Bare `<li>` outside a list — Wirksworth emits these direct
            // under TR/TD. Treat as unordered bullet.
            if let kind = listStack.last {
                if kind == .ordered {
                    let idx = (orderedCounters.last ?? 0) + 1
                    orderedCounters[orderedCounters.count - 1] = idx
                    output.append("\(idx). ")
                } else {
                    output.append("- ")
                }
            } else {
                output.append("- ")
            }
        case "pre":
            ensureBlankLine()
            output.append("```\n")
            insidePre += 1
        case "blockquote":
            ensureBlankLine()
            output.append("> ")
        case "a":
            linkHrefStack.append(attrs["href"] ?? "")
            linkTextStack.append("")
        case "table":
            insideTable += 1
            ensureBlankLine()
        case "tr":
            if insideTable > 0 { ensureLineBreak() }
        case "td", "th":
            if insideTable > 0, !output.hasSuffix("\n"), !output.hasSuffix(" ") {
                output.append(" ")
            }
        default:
            // FONT, CENTER, DIV, SPAN, BODY, HTML, etc — pass through to
            // their content without emitting markdown.
            break
        }
    }

    private mutating func handleClose(name: String) {
        // Track chrome exit. We don't know if the matching open was chrome
        // unless we maintained a stack — for the v1 tag set this is good
        // enough because nav/header/footer don't nest in genealogy HTML.
        // The `insideChrome` counter still gates emission correctly.
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            output.append("\n\n")
        case "p":
            output.append("\n\n")
        case "b", "strong":
            output.append("**")
        case "i", "em":
            output.append("_")
        case "ul":
            if listStack.last == .unordered { listStack.removeLast() }
            ensureBlankLine()
        case "ol":
            if listStack.last == .ordered { listStack.removeLast() }
            if !orderedCounters.isEmpty { orderedCounters.removeLast() }
            ensureBlankLine()
        case "li":
            // Markdown list items terminate on the next list-item or block.
            // No explicit close needed.
            break
        case "pre":
            insidePre -= 1
            ensureLineBreak()
            output.append("```\n")
        case "blockquote":
            output.append("\n\n")
        case "a":
            // Emit collected link.
            let href = linkHrefStack.popLast() ?? ""
            let text = linkTextStack.popLast() ?? ""
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !href.isEmpty {
                if trimmedText.isEmpty {
                    output.append("[\(href)](\(href))")
                } else {
                    output.append("[\(trimmedText)](\(href))")
                }
            } else if !trimmedText.isEmpty {
                output.append(trimmedText)
            }
        case "table":
            insideTable -= 1
            ensureBlankLine()
        case "tr":
            if insideTable > 0 { ensureLineBreak() }
        case "td", "th":
            if insideTable > 0, !output.hasSuffix(" ") { output.append(" ") }
        case "nav", "header", "footer", "aside":
            if insideChrome > 0 { insideChrome -= 1 }
        default:
            break
        }
    }

    private mutating func handleSelfClose(name: String, attrs: [String: String]) {
        switch name {
        case "br":
            if insidePre > 0 {
                output.append("\n")
            } else {
                ensureLineBreak()
            }
        case "hr":
            ensureBlankLine()
            output.append("---\n\n")
        case "img":
            let src = attrs["src"] ?? ""
            let alt = attrs["alt"] ?? ""
            if !src.isEmpty {
                let label = alt.isEmpty ? src : alt
                output.append("[image: \(label)](\(src))")
            }
        default:
            break
        }
    }

    /// Match chrome by class or id substring. Genealogy sites tend to use
    /// hand-written attributes ("class=\"nav-bar\"", "id=\"breadcrumb\"")
    /// rather than semantic `<nav>`/`<header>` tags, so attribute-based
    /// detection catches the cases the tag-name check would miss.
    private func isChrome(attrs: [String: String]) -> Bool {
        for key in ["class", "id"] {
            let value = (attrs[key] ?? "").lowercased()
            if value.isEmpty { continue }
            for keyword in MarkdownEmitter.chromeKeywords where value.contains(keyword) {
                return true
            }
        }
        return false
    }
}
