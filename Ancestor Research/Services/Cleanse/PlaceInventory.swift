import Foundation
import AncestorKit

/// Location model Part III, Slice A — every distinct location string the
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
        /// Already settled — either a pre-existing structured code on the field,
        /// or a live decision in the Places tab.
        let isBound: Bool
        /// The decision governing this use, when one exists. Carries the reason
        /// the user gave, so a later session can check it instead of re-deciding.
        let decision: PlaceDecision?
        /// The user has said this field's text names no place.
        let isNotAPlace: Bool
        /// The parish and district the RECORD states, when this use came from a
        /// census. "Shining Row" is an address; the schedule it sits on names
        /// Turnditch parish, Belper district. That is evidence with a citation
        /// behind it, not a guess — and the inventory used to ignore it and ask
        /// the user instead.
        let recordParish: String?
        let recordDistrict: String?

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
        /// Rows sharing this key are spellings of the same place — "Wirksworth",
        /// "Wirksworth, Derbyshire", "Wirksworth, Derbyshire (DBY)" and
        /// "Wirksworth, Derbyshire, England" are four rows and one village.
        let variantKey: String
        /// Candidate districts this family already has records in, with how many.
        /// Ranks `candidates`; deliberately does NOT move `confidence` — see
        /// `corroboration(…)`.
        let corroboration: [String: Int]
        /// The same counts for EVERY district, not just the ones on offer. The
        /// search results need it: that is the screen with least to go on, and
        /// where the family already has records is the only real signal there.
        let allCorroboration: [String: Int]
        /// The whole chain when the row resolves — "Shining Row, Turnditch,
        /// Belper, Derbyshire". The headline answer: a bare district name is the
        /// least informative rung, and burying the parish in a reason line meant
        /// the pane said "Belper" while the useful word sat four sections down.
        let resolvedDisplay: String?
        /// Parish/district pairs the RECORDS state for this text, with the years
        /// they were stated in. One pair is an answer; several disagreeing pairs
        /// is a finding of its own — the same address string in two parishes.
        let recordPlaces: [(parish: String, district: String, years: [Int])]
        /// District boundaries that fall INSIDE this row's own span of years —
        /// "Bakewell opened in 1839" on a row holding events from 1830 and 1891.
        /// Such a row is really two questions, and settling it in one go either
        /// hides a legitimate answer (candidates are filtered by the earliest
        /// year) or gets refused at bind time.
        let boundariesCrossed: [(year: Int, districtName: String, opened: Bool)]

        var profileCount: Int { Set(occurrences.map(\.profileID)).count }

        /// Every use of this text has been dismissed as naming no place.
        var isNotAPlace: Bool { !occurrences.isEmpty && occurrences.allSatisfy(\.isNotAPlace) }

        /// Every use carries a decision or an existing code. `confidence` still
        /// describes how well the TEXT resolves — the gazetteer has not learned
        /// anything about "Bolehill" — but the row itself is answered, and
        /// showing it as "Unresolved" after the user settled it is the app
        /// contradicting them.
        var isSettled: Bool { !occurrences.isEmpty && occurrences.allSatisfy(\.isBound) }

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
        lifeEvents: [LifeEvent] = [], dismissed: Set<String> = [],
        decisions: PlaceDecisionSet = .empty
    ) -> [Row] {
        var byText: [String: [Occurrence]] = [:]
        let live = profiles.filter { !$0.isDeleted }
        let nameByID = Dictionary(live.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let liveIDs = Set(live.map(\.id))

        func add(_ text: String?, code: String?, profileID: String, profileName: String,
                 target: LocationNormalizer.Target, key: String, year: Int?,
                 recordParish: String? = nil, recordDistrict: String? = nil) {
            guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return }
            let id = "\(profileID)|\(key)"
            let decision = decisions.decision(for: raw, occurrenceID: id, year: year)
            byText[raw, default: []].append(Occurrence(
                id: id, profileID: profileID, profileName: profileName,
                target: target, fieldKey: key, year: year,
                isBound: decision != nil
                    || !((code ?? "").trimmingCharacters(in: .whitespaces).isEmpty),
                decision: decision,
                isNotAPlace: dismissed.contains(id),
                recordParish: recordParish, recordDistrict: recordDistrict))
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
            let census: CensusDetails? = if case .census(let d) = e.details { d } else { nil }
            add(e.location, code: e.locationCode, profileID: e.profileID,
                profileName: nameByID[e.profileID] ?? "",
                target: .lifeEvent(id: e.id, type: e.type.rawValue),
                key: "event:\(e.id.uuidString)", year: e.sortYear,
                recordParish: census?.parish, recordDistrict: census?.district)
        }

        let districtsByProfile = knownDistricts(of: live, decisions: decisions)
        let kin = kinIndex(relationships, among: liveIDs)

        return byText.map { text, occurrences in
            score(text: text, occurrences: occurrences,
                  corroboration: corroboration(for: occurrences, rowText: text,
                                               kin: kin, districts: districtsByProfile))
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

    /// A district a profile is already established in, and the location string it
    /// was derived from (nil when it came from an applied record rather than a
    /// coded place).
    struct KnownDistrict: Sendable, Hashable {
        let districtID: String
        /// The tree text this was derived from. Carried so corroboration can
        /// refuse to count a decision as evidence for itself.
        let fromText: String?
    }

    /// Districts each profile is already established in, from the structured
    /// fields only — the typed birth registration district (Slice C, written by
    /// apply from a cited birth record) and any birth/death location code that
    /// rolls up to a district. Free text is deliberately excluded: corroborating
    /// an unresolved string with another unresolved string is circular.
    static func knownDistricts(
        of profiles: [Profile], decisions: PlaceDecisionSet = .empty
    ) -> [String: Set<KnownDistrict>] {
        let places = PlaceAuthorityRegistry.shared.places
        var byProfile: [String: Set<KnownDistrict>] = [:]

        func districtID(for code: String) -> String? {
            if let district = places.registrationDistrict(of: code) { return district.id }
            // Already a district id — the Places tab binds these directly.
            return code.hasSuffix("-RD") ? code : nil
        }

        for p in profiles {
            var found: Set<KnownDistrict> = []
            // No source text: this came from an applied, cited birth record, so
            // it is independent of anything decided in the Places tab.
            if let rd = p.birthRegistrationDistrict, !rd.isEmpty {
                found.insert(KnownDistrict(districtID: rd, fromText: nil))
            }
            for (code, text) in [(p.birthLocationCode, p.birthLocation),
                                 (p.deathLocationCode, p.deathLocation)] {
                guard let code, !code.isEmpty, let id = districtID(for: code) else { continue }
                found.insert(KnownDistrict(districtID: id, fromText: text))
            }
            // Decisions count as established districts too — a place the user
            // settled is exactly as real as a coded one. `fromText` carries the
            // string that was settled, so `corroboration` can still refuse to
            // let a decision vouch for itself while a decision about a DIFFERENT
            // string in the family goes on counting.
            for (field, text) in [(ProfileField.birthLocation.rawValue, p.birthLocation),
                                  (ProfileField.deathLocation.rawValue, p.deathLocation)] {
                guard let text, !text.isEmpty,
                      let decision = decisions.decision(for: text, occurrenceID: "\(p.id)|\(field)")
                else { continue }
                found.insert(KnownDistrict(districtID: decision.placeAuthorityID, fromText: text))
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
    ///
    /// **A decision is never evidence for itself.** Binding "Middleton,
    /// Derbyshire" for one person writes a code that would otherwise come back as
    /// independent corroboration when their sibling's identical "Middleton,
    /// Derbyshire" is scored — the same choice echoed, wearing the clothes of a
    /// second opinion. Districts derived from `rowText` are therefore excluded.
    static func corroboration(
        for occurrences: [Occurrence], rowText: String,
        kin: [String: Set<String>], districts: [String: Set<KnownDistrict>]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for profileID in Set(occurrences.map(\.profileID)) {
            // The person's own established districts count too — a known death
            // district is evidence about how to read their birthplace.
            var circle = kin[profileID] ?? []
            circle.insert(profileID)
            for relative in circle {
                for known in districts[relative] ?? [] {
                    if let from = known.fromText,
                       from.caseInsensitiveCompare(rowText) == .orderedSame { continue }
                    counts[known.districtID, default: 0] += 1
                }
            }
        }
        return counts
    }

    // MARK: - Decisions

    enum BindError: Error, Equatable {
        /// The chosen district's validity window excludes years on this row.
        case districtCannotHoldYears(district: String, validFrom: Int?, validTo: Int?, years: [Int])

        var message: String {
            switch self {
            case .districtCannotHoldYears(let district, let from, let to, let years):
                let window = [from.map { "from \($0)" }, to.map { "to \($0)" }]
                    .compactMap { $0 }.joined(separator: " ")
                let list = years.map(String.init).joined(separator: ", ")
                return "\(district) existed \(window), so it cannot hold \(list)."
            }
        }
    }

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
        _ row: Row, occurrenceIDs: Set<String>, to code: String,
        reason: String = "", in db: ProjectDatabase, now: Date = Date()
    ) throws -> Int {
        // Window the decision to the chosen district's own validity. Bind
        // "Middleton, Derbyshire" to Bakewell RD and the decision starts in 1839,
        // so Ruth Brailsford's 1824 birth can never inherit it — the bug that
        // started this work is structurally unreachable rather than merely fixed.
        let district = PlaceAuthorityRegistry.shared.places.place(id: code)
        let targets = row.occurrences.filter { occurrenceIDs.contains($0.id) && !$0.isBound }
        guard !targets.isEmpty else { return 0 }

        // Refuse a district that cannot hold the years being settled, at the
        // moment the human tries it. Bakewell RD began in 1839; binding it to
        // Ruth Brailsford's 1824 birth is the original bug, and rejecting it here
        // is both earlier and more explicable than quietly declining to apply
        // the decision later.
        let impossible = PlaceDecision.yearsOutsideWindow(
            targets.compactMap(\.year), from: district?.validFrom, to: district?.validTo)
        guard impossible.isEmpty else {
            throw BindError.districtCannotHoldYears(
                district: district?.name ?? code,
                validFrom: district?.validFrom, validTo: district?.validTo,
                years: impossible)
        }

        for occurrence in targets {
            // A fresh id per decision INSTANCE, not per (text, field): the table
            // keeps every answer ever given, so a deterministic key would collide
            // with the very row it is meant to supersede the moment someone
            // changes their mind.
            try db.recordPlaceDecision(PlaceDecision(
                id: UUID().uuidString,
                placeText: PlaceDecision.canonicalKey(row.text),
                displayText: row.text,
                scopeField: occurrence.id,
                placeAuthorityID: code,
                yearFrom: district?.validFrom, yearTo: district?.validTo,
                reason: reason, decidedAt: now, supersededAt: nil))
            // Binding answers the question the set-aside flag was raised about.
            try db.clearCleanseUnresolvable(profileID: occurrence.profileID, field: occurrence.fieldKey)
        }
        return targets.count
    }

    /// The "apply to all N occurrences" convenience — an explicit choice the user
    /// makes after seeing who is affected, not the default path.
    @discardableResult
    static func bindAll(
        _ row: Row, to code: String, reason: String = "",
        in db: ProjectDatabase, now: Date = Date()
    ) throws -> Int {
        try bind(row, occurrenceIDs: Set(row.occurrences.map(\.id)), to: code,
                 reason: reason, in: db, now: now)
    }

    /// Undo — retires every live decision this row carries. The rows stay in the
    /// table; a changed mind is history, not a mistake to erase.
    static func unbind(_ row: Row, decisions: PlaceDecisionSet, in db: ProjectDatabase) throws {
        for occurrence in row.occurrences {
            guard let decision = decisions.decision(
                for: row.text, occurrenceID: occurrence.id, year: occurrence.year) else { continue }
            try db.supersedePlaceDecision(id: decision.id)
        }
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

    /// The distinct parish/district pairs the source records state for a row.
    ///
    /// "Shining Row" is an address; the 1891 schedule it appears on names
    /// Turnditch parish, Belper district. That is the answer, already cited,
    /// sitting in the same record the address came from.
    static func recordPlaces(
        in occurrences: [Occurrence]
    ) -> [(parish: String, district: String, years: [Int])] {
        var byPair: [String: (parish: String, district: String, years: [Int])] = [:]
        for occurrence in occurrences {
            guard let parish = occurrence.recordParish?.trimmingCharacters(in: .whitespaces),
                  !parish.isEmpty else { continue }
            let district = (occurrence.recordDistrict ?? "").trimmingCharacters(in: .whitespaces)
            let key = "\(parish.lowercased())|\(district.lowercased())"
            var entry = byPair[key] ?? (parish, district, [])
            if let year = occurrence.year, !entry.years.contains(year) { entry.years.append(year) }
            byPair[key] = entry
        }
        return byPair.values
            .map { ($0.parish, $0.district, $0.years.sorted()) }
            .sorted { $0.parish < $1.parish }
    }

    /// The parish node a record's own (parish, district) pair names.
    static func authorityForRecordPlace(
        parish: String, district: String, year: Int?
    ) -> PlaceAuthority? {
        let places = PlaceAuthorityRegistry.shared
        let candidates = places.parishRecords(named: parish, year: year, chapman: nil)
        guard !candidates.isEmpty else { return nil }
        // Prefer the one under the district the record names.
        if !district.isEmpty {
            let wanted = PlaceAuthority.foldedName(district)
            if let exact = candidates.first(where: {
                PlaceAuthority.foldedName(
                    places.places.registrationDistrict(of: $0.id)?.name ?? "") == wanted
            }) { return exact }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Whether a settled row went somewhere the app's own resolution never
    /// offered — a genuine hand placement rather than agreement.
    ///
    /// Compares the decision's REGISTRATION DISTRICT against the row's
    /// candidates. Comparing the ids directly cannot work: a decision usually
    /// names a parish ("DBY:Belper-RD/Wirksworth") while candidates are
    /// districts ("DBY:Belper-RD"), so the marker fired on every search-bound
    /// decision — including ones the census schedule corroborated word for word,
    /// which left the pane saying "the gazetteer did not match this text"
    /// directly beneath "the 1891 record names the parish itself".
    static func wasPlacedByHand(_ row: Row) -> Bool {
        guard let code = settledCode(row) else { return false }
        guard !row.candidates.isEmpty else { return true }
        let decided = PlaceAuthorityRegistry.shared.registrationDistrict(ofID: code)?.id ?? code
        return !row.candidates.contains { $0.id == decided }
    }

    /// The place a settled row was settled to.
    static func settledCode(_ row: Row) -> String? {
        guard row.isSettled else { return nil }
        return row.occurrences.compactMap(\.decision?.placeAuthorityID).first
    }

    /// Of the rows settled to the same place under the same variant key, the ids
    /// to KEEP in the list — one per group, the spelling most fields use.
    ///
    /// Unsettled rows are always kept: collapsing one would hide a question
    /// rather than a duplicate. Rows settled to DIFFERENT places are never
    /// grouped — that is a distinction the user drew deliberately.
    static func collapsedSurvivorIDs(_ rows: [Row]) -> Set<String> {
        var best: [String: Row] = [:]
        for row in rows {
            guard let code = settledCode(row) else { continue }
            let key = "\(row.variantKey)|\(code)"
            if let held = best[key], held.occurrences.count >= row.occurrences.count { continue }
            best[key] = row
        }
        let winners = Set(best.values.map(\.id))
        return Set(rows.filter { settledCode($0) == nil || winners.contains($0.id) }.map(\.id))
    }

    /// The settled place in full: settlement, parish, district, county —
    /// "Bolehill, Wirksworth, Belper, Derbyshire".
    ///
    /// Settling does not rename anything. The tree still says "Bolehill", and
    /// that is the most precise name in the chain — a real settlement the
    /// catalogue has never listed. What the decision adds is where it SITS, so
    /// the display keeps the user's own word at the front and appends what the
    /// authority knows above it. That composed line is the user-built layer over
    /// the bundled gazetteer, made visible.
    ///
    /// A name already present is not repeated: settling "Wirksworth" itself to
    /// Wirksworth parish reads "Wirksworth, Belper, Derbyshire", not
    /// "Wirksworth, Wirksworth, Belper, Derbyshire".
    static func hierarchyDisplay(text: String, placeAuthorityID: String) -> String {
        let places = PlaceAuthorityRegistry.shared.places
        var parts: [String] = []

        // The settlement as the tree names it, without trailing county/country.
        if let settlement = RegistrationDistrictResolver.segments(of: text).first {
            parts.append(settlement)
        }
        if let bound = places.place(id: placeAuthorityID), bound.kind == .parish {
            parts.append(bound.name)
        }
        if let district = places.registrationDistrict(of: placeAuthorityID) {
            parts.append(district.name)
        }
        if let county = places.county(of: placeAuthorityID) {
            parts.append(county.name)
        }

        // Collapse repeats while preserving order — "Wirksworth, Wirksworth" is
        // the common one, but a district and parish can share a name too.
        var seen: Set<String> = []
        return parts
            .filter { seen.insert($0.lowercased()).inserted }
            .joined(separator: ", ")
    }

    /// The place a string names, with trailing county and country dropped.
    ///
    /// "Wirksworth, Derbyshire, England" and "Wirksworth" are the same village
    /// recorded two ways; on the live tree Wirksworth appears under four
    /// spellings across 21 people, and settling each separately is most of the
    /// work in the queue.
    ///
    /// Only county and country tokens are dropped, never a qualifier: "Middleton"
    /// and "Middleton By Wirksworth" stay distinct, because they are two
    /// different villages and merging them would be the Bakewell mistake again.
    static func variantKey(for text: String) -> String {
        var parts = RegistrationDistrictResolver.segments(of: text)
        let countries: Set<String> = ["england", "scotland", "wales", "uk",
                                      "united kingdom", "great britain", "gb"]
        // Never strip the LAST segment. "Derbyshire" is entirely county, and
        // emptying it would give every bare county the same key — so the tab
        // would offer to settle Warwickshire as another spelling of Derbyshire.
        while parts.count > 1, let last = parts.last?.lowercased() {
            guard countries.contains(last)
                    || UKChapmanCodes.shared.chapmanCode(forCountyName: parts[parts.count - 1]) != nil
            else { break }
            parts.removeLast()
        }
        return parts.joined(separator: ", ").lowercased()
    }

    /// District openings and closings that fall strictly inside `years`.
    ///
    /// A row whose uses straddle one is two questions wearing one row: the era
    /// filter narrows candidates by the EARLIEST year, so a district that is
    /// right for the later events is ruled out on account of the earlier ones.
    static func boundaries(
        crossedBy years: [Int], districts: [PlaceAuthority]
    ) -> [(year: Int, districtName: String, opened: Bool)] {
        guard let low = years.min(), let high = years.max(), low < high else { return [] }
        var out: [(year: Int, districtName: String, opened: Bool)] = []
        for district in districts {
            if let from = district.validFrom, from > low, from <= high {
                out.append((from, district.name, true))
            }
            if let to = district.validTo, to >= low, to < high {
                out.append((to, district.name, false))
            }
        }
        return out.sorted { $0.year != $1.year ? $0.year < $1.year : $0.districtName < $1.districtName }
    }

    /// The uses a district can actually hold — those whose year sits inside its
    /// validity window, plus any that carry no year at all.
    static func occurrenceIDsFitting(
        _ row: Row, districtID: String, within ids: Set<String>
    ) -> Set<String> {
        let district = PlaceAuthorityRegistry.shared.places.place(id: districtID)
        return Set(row.occurrences
            .filter { ids.contains($0.id) && !$0.isBound }
            .filter { occurrence in
                guard let year = occurrence.year else { return true }
                return PlaceDecision.yearsOutsideWindow(
                    [year], from: district?.validFrom, to: district?.validTo).isEmpty
            }
            .map(\.id))
    }

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
        let fromRecords = recordPlaces(in: occurrences)

        guard let result, !result.districts.isEmpty else {
            // THE RECORD MAY ALREADY SAY. "Shining Row" is an address the
            // gazetteer will never hold, but the 1891 schedule it sits on names
            // Turnditch parish, Belper district. Asking the user for something
            // the cited record states is the app not reading its own evidence.
            if fromRecords.count == 1, let only = fromRecords.first,
               let parish = authorityForRecordPlace(
                   parish: only.parish, district: only.district, year: year),
               let district = PlaceAuthorityRegistry.shared.registrationDistrict(ofID: parish.id) {
                let when = only.years.isEmpty
                    ? "The record"
                    : "The \(only.years.map(String.init).joined(separator: ", ")) record"
                reasons.append("\(when) names the parish itself: \(only.parish)"
                               + (only.district.isEmpty ? "." : ", \(only.district) district."))
                reasons.append("The gazetteer has no entry for \u{201C}\(text)\u{201D} — "
                               + "this is an address, and the parish comes from the schedule it sits on.")
                return Row(id: text, text: text, occurrences: occurrences, candidates: [district],
                           eliminated: [], placeNames: [parish.name],
                           matchedSegment: nil, confidence: .high, reasons: reasons,
                           variantKey: variantKey(for: text),
                           corroboration: corroboration.filter { $0.key == district.id },
                           allCorroboration: corroboration,
                           resolvedDisplay: hierarchyDisplay(text: text, placeAuthorityID: parish.id),
                           recordPlaces: fromRecords,
                           boundariesCrossed: [])
            }
            if fromRecords.count > 1 {
                reasons.append("The records disagree: "
                               + fromRecords.map { "\($0.parish)"
                                   + ($0.years.isEmpty ? "" : " (\($0.years.map(String.init).joined(separator: ", ")))") }
                                   .joined(separator: " vs ")
                               + ". The same words name more than one place.")
            }
            reasons.append("No registration district matches any part of this text.")
            if stated == nil { reasons.append("No county stated, so nothing narrows the search.") }
            return Row(id: text, text: text, occurrences: occurrences, candidates: [],
                       eliminated: [], placeNames: [], matchedSegment: nil,
                       confidence: .unresolved, reasons: reasons,
                       variantKey: variantKey(for: text),
                       corroboration: [:], allCorroboration: corroboration,
                       resolvedDisplay: nil,
                       recordPlaces: fromRecords, boundariesCrossed: [])
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
                   confidence: confidence, reasons: reasons,
                   variantKey: variantKey(for: text),
                   corroboration: relevant, allCorroboration: corroboration,
                   // Only when one district survives — with rivals on the table
                   // there is no single chain to state.
                   resolvedDisplay: ranked.count == 1
                       ? hierarchyDisplay(text: text, placeAuthorityID: ranked[0].id) : nil,
                   recordPlaces: fromRecords,
                   boundariesCrossed: boundaries(
                       crossedBy: occurrences.compactMap(\.year),
                       districts: ranked + result.eliminated.map(\.district)))
    }
}
