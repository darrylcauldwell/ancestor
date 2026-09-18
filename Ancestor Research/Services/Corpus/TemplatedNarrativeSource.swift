import Foundation

/// WHY this class of site is worth the effort, given it is prose HTML with no
/// API: memorial-inscription transcriptions, parish histories, Online Parish
/// Clerk projects and GENUKI hold **discriminating** evidence a namesake-heavy
/// BMD index cannot — death dates, ages (implying birth years) and family
/// groupings, exactly the fields that separate a subject from their namesakes.
/// Both obvious routes fail: a bespoke connector per site is too much code for
/// the yield, and a whole-site crawl is forbidden by most of these sites' terms
/// ("may not copy… as a whole") and hammers a volunteer server. Hence one
/// on-demand page, built from a template. Outstanding: `#TNS1` live-run
/// verification, `#TNS2` the user-add UI.
///
/// Stage 1 — a config-driven Chapman-templated
/// narrative source. A source is a URL TEMPLATE plus a parser; adding a site is a
/// config entry, not a bespoke connector. The template is filled per-subject from
/// the Chapman code the pipeline already derives (with the project Home-county
/// fallback) and the subject's resolved parish, and we fetch ONLY that one local
/// page — never the whole site.

/// How a parish name maps into the URL path — the schemes differ per site.
nonisolated enum ParishSlugStyle: String, Codable, Sendable {
    case concatenated   // "South Darley" -> "SouthDarley"  (wishful-thinking)
    case hyphenated     // "South Darley" -> "South-Darley"
    case asIs           // "South Darley" -> "South%20Darley"

    func slug(_ parish: String) -> String {
        let words = parish
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        switch self {
        case .concatenated: return words.joined()
        case .hyphenated:   return words.joined(separator: "-")
        case .asIs:         return words.joined(separator: "%20")
        }
    }
}

/// Which parser turns a fetched page into facts.
nonisolated enum TemplatedParserKind: String, Codable, Sendable {
    case memorialInscription   // this site's stone format (MemorialInscriptionSource.parse)
    case prose                 // freer pages -> MLX prose extraction
}

/// A bundleable / user-addable source definition.
nonisolated struct TemplatedSourceConfig: Codable, Sendable, Equatable {
    let sourceID: String
    let displayName: String
    /// URL with `{chapman}` / `{parish}` / `{surname}` / `{county}` placeholders.
    let urlTemplate: String
    let parishStyle: ParishSlugStyle
    let parser: TemplatedParserKind
    /// Verbatim summary of the site's PUBLISHED terms (verified per site).
    let termsSummary: String
    let attributionRequired: Bool
}

/// Fills a URL template from a subject's derived context. Pure and deterministic;
/// never emits a URL with an unfilled placeholder.
nonisolated enum TemplatedURLResolver {

    struct Subject: Sendable, Equatable {
        var chapmanCode: String
        var parish: String?
        var surname: String?
        var county: String?

        init(chapmanCode: String, parish: String? = nil, surname: String? = nil, county: String? = nil) {
            self.chapmanCode = chapmanCode
            self.parish = parish
            self.surname = surname
            self.county = county
        }
    }

    static func resolve(_ config: TemplatedSourceConfig, subject: Subject) -> URL? {
        resolve(template: config.urlTemplate, parishStyle: config.parishStyle, subject: subject)
    }

    static func resolve(template: String, parishStyle: ParishSlugStyle, subject: Subject) -> URL? {
        var url = template

        // {chapman} — must be a real 3-letter Chapman code.
        if url.contains("{chapman}") {
            let code = subject.chapmanCode.trimmingCharacters(in: .whitespaces).uppercased()
            guard code.count == 3, code.allSatisfy({ $0.isLetter }) else { return nil }
            url = url.replacingOccurrences(of: "{chapman}", with: code)
        }

        // {parish}
        if url.contains("{parish}") {
            guard let parish = subject.parish?.trimmingCharacters(in: .whitespaces),
                  !parish.isEmpty else { return nil }
            let slug = parishStyle.slug(parish)
            guard !slug.isEmpty else { return nil }
            url = url.replacingOccurrences(of: "{parish}", with: slug)
        }

        // {surname}
        if url.contains("{surname}") {
            guard let surname = subject.surname?.trimmingCharacters(in: .whitespaces),
                  !surname.isEmpty else { return nil }
            let clean = surname
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined()
            guard !clean.isEmpty else { return nil }
            url = url.replacingOccurrences(of: "{surname}", with: clean)
        }

        // {county} — full county name; spaces percent-encoded.
        if url.contains("{county}") {
            guard let county = subject.county?.trimmingCharacters(in: .whitespaces),
                  !county.isEmpty else { return nil }
            url = url.replacingOccurrences(
                of: "{county}", with: county.split(separator: " ").joined(separator: "%20"))
        }

        // Any placeholder the template used but the subject couldn't fill (or a
        // typo'd token) leaves a brace behind — refuse rather than emit a broken URL.
        guard !url.contains("{") else { return nil }
        return URL(string: url)
    }
}

/// Bundled configs whose URL scheme AND published terms have been verified. Other
/// sites (GENUKI, county OPCs) are Stage-3 candidates — a config each, once
/// checked.
nonisolated enum TemplatedSourceCatalogue {

    /// Wishful Thinking (Mel & Rosemary Lockie) county memorial inscriptions.
    /// Terms verified 2026-08-05 at wishful-thinking.org.uk/Conditions.html:
    /// personal family-history research explicitly permitted; commercial sale,
    /// publication in family histories, and whole-site copying forbidden;
    /// attribution (URL) required. We fetch ONE parish page per lookup.
    static let wishfulThinkingMIs = TemplatedSourceConfig(
        sourceID: "wishful-thinking-mi",
        displayName: "Memorial Inscriptions (Wishful Thinking)",
        urlTemplate: "https://places.wishful-thinking.org.uk/{chapman}/{parish}/MIs.html",
        parishStyle: .concatenated,
        parser: .memorialInscription,
        termsSummary: "Personal family-history research permitted; commercial sale, "
            + "publication in family histories, and whole-site copying forbidden; "
            + "attribution (URL) required. One on-demand page per lookup — never a crawl.",
        attributionRequired: true)

    static let bundled: [TemplatedSourceConfig] = [wishfulThinkingMIs]
}
