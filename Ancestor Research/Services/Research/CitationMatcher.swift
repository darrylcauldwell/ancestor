import Foundation

/// Parses prose-form citations out of GEDCOM biography NOTE blocks and
/// decides whether two cited identifiers refer to the same source record.
///
/// Per `RESEARCH_PIPELINE_SPEC.md` §5.8.5: the §5.8 eval harness needs a
/// matcher to compute *evidence reproduction rate* — the fraction of a
/// certified profile's existing GEDCOM citations that the pipeline
/// surfaces. The twin-export GEDCOM stores citations as semi-structured
/// prose inside `1 NOTE` blocks (memory `gedcom_prose_citations.md`),
/// not as standard GEDCOM `SOUR`/`CITN` tags — so this matcher is a
/// tolerant pattern parser, not a tag walker.
///
/// Reference implementation in Python lives at
/// `eval/extract_gedcom_citations.py`. Keep the two in sync when adding
/// new patterns.
nonisolated struct CitationMatcher {

    // MARK: - Public API

    /// Parse all citations out of a single bio-note prose string.
    /// Returns an empty array if no recognised patterns match.
    static func parse(prose: String) -> [CitedIdentifier] {
        var out: [CitedIdentifier] = []
        out.append(contentsOf: parseFreeBMD(prose: prose))
        out.append(contentsOf: parseGRO(prose: prose))
        out.append(contentsOf: parseFamilySearchCensus(prose: prose))
        out.append(contentsOf: parseCWGC(prose: prose))
        return out
    }

    /// Decide whether two cited identifiers refer to the same source
    /// record. Symmetric — `equivalent(a, b) == equivalent(b, a)`.
    static func equivalent(_ a: CitedIdentifier, _ b: CitedIdentifier) -> CitationMatch {
        // GRO and FreeBMD both reference the same GRO index — treat as same family.
        guard sourceFamily(a.source) == sourceFamily(b.source) else { return .noMatch }
        guard a.kind == b.kind else { return .noMatch }

        switch sourceFamily(a.source) {
        case .freebmdFamily:
            return matchFreeBMD(a, b)
        case .familysearchFamily:
            return matchFamilySearchCensus(a, b)
        case .cwgcFamily:
            return matchCWGC(a, b)
        case .other:
            return matchGeneric(a, b)
        }
    }

    // MARK: - Pattern parsers

    private static func parseFreeBMD(prose: String) -> [CitedIdentifier] {
        // "FreeBMD birth Dec 1887 Belper vol7b p559"
        // "FreeBMD death Mar 1959 Ashbourne vol3a p14"
        // "FreeBMD birth Sep 1885 Belper"   (vol/page optional)
        let pattern = #/FreeBMD\s+(?<kind>birth|death|marriage)\s+(?<quarter>Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(?<year>\d{4})\s+(?<district>[A-Za-z][A-Za-z .'\-]*?)(?:\s+vol(?<vol>\w+)\s+p(?<page>\d+))?(?=[\s,.)]|$)/#.ignoresCase()
        return prose.matches(of: pattern).map { match in
            var ids: [String: String] = [
                "quarter": String(match.output.quarter),
                "year": String(match.output.year),
                "district": String(match.output.district).trimmingCharacters(in: .whitespaces),
            ]
            if let vol = match.output.vol { ids["volume"] = String(vol) }
            if let page = match.output.page { ids["page"] = String(page) }
            return CitedIdentifier(
                source: .freebmd,
                kind: bmdKind(String(match.output.kind)),
                identifiers: ids,
                raw: String(prose[match.range])
            )
        }
    }

    private static func parseGRO(prose: String) -> [CitedIdentifier] {
        // "GRO vol7b p977" inline in narrative — same shape as FreeBMD vol/page.
        // Context determines kind: "married"/"birth"/"died" within ~200 chars.
        let pattern = #/GRO\s+vol(?<vol>\w+)\s+p(?<page>\d+)/#.ignoresCase()
        return prose.matches(of: pattern).compactMap { match in
            let start = prose.index(match.range.lowerBound, offsetBy: -200, limitedBy: prose.startIndex) ?? prose.startIndex
            let ctx = String(prose[start..<match.range.lowerBound]).lowercased()
            let kind: CitationKind
            if ctx.contains("marri") {
                kind = .marriageRegistration
            } else if ctx.contains("born") || ctx.contains("birth") {
                kind = .birthRegistration
            } else if ctx.contains("died") || ctx.contains("death") {
                kind = .deathRegistration
            } else {
                kind = .unknown
            }
            return CitedIdentifier(
                source: .gro,
                kind: kind,
                identifiers: [
                    "volume": String(match.output.vol),
                    "page": String(match.output.page),
                ],
                raw: String(prose[match.range])
            )
        }
    }

    private static func parseFamilySearchCensus(prose: String) -> [CitedIdentifier] {
        // "FamilySearch 1901 census: Ernest Cauldwell ... (ARK p_10268848273)"
        // "FamilySearch 1911 census: Mrs Robert ... (ARK 1G2B-WFR)"
        let pattern = #/FamilySearch\s+(?<year>\d{4})\s+census\s*:?\s*[^()]*\(ARK\s+(?<ark>[A-Za-z0-9_\-]+)\)/#.ignoresCase()
        return prose.matches(of: pattern).map { match in
            CitedIdentifier(
                source: .familysearch,
                kind: .census,
                identifiers: [
                    "year": String(match.output.year),
                    "ark": String(match.output.ark),
                ],
                raw: String(prose[match.range])
            )
        }
    }

    private static func parseCWGC(prose: String) -> [CitedIdentifier] {
        // "CWGC: Corporal Robert Cauldwell, 1st Bn West Yorkshire Regt,
        //  died 14 Jul 1918, Lijssenthoek Military Cemetery XXVIII.G.3A"
        let pattern = #/CWGC[:\s]+(?<rest>[^\n]+)/#.ignoresCase()
        let plotPattern = #/([IVXLCDM]+\.\s*[A-Z]\.\s*\d+[A-Z]?)/#
        let datePattern = #/died\s+(?<day>\d{1,2})\s+(?<month>Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(?<year>\d{4})/#.ignoresCase()
        return prose.matches(of: pattern).map { match in
            let rest = String(match.output.rest)
            var ids: [String: String] = [:]
            if let p = rest.firstMatch(of: plotPattern) {
                ids["plot"] = String(p.output.1).replacingOccurrences(of: " ", with: "")
            }
            if let d = rest.firstMatch(of: datePattern) {
                ids["date_of_death"] = "\(d.output.day) \(d.output.month) \(d.output.year)"
            }
            return CitedIdentifier(
                source: .cwgc,
                kind: .warGrave,
                identifiers: ids,
                raw: String(prose[match.range])
            )
        }
    }

    // MARK: - Match rules

    private static func matchFreeBMD(_ a: CitedIdentifier, _ b: CitedIdentifier) -> CitationMatch {
        // Primary keys: district + quarter + year. Secondary: vol + page.
        guard let aD = a.identifiers["district"]?.lowercased(),
              let bD = b.identifiers["district"]?.lowercased(),
              aD == bD,
              a.identifiers["quarter"] == b.identifiers["quarter"],
              a.identifiers["year"] == b.identifiers["year"]
        else { return .noMatch }

        let aVol = a.identifiers["volume"]
        let bVol = b.identifiers["volume"]
        let aPage = a.identifiers["page"]
        let bPage = b.identifiers["page"]

        // If both sides have vol+page, they must match exactly.
        if aVol != nil && bVol != nil {
            return (aVol == bVol && aPage == bPage) ? .exact : .noMatch
        }
        // If neither has vol+page — exact match on primary keys alone.
        if aVol == nil && bVol == nil {
            return .exact
        }
        // One has, one doesn't — partial match (primary keys align, secondary
        // missing on one side). This is the Robert-birth case where the bio
        // note says "FreeBMD birth Sep 1885 Belper" without vol/page.
        return .partial
    }

    private static func matchFamilySearchCensus(_ a: CitedIdentifier, _ b: CitedIdentifier) -> CitationMatch {
        guard a.identifiers["year"] == b.identifiers["year"] else { return .noMatch }
        if let aArk = a.identifiers["ark"], let bArk = b.identifiers["ark"] {
            return aArk == bArk ? .exact : .noMatch
        }
        // Missing ARK on either side — can't disambiguate uniquely.
        return .partial
    }

    private static func matchCWGC(_ a: CitedIdentifier, _ b: CitedIdentifier) -> CitationMatch {
        // Plot is uniquely identifying within a cemetery; if both sides have
        // a plot, that's the key.
        if let aPlot = a.identifiers["plot"], let bPlot = b.identifiers["plot"] {
            return aPlot == bPlot ? .exact : .noMatch
        }
        // Fall back to date of death.
        if a.identifiers["date_of_death"] == b.identifiers["date_of_death"],
           a.identifiers["date_of_death"] != nil {
            return .partial
        }
        return .noMatch
    }

    private static func matchGeneric(_ a: CitedIdentifier, _ b: CitedIdentifier) -> CitationMatch {
        // No specialised rule — exact identifier-bag equality, or no match.
        return a.identifiers == b.identifiers ? .exact : .noMatch
    }

    // MARK: - Helpers

    private static func bmdKind(_ raw: String) -> CitationKind {
        switch raw.lowercased() {
        case "birth": return .birthRegistration
        case "death": return .deathRegistration
        case "marriage": return .marriageRegistration
        default: return .unknown
        }
    }

    private enum SourceFamily { case freebmdFamily, familysearchFamily, cwgcFamily, other }

    private static func sourceFamily(_ s: CitedSource) -> SourceFamily {
        switch s {
        case .freebmd, .gro: return .freebmdFamily
        case .familysearch: return .familysearchFamily
        case .cwgc: return .cwgcFamily
        default: return .other
        }
    }
}

// MARK: - Supporting types

nonisolated struct CitedIdentifier: Hashable, Sendable {
    let source: CitedSource
    let kind: CitationKind
    let identifiers: [String: String]
    let raw: String?
}

nonisolated enum CitedSource: String, Sendable {
    case freebmd
    case gro
    case familysearch
    case cwgc
    case freereg
    case freecen
    case probate
    case wirksworth
    case findagrave
    case unknown
}

nonisolated enum CitationKind: String, Sendable {
    case birthRegistration = "birth_registration"
    case deathRegistration = "death_registration"
    case marriageRegistration = "marriage_registration"
    case census
    case warGrave = "war_grave"
    case baptism
    case burial
    case probateCalendar = "probate_calendar"
    case soldiersEffects = "soldiers_effects"
    case unknown
}

nonisolated enum CitationMatch: String, Sendable {
    case exact
    case partial
    case noMatch
}
