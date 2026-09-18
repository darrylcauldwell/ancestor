import Foundation

// MARK: - Parish-absorption helpers (Parish absorption)
//
// Pure resolvers over the typed FreeREG payload used by the absorption layer
// to decide WHICH block of a multi-person register entry is the subject, and
// to lift the subject's spouse / parents. No app or DB dependency — unit
// testable in isolation.

public nonisolated extension FreeREGPerson {
    /// The leading integer of the free-text age cell ("26", "26 years" → 26;
    /// "full age", "infant", "3 mo", "" → nil). Volunteer transcription is
    /// stored as-transcribed (never blind-Int at the model layer), so parse
    /// leniently and refuse anything without a clean leading number.
    var ageInt: Int? {
        guard let age else { return nil }
        let digits = age.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), n >= 0, n <= 120 else { return nil }
        return n
    }
}

public nonisolated extension FreeREGMarriage {
    /// Which principal of the marriage a subject is.
    enum Role: Sendable, Equatable { case groom, bride }

    /// The role whose person-block best matches the subject's (given, surname).
    /// Surname is the strongest signal, then forename; a tie (or no name
    /// signal) falls back to gender (male → groom, female → bride), then to
    /// `.groom` as the row-principal default. Case-insensitive throughout.
    func role(forGiven given: String?, surname: String?, gender: Gender?) -> Role {
        func norm(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return t.isEmpty ? nil : t
        }
        let g = norm(given), s = norm(surname)
        func score(_ p: FreeREGPerson) -> Int {
            var n = 0
            if let s, let ps = norm(p.surname), ps == s { n += 2 }
            if let g, let pf = norm(p.forename), pf == g { n += 1 }
            return n
        }
        let groomScore = score(groom), brideScore = score(bride)
        if groomScore != brideScore { return groomScore > brideScore ? .groom : .bride }
        switch gender {
        case .male:   return .groom
        case .female: return .bride
        default:      return .groom
        }
    }

    /// The subject's own block.
    func principal(as role: Role) -> FreeREGPerson { role == .groom ? groom : bride }
    /// The other party.
    func spouse(of role: Role) -> FreeREGPerson { role == .groom ? bride : groom }
    /// The subject's father / mother block (nil when the entry names none).
    func father(of role: Role) -> FreeREGPerson? { role == .groom ? groomFather : brideFather }
    func mother(of role: Role) -> FreeREGPerson? { role == .groom ? groomMother : brideMother }
}

public nonisolated extension FreeREGPerson {
    /// A best-effort full name for a relative whose surname the register cell
    /// omitted (a father sharing the principal's surname): fills a missing
    /// surname from `inheritedSurname`. Returns nil when there is no forename
    /// AND no surname to show.
    func displayName(inheritingSurname inheritedSurname: String?) -> String? {
        let sur = (surname?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? inheritedSurname?.trimmingCharacters(in: .whitespaces)
        let parts = [forename?.trimmingCharacters(in: .whitespaces), sur]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// True when a surname is present (used to decide whether a synthesized
    /// spouse column is safe to state — a forename-only spouse can't be
    /// surname-matched to an edge and must not open a mismatch dispute).
    var hasSurname: Bool {
        !(surname ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public nonisolated extension ParishRecord {
    /// Parish absorption — a BMD-shaped `MarriageRecord` synthesized
    /// from a parish MARRIAGE entry, so the existing subject-side spouse-edge
    /// fill runs for a FreeREG marriage exactly as it does for a FreeBMD one:
    /// the marriage date/place lands on the linked spouse edge (nil columns
    /// only), married-surname enrichment fires, and a stated-spouse that
    /// matches no linked spouse opens the same DS-12 dispute.
    ///
    /// The `spouseName` column is stated ONLY when the other party carries a
    /// surname — `applyMarriageToSubjectSpouseEdge` matches spouses by surname,
    /// so a forename-only party would both fail to match and (being a stated
    /// column) manufacture a spurious mismatch dispute. nil for non-marriage
    /// parish events. Subject role is resolved from the row principal's name.
    var syntheticMarriageRecord: MarriageRecord? {
        guard case .marriage(let m)? = detail?.event else { return nil }
        let role = m.role(forGiven: common.givenName, surname: common.surname, gender: nil)
        let other = m.spouse(of: role)
        let spouseName = other.hasSurname ? other.displayName : nil
        let place = [parish, county]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let date = (m.marriageDate?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? eventDate
        return MarriageRecord(
            common: common,
            marriageYear: eventYear,
            marriageDate: date,
            marriagePlace: place.isEmpty ? nil : place,
            quarter: nil, district: nil, volume: nil, page: nil,
            spouseName: spouseName
        )
    }
}
