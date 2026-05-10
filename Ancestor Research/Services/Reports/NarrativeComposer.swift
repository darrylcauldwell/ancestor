import Foundation

/// Output of the narrative composer — pure data, ready for either PDF or
/// Markdown rendering. Paragraphs already carry their inline footnote
/// references (Unicode superscript for PDF/plain output; the Markdown
/// renderer rewrites these to `[^N]` syntax). Footnotes are formatted
/// citation strings in the order they're referenced.
nonisolated struct NarrativeDocument: Sendable {
    let title: String
    let paragraphs: [String]
    let footnotes: [String]
}

/// Pure narrative composition logic for the M10 narrative report
/// (DESIGN.md §7.9.4). Reads a profile's fields, parents, marriages,
/// children, and attached workbench notes and emits a `NarrativeDocument`
/// with structured prose plus citation footnotes.
///
/// Composition rules:
///   - Each section is skipped entirely when its source data is missing.
///   - Pronouns: `he` for `.male`, `she` for `.female`, `they` otherwise.
///   - Citations: the first non-empty `Citation` on the relevant field's
///     `FieldSource` array becomes a footnote. Marriages cite the spouse
///     relationship's marriageDate field if one exists in the relationship,
///     falling back to the spouse's profile sources for the same fact.
///   - Footnote numbering increments document-wide in order of appearance.
///   - Inline references use Unicode superscript digits; the markdown
///     renderer rewrites these to `[^N]` form.
nonisolated enum NarrativeComposer {

    static func compose(
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote],
        hypotheses: [Hypothesis] = [],
        questions: [OpenQuestion] = []
    ) -> NarrativeDocument {
        var builder = Builder(profile: profile, snapshot: snapshot)

        builder.appendBirth()
        builder.appendParents()
        builder.appendMarriages()
        builder.appendChildren()
        builder.appendDeath()
        builder.appendResearchContext(notes: notes)

        return NarrativeDocument(
            title: profile.displayName.isEmpty ? profile.id : profile.displayName,
            paragraphs: builder.paragraphs,
            footnotes: builder.footnotes
        )
    }

    // MARK: - Builder

    private struct Builder {
        let profile: Profile
        let snapshot: FamilyGraphSnapshot
        var paragraphs: [String] = []
        var footnotes: [String] = []

        var pronoun: String {
            switch profile.gender {
            case .male: return "He"
            case .female: return "She"
            case .other, .unknown, .none: return "They"
            }
        }

        var verbWas: String {
            // "He was" / "She was" / "They were"
            switch profile.gender {
            case .other, .unknown, .none: return "were"
            default: return "was"
            }
        }

        var verbDied: String {
            // "He died" / "She died" / "They died" — same verb regardless.
            return "died"
        }

        var fullName: String {
            profile.displayName.isEmpty ? profile.id : profile.displayName
        }

        // MARK: Birth

        mutating func appendBirth() {
            let date = profile.birthDate
            let location = profile.birthLocation
            guard date != nil || location != nil else { return }

            var sentence = "\(fullName) was born"
            if let datePhrase = formatDatePhrase(date) {
                sentence += " \(datePhrase)"
            }
            if let location, !location.isEmpty {
                sentence += " in \(location)"
            }
            // Citation: prefer birthDate's first citation, fall back to birthLocation.
            let ref = citationReference(for: .birthDate)
                ?? citationReference(for: .birthLocation)
            sentence += "\(ref ?? "")."
            paragraphs.append(sentence)
        }

        // MARK: Parents

        mutating func appendParents() {
            let parents = snapshot.parentsOf(profile.id)
            guard !parents.isEmpty else { return }

            // Order: father then mother where role is set, else as listed.
            let ordered = orderParents(parents)
            let names = ordered.map { $0.displayName.isEmpty ? $0.id : $0.displayName }

            var sentence: String
            switch ordered.count {
            case 1:
                sentence = "\(pronoun) \(verbWas) the child of \(names[0])"
            case 2:
                sentence = "\(pronoun) \(verbWas) the child of \(names[0]) and \(names[1])"
            default:
                let head = names.dropLast().joined(separator: ", ")
                sentence = "\(pronoun) \(verbWas) the child of \(head), and \(names.last ?? "")"
            }

            // Look for a spouse relationship between the parents — its
            // marriage clause becomes the second half of the parents sentence.
            if ordered.count >= 2,
               let marriage = marriageBetween(ordered[0].id, ordered[1].id) {
                var clause = ", who married"
                if let datePhrase = formatDatePhrase(marriage.marriageDate) {
                    clause += " \(datePhrase)"
                }
                if let loc = marriage.marriageLocation, !loc.isEmpty {
                    clause += " in \(loc)"
                }
                sentence += clause
            }
            sentence += "."
            paragraphs.append(sentence)
        }

        private func orderParents(_ parents: [Profile]) -> [Profile] {
            // Prefer father first, then mother, then any other.
            let rels = snapshot.relationships.filter {
                $0.type == .parent && $0.to == profile.id
            }
            let role: (String) -> ParentRole? = { id in
                rels.first { $0.from == id }?.role
            }
            return parents.sorted { a, b in
                let ra = role(a.id) ?? .unspecified
                let rb = role(b.id) ?? .unspecified
                func rank(_ r: ParentRole) -> Int {
                    switch r {
                    case .father: return 0
                    case .mother: return 1
                    case .unspecified: return 2
                    }
                }
                return rank(ra) < rank(rb)
            }
        }

        private func marriageBetween(_ a: String, _ b: String) -> Relationship? {
            snapshot.relationships.first {
                $0.type == .spouse
                    && (($0.from == a && $0.to == b) || ($0.from == b && $0.to == a))
            }
        }

        // MARK: Marriages

        mutating func appendMarriages() {
            let spouseRels = snapshot.relationships.filter {
                $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id)
            }
            // Stable order — by marriageDate.bestYear (nil last), then by spouse name.
            let ordered = spouseRels.sorted { lhs, rhs in
                let ly = lhs.marriageDate?.bestYear ?? Int.max
                let ry = rhs.marriageDate?.bestYear ?? Int.max
                if ly != ry { return ly < ry }
                let lname = otherSpouseName(lhs)
                let rname = otherSpouseName(rhs)
                return lname < rname
            }

            for rel in ordered {
                let otherID = rel.from == profile.id ? rel.to : rel.from
                guard let spouse = snapshot.profiles[otherID] else { continue }
                let spouseName = spouse.displayName.isEmpty ? spouse.id : spouse.displayName
                var sentence = "\(pronoun) married \(spouseName)"
                if let datePhrase = formatDatePhrase(rel.marriageDate) {
                    sentence += " \(datePhrase)"
                }
                if let loc = rel.marriageLocation, !loc.isEmpty {
                    sentence += " in \(loc)"
                }
                sentence += "."
                paragraphs.append(sentence)
            }
        }

        private func otherSpouseName(_ rel: Relationship) -> String {
            let otherID = rel.from == profile.id ? rel.to : rel.from
            return snapshot.profiles[otherID]?.displayName ?? otherID
        }

        // MARK: Children

        mutating func appendChildren() {
            let children = snapshot.childrenOf(profile.id)
            guard !children.isEmpty else { return }

            // Order children by birth year (nil last).
            let ordered = children.sorted { a, b in
                let ya = a.birthDate?.bestYear ?? Int.max
                let yb = b.birthDate?.bestYear ?? Int.max
                if ya != yb { return ya < yb }
                return (a.displayName) < (b.displayName)
            }

            // First spouse (if any) for "Thomas and Mary had..." phrasing.
            let firstSpouse = snapshot.spousesOf(profile.id).first
            let leadName = profile.firstName ?? profile.displayName
            let lead: String
            if let spouse = firstSpouse {
                let spouseLead = spouse.firstName ?? spouse.displayName
                lead = "\(leadName) and \(spouseLead)"
            } else {
                lead = leadName.isEmpty ? fullName : leadName
            }

            if ordered.count == 1 {
                let only = ordered[0]
                let descriptor: String
                switch only.gender {
                case .male: descriptor = "a son"
                case .female: descriptor = "a daughter"
                default: descriptor = "a child"
                }
                let only_name = only.displayName.isEmpty ? only.id : only.displayName
                let yearPart = only.birthDate?.bestYear.map { " (b. \($0))" } ?? Optional("")
                paragraphs.append("\(lead) had \(descriptor) \(only_name)\(yearPart ?? "").")
            } else {
                let countWord = numberWord(ordered.count)
                let listed = ordered.map { child -> String in
                    let cname = child.displayName.isEmpty ? child.id : child.displayName
                    if let y = child.birthDate?.bestYear {
                        return "\(cname) (b. \(y))"
                    }
                    return cname
                }
                let listText: String
                if listed.count == 2 {
                    listText = "\(listed[0]) and \(listed[1])"
                } else {
                    let head = listed.dropLast().joined(separator: ", ")
                    listText = "\(head), and \(listed.last ?? "")"
                }
                paragraphs.append("\(lead) had \(countWord) children: \(listText).")
            }
        }

        private func numberWord(_ n: Int) -> String {
            switch n {
            case 2: return "two"
            case 3: return "three"
            case 4: return "four"
            case 5: return "five"
            case 6: return "six"
            case 7: return "seven"
            case 8: return "eight"
            case 9: return "nine"
            case 10: return "ten"
            default: return "\(n)"
            }
        }

        // MARK: Death

        mutating func appendDeath() {
            let date = profile.deathDate
            let location = profile.deathLocation
            guard date != nil || location != nil else { return }

            var sentence = "\(pronoun) \(verbDied)"
            if let datePhrase = formatDatePhrase(date) {
                sentence += " \(datePhrase)"
            }
            if let location, !location.isEmpty {
                sentence += " in \(location)"
            }
            let ref = citationReference(for: .deathDate)
                ?? citationReference(for: .deathLocation)
            sentence += "\(ref ?? "")."
            paragraphs.append(sentence)
        }

        // MARK: Research context

        mutating func appendResearchContext(notes: [WorkbenchNote]) {
            let attached = notes.filter {
                if case .profile(let id) = $0.attachedTo { return id == profile.id }
                return false
            }
            guard !attached.isEmpty else { return }

            let snippets = attached.map { note -> String in
                let trimmed = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let body: String
                if trimmed.count > 80 {
                    let idx = trimmed.index(trimmed.startIndex, offsetBy: 80)
                    body = String(trimmed[..<idx]) + "..."
                } else {
                    body = trimmed
                }
                return "\(note.tag.displayName) → \(body)"
            }
            paragraphs.append("Research notes: \(snippets.joined(separator: ", ")).")
        }

        // MARK: Date phrasing

        private func formatDatePhrase(_ date: GenealogicalDate?) -> String? {
            guard let date else { return nil }
            switch date.qualifier {
            case .yearOnly:
                if let y = date.earliest { return "in \(y)" }
                return nil
            case .exact:
                // "1 JAN 1887" → display the original lower-cased month.
                let trimmed = date.original.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return "on \(humanizeExactDate(trimmed))" }
                return nil
            case .about, .estimated, .calculated:
                if let y = date.bestYear { return "around \(y)" }
                return nil
            case .before:
                if let y = date.latest { return "before \(y)" }
                return nil
            case .after:
                if let y = date.earliest { return "after \(y)" }
                return nil
            case .between:
                if let a = date.earliest, let b = date.latest {
                    return "between \(a) and \(b)"
                }
                return nil
            }
        }

        private func humanizeExactDate(_ raw: String) -> String {
            // Convert "1 JAN 1887" → "1 January 1887", "MAR 1887" → "March 1887".
            let monthMap: [String: String] = [
                "JAN": "January", "FEB": "February", "MAR": "March",
                "APR": "April", "MAY": "May", "JUN": "June",
                "JUL": "July", "AUG": "August", "SEP": "September",
                "OCT": "October", "NOV": "November", "DEC": "December"
            ]
            let parts = raw.split(separator: " ").map(String.init)
            let mapped = parts.map { p -> String in
                let upper = p.uppercased()
                return monthMap[upper] ?? p
            }
            return mapped.joined(separator: " ")
        }

        // MARK: Citations / footnotes

        /// Returns the inline footnote reference (e.g. " ¹") for the first
        /// non-empty citation found on `field`'s sources, or nil if none.
        /// Also appends the formatted citation string to `footnotes`.
        mutating func citationReference(for field: ProfileField) -> String? {
            guard let sources = profile.sources[field] else { return nil }
            for source in sources {
                if let citation = source.citation, !citation.isEmpty {
                    footnotes.append(citation.formatted)
                    return Self.superscript(footnotes.count)
                }
            }
            return nil
        }

        static func superscript(_ n: Int) -> String {
            let map: [Character: Character] = [
                "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}",
                "4": "\u{2074}", "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}",
                "8": "\u{2078}", "9": "\u{2079}"
            ]
            let digits = String(n)
            return String(digits.map { map[$0] ?? $0 })
        }
    }
}

/// Mapping helper for converting a composed paragraph that uses Unicode
/// superscript digits into Markdown `[^N]` references. Lives outside
/// `NarrativeComposer` so the renderer code can call it without touching
/// the composer's private state.
nonisolated enum NarrativeFootnoteFormatter {

    /// Converts every run of Unicode superscript digits in `text` to
    /// `[^N]` form. "Belper¹." → "Belper[^1]."
    static func toMarkdown(_ text: String) -> String {
        let supers: [Character: Character] = [
            "\u{2070}": "0", "\u{00B9}": "1", "\u{00B2}": "2", "\u{00B3}": "3",
            "\u{2074}": "4", "\u{2075}": "5", "\u{2076}": "6", "\u{2077}": "7",
            "\u{2078}": "8", "\u{2079}": "9"
        ]
        var result = ""
        result.reserveCapacity(text.count)
        var buffer = ""
        for ch in text {
            if let mapped = supers[ch] {
                buffer.append(mapped)
            } else {
                if !buffer.isEmpty {
                    result += "[^\(buffer)]"
                    buffer = ""
                }
                result.append(ch)
            }
        }
        if !buffer.isEmpty {
            result += "[^\(buffer)]"
        }
        return result
    }
}
