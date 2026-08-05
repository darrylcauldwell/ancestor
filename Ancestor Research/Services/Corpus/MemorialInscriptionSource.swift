import Foundation

/// First working version of a CHAPMAN-TEMPLATED memorial-inscription source
/// (owner idea 2026-08-05). Rather than crawling a whole transcription site, we
/// template the page URL on the subject's county Chapman code + parish and fetch
/// ONLY that one local page on demand — ToS-clean ("an individual pursuing their
/// own private family history research"), gentle on a volunteer server, and
/// reusing the Chapman code the pipeline already derives for every subject
/// (`ResearchSubject.homeChapmanCode`, with the project Home-county fallback).
///
/// This is the pure engine: URL construction + MI-prose parsing, no networking.
/// Wiring it as a live `RecordSource` — a single on-demand fetch behind the
/// firewall, so the extracted FACTS enter as pending evidence while the verbatim
/// transcription is never republished (the Publisher rule from the site's
/// terms) — is the next step. The pattern generalises to any Chapman-addressable
/// site (e.g. GENUKI `.../big/eng/{CHAPMAN}/{Parish}`).
nonisolated enum MemorialInscriptionSource {

    /// One person parsed from a memorial inscription. An MI is effectively a
    /// burial record: it yields a death year + age (hence a birth year) and
    /// family relationships — the discriminating evidence a namesake-heavy BMD
    /// index can't give (the William Holmes problem).
    struct Person: Equatable, Sendable {
        var surname: String
        var givenName: String
        var relationship: String?
        var deathYear: Int?
        var ageAtDeath: Int?
        /// Birth year implied by death year − age at death.
        var birthYear: Int? {
            guard let deathYear, let ageAtDeath else { return nil }
            return deathYear - ageAtDeath
        }
    }

    /// Build the on-demand page URL for ONE parish, templated on the subject's
    /// county Chapman code + parish. NEVER the whole site — one local page per
    /// lookup. Returns nil for an implausible Chapman code or an empty parish.
    ///
    /// (DBY, "Youlgreave") -> https://places.wishful-thinking.org.uk/DBY/Youlgreave/MIs.html
    static func memorialPageURL(
        chapmanCode: String,
        parish: String,
        host: String = "places.wishful-thinking.org.uk"
    ) -> URL? {
        let code = chapmanCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3, code.allSatisfy({ $0.isLetter }) else { return nil }
        // The site's parish path drops interior spaces ("Youlgreave"; "South
        // Darley" -> "SouthDarley"). A few parishes are combined onto one page
        // (Foston+Scropton) — a per-parish slug map is a v2 refinement.
        let slug = parish
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined()
        guard !slug.isEmpty else { return nil }
        return URL(string: "https://\(host)/\(code)/\(slug)/MIs.html")
    }

    /// Parse memorial-inscription collection text into people. One line per
    /// memorial; people within a memorial are ';'-separated and share the first
    /// stated SURNAME (in caps) — so "Ellen, w, 25 Oct 1857, 73" following "John
    /// HOLMES…" is a HOLMES. v1 extracts surname, given name, death year and age
    /// (→ birth year); place and finer relationship parsing are best-effort.
    /// Only dated people (a death year or an age) are returned — an undated
    /// "Also two children who died in infancy" line carries no evidence.
    static func parse(_ text: String) -> [Person] {
        var people: [Person] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = stripLeadingReference(
                String(rawLine).trimmingCharacters(in: .whitespaces))
            guard !line.isEmpty else { continue }
            var inheritedSurname: String?
            for rawSegment in line.split(separator: ";") {
                let segment = rawSegment.trimmingCharacters(in: .whitespaces)
                guard !segment.isEmpty,
                      let person = parseSegment(segment, inheritedSurname: inheritedSurname)
                else { continue }
                inheritedSurname = person.surname
                if person.deathYear != nil || person.ageAtDeath != nil {
                    people.append(person)
                }
            }
        }
        return people
    }

    // MARK: - Internals

    /// Drop a leading transcription reference such as "A67:", "D121" or "B1 -".
    static func stripLeadingReference(_ line: String) -> String {
        var idx = line.startIndex
        guard idx < line.endIndex, line[idx].isLetter else { return line }
        idx = line.index(after: idx)
        var sawDigit = false
        while idx < line.endIndex, line[idx].isNumber { sawDigit = true; idx = line.index(after: idx) }
        guard sawDigit else { return line }
        while idx < line.endIndex, ": .-".contains(line[idx]) { idx = line.index(after: idx) }
        return String(line[idx...]).trimmingCharacters(in: .whitespaces)
    }

    static func parseSegment(_ segment: String, inheritedSurname: String?) -> Person? {
        let tokens = segment
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        // Surname: an all-caps alphabetic token (>=2 letters), else inherited
        // from the memorial's first-named person.
        let capsSurname = tokens.first {
            $0.count >= 2 && $0 == $0.uppercased() && $0.allSatisfy({ $0.isLetter })
        }
        guard let surnameRaw = capsSurname ?? inheritedSurname else { return nil }

        // Death year: a 4-digit token in a plausible headstone range.
        let deathYear = tokens.compactMap { Int($0) }.first { (1500...2025).contains($0) }
        // Age: a 0–129 value (or "8yrs") that isn't the year — headstones put it
        // last, so take the last such token.
        let ageAtDeath = tokens.reversed().compactMap { ageValue($0) }.first

        // Given name: the leading Capitalised (not ALL-CAPS) word(s) before the
        // surname, a number, or a relationship marker.
        let given = tokens.prefix { token in
            token != capsSurname
                && Int(token) == nil
                && !isRelationshipMarker(token)
                && (token.first?.isUppercase ?? false)
                && token != token.uppercased()
        }.joined(separator: " ")

        let relationship = tokens.first { isRelationshipMarker($0) }

        return Person(
            surname: titleCased(surnameRaw),
            givenName: given,
            relationship: relationship,
            deathYear: deathYear,
            ageAtDeath: ageAtDeath)
    }

    static func ageValue(_ token: String) -> Int? {
        let digits = String(token.prefix { $0.isNumber })
        guard let n = Int(digits), (0...129).contains(n) else { return nil }
        return n
    }

    static func isRelationshipMarker(_ token: String) -> Bool {
        ["w", "h", "d", "s", "w/o", "h/o", "s/o", "d/o",
         "wife", "husband", "son", "daughter", "widow", "widower",
         "grand-daughter", "granddaughter", "grand-son", "grandson",
         "infant", "relict", "dau"].contains(token.lowercased())
    }

    static func titleCased(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst().lowercased()
    }
}
