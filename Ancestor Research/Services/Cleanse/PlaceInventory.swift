import Foundation
import AncestorKit

/// LOCATION_MODEL_SPEC Part III, Slice A — every distinct location string the
/// tree uses, each scored for how confidently it resolves to a registration
/// district, so a human can settle the ones the data cannot.
///
/// **One uniform list, not two buckets.** An earlier draft split rows into
/// "ambiguous → ask the user" and "resolved → stay quiet". Owner direction
/// 2026-08-17 overrode that, and rightly: it let the app decide which cases the
/// user is allowed to see, which is the same failure as the app silently
/// choosing Bakewell for Ruth Brailsford's 1824 Middleton. Resolution
/// confidence is a continuum; the split was arbitrary.
///
/// So every string appears, scored, with its reasons. Sorted ascending the work
/// floats to the top and a high-confidence row is a glance and a tick.
///
/// Pure: reads profiles, life events and the bundled catalogues. Writes nothing.
nonisolated enum PlaceInventory {

    /// How far a resolution can be trusted. Ordered so `<` means "needs more
    /// attention" and the list can sort on it directly.
    enum Confidence: Int, Sendable, Comparable, CaseIterable {
        /// Nothing matched — a hamlet the catalogue lacks, or not a place.
        case unresolved = 0
        /// Resolved, but something material is missing or contested — rival
        /// districts, no county stated, no year to eliminate by.
        case low = 1
        /// Resolved with one soft caveat.
        case medium = 2
        /// Single candidate, county stated, matched on the parish's own name.
        case high = 3

        static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .unresolved: "Unresolved"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }
    }

    /// One field that uses a location string. The year matters: it is what lets
    /// era elimination rule out a district that did not exist yet.
    struct Occurrence: Sendable, Equatable, Identifiable {
        let id: String                       // "profileID|fieldKey"
        let profileID: String
        let profileName: String
        let target: LocationNormalizer.Target
        /// Which field this is, as the unresolvable-flag table keys it
        /// ("birthLocation", "event:<uuid>").
        let fieldKey: String
        /// The event's year, used for era elimination — a birth location takes
        /// the birth year, a life event its own date.
        let year: Int?
        /// Already bound to a PlaceAuthority id; such rows need no decision.
        let isBound: Bool
        /// The user has said this field's text names no place.
        let isNotAPlace: Bool

        /// Short label for the field ("Birth", "Death", "Residence").
        var fieldLabel: String {
            switch target {
            case .profileField(let f): f == .birthLocation ? "Birth" : "Death"
            case .lifeEvent(_, let type): type.capitalized
            }
        }
    }

    /// One distinct location string, everything known about it.
    struct Row: Sendable, Identifiable {
        let id: String                       // the location text itself
        let text: String
        let occurrences: [Occurrence]
        /// Districts still standing after county and era filtering.
        let candidates: [PlaceAuthority]
        /// Districts the event year ruled out, with the window that ruled them
        /// out. Shown, not dropped: an answer arrived at by elimination is only
        /// checkable if the eliminations are visible.
        let eliminated: [(district: PlaceAuthority, reason: String)]
        /// The distinct settlements the matched segment names. More than one
        /// means the *place* is ambiguous even when the districts collapse to one.
        let placeNames: [String]
        /// The comma segment that produced the candidates — "Alport,
        /// Youlgreave, Derbyshire" matches on Youlgreave, and saying so is how
        /// the user knows the hamlet itself is still unknown.
        let matchedSegment: String?
        let confidence: Confidence
        /// Why it scored what it scored. Shown verbatim: a bare number becomes
        /// something you learn to ignore, and an unexplained low score is not
        /// actionable.
        let reasons: [String]
        /// Candidate districts this family already has records in, with how many.
        /// Ranks `candidates`; deliberately does NOT move `confidence` — see
        /// `corroboration(…)`.
        let corroboration: [String: Int]

        var profileCount: Int { Set(occurrences.map(\.profileID)).count }

        /// Every use of this text has been dismissed as naming no place.
        var isNotAPlace: Bool { !occurrences.isEmpty && occurrences.allSatisfy(\.isNotAPlace) }

        /// Still owed a human decision. A row leaves the queue two ways: it
        /// resolves confidently, or a person settles it — by binding a district
        /// or by saying it names no place. Nothing leaves silently.
        var needsDecision: Bool {
            !isNotAPlace && confidence < .high && occurrences.contains { !$0.isBound }
        }
    }

    // MARK: - Build

    /// - Parameters:
    ///   - dismissed: occurrence ids (`"profileID|fieldKey"`) the user has marked as
    ///     naming no place — `ProjectDatabase.loadCleanseUnresolvableFlags`.
    ///   - relationships: used only to rank candidates by family corroboration.
    ///     Omitting them costs ranking, never correctness.
    static func build(
        profiles: [Profile], relationships: [Relationship] = [],
        lifeEvents: [LifeEvent] = [], dismissed: Set<String> = []
    ) -> [Row] {
        var byText: [String: [Occurrence]] = [:]
        let live = profiles.filter { !$0.isDeleted }
        let nameByID = Dictionary(live.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let liveIDs = Set(live.map(\.id))

        func add(_ text: String?, code: String?, profileID: String, profileName: String,
                 target: LocationNormalizer.Target, key: String, year: Int?) {
            guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return }
            let id = "\(profileID)|\(key)"
            byText[raw, default: []].append(Occurrence(
                id: id, profileID: profileID, profileName: profileName,
                target: target, fieldKey: key, year: year,
                isBound: !((code ?? "").trimmingCharacters(in: .whitespaces).isEmpty),
                isNotAPlace: dismissed.contains(id)))
        }

        for p in live {
            add(p.birthLocation, code: p.birthLocationCode, profileID: p.id, profileName: p.displayName,
                target: .profileField(.birthLocation), key: ProfileField.birthLocation.rawValue,
                year: p.birthDate?.bestYear)
            add(p.deathLocation, code: p.deathLocationCode, profileID: p.id, profileName: p.displayName,
                target: .profileField(.deathLocation), key: ProfileField.deathLocation.rawValue,
                year: p.deathDate?.bestYear)
        }
        for e in lifeEvents where liveIDs.contains(e.profileID) {
            add(e.location, code: e.locationCode, profileID: e.profileID,
                profileName: nameByID[e.profileID] ?? "",
                target: .lifeEvent(id: e.id, type: e.type.rawValue),
                key: "event:\(e.id.uuidString)", year: e.sortYear)
        }

        let districtsByProfile = knownDistricts(of: live)
        let kin = kinIndex(relationships, among: liveIDs)

        return byText.map { text, occurrences in
            score(text: text, occurrences: occurrences,
                  corroboration: corroboration(for: occurrences, kin: kin, districts: districtsByProfile))
        }
        // Ascending confidence, then by how much of the tree it affects, so the
        // top of the list is both the least certain and the most consequential.
        .sorted {
            $0.confidence != $1.confidence
                ? $0.confidence < $1.confidence
                : ($0.occurrences.count != $1.occurrences.count
                   ? $0.occurrences.count > $1.occurrences.count
                   : $0.text < $1.text)
        }
    }

    // MARK: - Family corroboration

    /// Districts each profile is already established in, from the structured
    /// fields only — the typed birth registration district (Slice C) and any
    /// birth/death location code that rolls up to a district. Free text is
    /// deliberately excluded: corroborating an unresolved string with another
    /// unresolved string is circular.
    static func knownDistricts(of profiles: [Profile]) -> [String: Set<String>] {
        let places = PlaceAuthorityRegistry.shared.places
        var byProfile: [String: Set<String>] = [:]
        for p in profiles {
            var found: Set<String> = []
            if let rd = p.birthRegistrationDistrict, !rd.isEmpty { found.insert(rd) }
            for code in [p.birthLocationCode, p.deathLocationCode].compactMap({ $0 }) where !code.isEmpty {
                if let district = places.registrationDistrict(of: code) {
                    found.insert(district.id)
                } else if code.hasSuffix("-RD") {
                    // Already a district id — the Places tab binds these directly.
                    found.insert(code)
                }
            }
            if !found.isEmpty { byProfile[p.id] = found }
        }
        return byProfile
    }

    /// Immediate family for each profile: parents, children, spouses, siblings.
    /// Deliberately one hop plus siblings, not a transitive walk — at three hops
    /// a Derbyshire tree is one connected blob and every district "corroborates"
    /// everything.
    static func kinIndex(_ relationships: [Relationship], among live: Set<String>) -> [String: Set<String>] {
        var kin: [String: Set<String>] = [:]
        var childrenOf: [String: Set<String>] = [:]

        for r in relationships where live.contains(r.from) && live.contains(r.to) {
            kin[r.from, default: []].insert(r.to)
            kin[r.to, default: []].insert(r.from)
            if r.type == .parent { childrenOf[r.from, default: []].insert(r.to) }
        }
        // Siblings: everyone sharing a parent.
        for (_, siblings) in childrenOf where siblings.count > 1 {
            for child in siblings {
                kin[child, default: []].formUnion(siblings.subtracting([child]))
            }
        }
        return kin
    }

    /// How many of this row's people have family already recorded in each
    /// candidate district.
    ///
    /// **This ranks; it must never raise confidence.** A family that stayed put
    /// corroborates *every* ambiguous place in the same district, so a boost would
    /// be near-uniform — it would discriminate almost nothing while manufacturing
    /// high scores. Worse, it compounds: one wrong binding makes the next
    /// ambiguous place score higher toward the same wrong district, and the round
    /// after that higher still. Confidence answers "how ambiguous is this text",
    /// which is not changed by where the family lived. Putting the corroborated
    /// candidate first, with the count stated, makes the decision fast without
    /// ever making it for the user.
    static func corroboration(
        for occurrences: [Occurrence], kin: [String: Set<String>], districts: [String: Set<String>]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for profileID in Set(occurrences.map(\.profileID)) {
            // The person's own established districts count too — a known death
            // district is evidence about how to read their birthplace.
            var circle = kin[profileID] ?? []
            circle.insert(profileID)
            for relative in circle {
                for district in districts[relative] ?? [] {
                    counts[district, default: 0] += 1
                }
            }
        }
        return counts
    }

    // MARK: - Decisions

    /// Bind specific uses of `row.text` to the district the user picked.
    ///
    /// **Per field, not per string.** Binding every occurrence at once assumes
    /// every use of "Middleton, Derbyshire" in the tree means the same Middleton
    /// — true within one family, false in general, and silently wrong in exactly
    /// the case this feature exists to catch. The caller names the fields;
    /// `bindAll` is the convenience, never the default.
    ///
    /// Deliberately not `LocationNormalizer.apply`, which refuses anything the
    /// resolver did not decide by itself. That guard is right for the cleanse
    /// wizard — it stops a *declined* proposal being written as if confident —
    /// but here the decision came from a person looking at the rival candidates
    /// and the eliminations, which is the strongest provenance the app has.
    ///
    /// Already-bound fields are left alone (check-before-overwrite): a code
    /// someone set earlier, by any route, is not clobbered by a later decision.
    ///
    /// Returns the number of fields written.
    @discardableResult
    static func bind(
        _ row: Row, occurrenceIDs: Set<String>, to code: String, in db: ProjectDatabase
    ) throws -> Int {
        var written = 0
        for occurrence in row.occurrences
        where occurrenceIDs.contains(occurrence.id) && !occurrence.isBound {
            switch occurrence.target {
            case .profileField(let field):
                try db.setProfileLocationCode(profileID: occurrence.profileID, field: field, code: code)
            case .lifeEvent(let id, _):
                try db.setLifeEventLocationCode(eventID: id, code: code)
            }
            // Binding answers the question the flag was raised about.
            try db.clearCleanseUnresolvable(profileID: occurrence.profileID, field: occurrence.fieldKey)
            written += 1
        }
        return written
    }

    /// The "apply to all N occurrences" convenience — an explicit choice the user
    /// makes after seeing who is affected, not the default path.
    @discardableResult
    static func bindAll(_ row: Row, to code: String, in db: ProjectDatabase) throws -> Int {
        try bind(row, occurrenceIDs: Set(row.occurrences.map(\.id)), to: code, in: db)
    }

    /// Record that this text names no place — a house ("Darley Hall"), a
    /// hospital, a typo, a fragment. Flagged rather than coded so it stops
    /// reappearing in the queue while staying visible and reversible; the tree
    /// text is never edited from here, because correcting it is a different
    /// decision from saying it cannot be resolved.
    @discardableResult
    static func markNotAPlace(_ row: Row, in db: ProjectDatabase) throws -> Int {
        for occurrence in row.occurrences {
            try db.markCleanseUnresolvable(profileID: occurrence.profileID, field: occurrence.fieldKey)
        }
        return row.occurrences.count
    }

    /// Undo `markNotAPlace`.
    static func clearNotAPlace(_ row: Row, in db: ProjectDatabase) throws {
        for occurrence in row.occurrences {
            try db.clearCleanseUnresolvable(profileID: occurrence.profileID, field: occurrence.fieldKey)
        }
    }

    // MARK: - Scoring

    static func score(
        text: String, occurrences: [Occurrence], corroboration: [String: Int] = [:]
    ) -> Row {
        // Era elimination needs a year. Use the earliest occurrence's year: the
        // narrowest constraint any use of this string carries.
        let year = occurrences.compactMap(\.year).min()
        let stated = RegistrationDistrictResolver.statedChapman(in: text)
        let result = RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: text, chapman: nil, year: year)

        var reasons: [String] = []
        guard let result, !result.districts.isEmpty else {
            reasons.append("No registration district matches any part of this text.")
            if stated == nil { reasons.append("No county stated, so nothing narrows the search.") }
            return Row(id: text, text: text, occurrences: occurrences, candidates: [],
                       eliminated: [], placeNames: [], matchedSegment: nil,
                       confidence: .unresolved, reasons: reasons, corroboration: [:])
        }

        let firstSegment = RegistrationDistrictResolver.segments(of: text).first
        let matchedFirst = result.matchedSegment.caseInsensitiveCompare(firstSegment ?? "") == .orderedSame

        var score = 3   // start at high, deduct for what is missing or contested

        // AMBIGUITY IS COUNTED IN PLACES, NOT DISTRICTS. Counting districts gets
        // this backwards in both directions: "Warslow" is one settlement filed
        // under two districts (Leek, and Staffordshire Moorlands after the 1974
        // reorganisation) and would look contested; "Middleton" in Derbyshire is
        // two settlements whose districts collapse to one once a validity window
        // eliminates Bakewell, and would look certain. It was the second of those
        // that put Ruth Brailsford's 1824 birth in a district founded in 1839.
        let distinctPlaces = Set(result.parishes.map { $0.name })
        if distinctPlaces.count > 1 {
            score -= 2
            reasons.append("\(distinctPlaces.count) different places share this name: "
                           + distinctPlaces.sorted().joined(separator: ", ") + ".")
        }

        if result.districts.count > 1 {
            score -= 1
            let names = result.districts.map(\.name).sorted().joined(separator: ", ")
            reasons.append("\(result.districts.count) possible districts: \(names).")
        } else {
            reasons.append("Registration district: \(result.districts[0].name).")
        }

        if let stated {
            reasons.append("County stated in the text (\(stated)).")
        } else {
            score -= 1
            reasons.append("No county stated — the match could be in another county.")
        }

        if !matchedFirst {
            score -= 1
            reasons.append("Matched on \"\(result.matchedSegment)\", not \"\(firstSegment ?? text)\" — "
                           + "the more precise place is not in the catalogue.")
        }

        if let year {
            if !result.eliminated.isEmpty {
                let ruledOut = result.eliminated
                    .map { "\($0.district.name) (\($0.reason))" }
                    .sorted().joined(separator: ", ")
                reasons.append("Ruled out for \(year): \(ruledOut).")
            }
            // Civil registration began in July 1837. Before it, a district is a
            // geographic approximation rather than where the event was actually
            // registered — worth saying, but not itself a reason to doubt WHICH
            // place the text means, so it does not deduct.
            if year < 1837 {
                reasons.append("\(year) predates civil registration (1837) — "
                               + "the district locates the place, it is not where the event was registered.")
            }
        } else if result.districts.count > 1 {
            reasons.append("No event year available, so districts outside their window could not be ruled out.")
        }

        // Family corroboration RANKS, and only ranks. See `corroboration(…)` for
        // why a boost would be both near-useless and self-reinforcing.
        let relevant = corroboration.filter { key, _ in result.districts.contains { $0.id == key } }
        if !relevant.isEmpty {
            let described = relevant
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .compactMap { key, count -> String? in
                    guard let district = result.districts.first(where: { $0.id == key }) else { return nil }
                    return "\(district.name) (\(count) record\(count == 1 ? "" : "s"))"
                }
                .joined(separator: ", ")
            reasons.append("This family already has records in: \(described). "
                           + "That orders the list; it does not decide.")
        }
        let ranked = result.districts.sorted {
            let a = relevant[$0.id] ?? 0, b = relevant[$1.id] ?? 0
            return a != b ? a > b : $0.id < $1.id
        }

        // Floor at `.low`, never `.unresolved`: enough deductions can drive a row
        // that DID match to zero, and "Unresolved" then claims nothing was found
        // while the row lists three candidate districts. "City Hospital, Derby"
        // read that way. `.unresolved` means the catalogue knows nothing about
        // this text, and it must keep meaning only that.
        let confidence = Confidence(rawValue: max(1, min(3, score))) ?? .low
        return Row(id: text, text: text, occurrences: occurrences,
                   candidates: ranked, eliminated: result.eliminated,
                   placeNames: distinctPlaces.sorted(), matchedSegment: result.matchedSegment,
                   confidence: confidence, reasons: reasons, corroboration: relevant)
    }
}
