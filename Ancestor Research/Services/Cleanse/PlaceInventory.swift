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
        let id: String                       // "profileID|targetKey"
        let profileID: String
        let profileName: String
        let target: LocationNormalizer.Target
        /// The event's year, used for era elimination — a birth location takes
        /// the birth year, a life event its own date.
        let year: Int?
        /// Already bound to a PlaceAuthority id; such rows need no decision.
        let isBound: Bool
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

        var profileCount: Int { Set(occurrences.map(\.profileID)).count }
        var needsDecision: Bool { confidence < .high && occurrences.contains { !$0.isBound } }
    }

    // MARK: - Build

    static func build(profiles: [Profile], lifeEvents: [LifeEvent] = []) -> [Row] {
        var byText: [String: [Occurrence]] = [:]
        let live = profiles.filter { !$0.isDeleted }
        let nameByID = Dictionary(live.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let liveIDs = Set(live.map(\.id))

        func add(_ text: String?, code: String?, profileID: String, profileName: String,
                 target: LocationNormalizer.Target, key: String, year: Int?) {
            guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return }
            byText[raw, default: []].append(Occurrence(
                id: "\(profileID)|\(key)", profileID: profileID, profileName: profileName,
                target: target, year: year,
                isBound: !((code ?? "").trimmingCharacters(in: .whitespaces).isEmpty)))
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

        return byText.map { text, occurrences in
            score(text: text, occurrences: occurrences)
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

    // MARK: - Scoring

    static func score(text: String, occurrences: [Occurrence]) -> Row {
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
                       confidence: .unresolved, reasons: reasons)
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

        // Floor at `.low`, never `.unresolved`: enough deductions can drive a row
        // that DID match to zero, and "Unresolved" then claims nothing was found
        // while the row lists three candidate districts. "City Hospital, Derby"
        // read that way. `.unresolved` means the catalogue knows nothing about
        // this text, and it must keep meaning only that.
        let confidence = Confidence(rawValue: max(1, min(3, score))) ?? .low
        return Row(id: text, text: text, occurrences: occurrences,
                   candidates: result.districts, eliminated: result.eliminated,
                   placeNames: distinctPlaces.sorted(), matchedSegment: result.matchedSegment,
                   confidence: confidence, reasons: reasons)
    }
}
