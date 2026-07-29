import Foundation

// MARK: - FreeREG detail-page → typed model mapper (FREEREG_INTEGRATION_SPEC §2)
//
// Maps the (label, value) pairs scraped from a FreeREG record detail page into
// the typed `FreeREGDetail`. Input is the ORDERED raw pairs (labels as
// rendered, tags stripped) — order is load-bearing for witness grouping when
// the page repeats identical "Witness forename"/"Witness surname" labels.
//
// Key tolerance: the live pages render possessive labels ("Father's
// Forename" → normalised `fathers_forename`) while MyopicVicar's DB schema
// uses `father_forename`; transcription-era pages vary further
// (forename/forenames/first name). Every lookup therefore resolves through
// role-prefix AND attribute-suffix variant lists. Unknown labels are ignored
// (never fatal) — the raw pairs also land in `rawFields` upstream, so nothing
// is lost, only un-typed.

public nonisolated enum FreeREGDetailMapper {

    // MARK: Public entry

    /// Build the typed detail from ordered raw (label, value) pairs.
    /// `typeHint` is the search-row's event type ("baptism"/"marriage"/
    /// "burial", or a RecordType rawValue) — used when the page itself
    /// doesn't carry a usable record-type marker. Returns nil when the
    /// event type can't be determined or the principal person is
    /// unidentifiable (an unattributable payload is worse than none).
    public static func detail(fromLabelledPairs rawPairs: [(String, String)], typeHint: String? = nil) -> FreeREGDetail? {
        let pairs = normalisedPairs(rawPairs)
        guard !pairs.isEmpty else { return nil }
        let map = firstWinsMap(pairs)

        guard let kind = eventKind(map: map, typeHint: typeHint) else { return nil }

        let event: FreeREGEvent?
        switch kind {
        case .baptism: event = baptism(map: map, pairs: pairs)
        case .marriage: event = marriage(map: map, pairs: pairs)
        case .burial: event = burial(map: map)
        }
        guard let event else { return nil }

        let register = registerReference(map: map)
        let provenance = provenance(map: map)
        let notes = notes(map: map)
        return FreeREGDetail(
            event: event,
            churchName: value(map, keys: ["church_name", "church"]),
            location: value(map, keys: ["location"]),
            register: register.isEmpty ? nil : register,
            provenance: provenance.isEmpty ? nil : provenance,
            notes: notes.isEmpty ? nil : notes
        )
    }

    // MARK: Key normalisation

    /// "Father forename" → "father_forename". The live pages generate
    /// labels via Rails `field.gsub('_',' ').capitalize`, so normalised
    /// keys are EXACTLY the MyopicVicar DB field names; possessive forms
    /// ("Father's Forename") are tolerated for legacy fixtures. Label
    /// cells can carry a parenthetical note — "Church name (Links to
    /// more information)" — which is stripped before normalisation.
    public static func normaliseKey(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
    }

    private static func normalisedPairs(_ raw: [(String, String)]) -> [(key: String, value: String)] {
        raw.compactMap { label, value in
            let key = normaliseKey(label)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !trimmed.isEmpty else { return nil }
            return (key, trimmed)
        }
    }

    /// First occurrence wins — mirrors the upstream rawFields behaviour.
    private static func firstWinsMap(_ pairs: [(key: String, value: String)]) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in pairs where map[key] == nil {
            map[key] = value
        }
        return map
    }

    // MARK: Event-kind resolution

    private enum EventKind { case baptism, marriage, burial }

    private static func eventKind(map: [String: String], typeHint: String?) -> EventKind? {
        // 1. The page's own record-type marker.
        if let marker = value(map, keys: ["record_type", "type"])?.lowercased() {
            if let kind = kind(fromToken: marker) { return kind }
        }
        // 2. Kind-specific date keys (confirmation / received-into-church
        // entries are baptism-family records that may carry no baptism date).
        if value(map, keys: ["baptism_date", "date_of_baptism", "confirmation_date", "received_into_church_date"]) != nil { return .baptism }
        if value(map, keys: ["marriage_date", "date_of_marriage", "contract_date"]) != nil { return .marriage }
        if value(map, keys: ["burial_date", "date_of_burial"]) != nil { return .burial }
        // 3. Kind-specific role blocks (surname-only entries included —
        // an undated surname-only burial must not fall to a wrong hint).
        if value(map, keys: ["groom_forename", "grooms_forename", "groom_surname", "grooms_surname",
                             "bride_forename", "brides_forename", "bride_surname", "brides_surname"]) != nil { return .marriage }
        if value(map, keys: ["burial_person_forename", "burial_persons_forename",
                             "burial_person_surname", "burial_persons_surname"]) != nil { return .burial }
        // 4. The caller's hint (search-row event type).
        if let hint = typeHint?.lowercased(), let kind = kind(fromToken: hint) { return kind }
        return nil
    }

    private static func kind(fromToken token: String) -> EventKind? {
        if token.contains("bapt") || token.contains("christen") || token == "ba" { return .baptism }
        if token.contains("marria") || token == "ma" { return .marriage }
        if token.contains("burial") || token.contains("buri") || token == "bu" { return .burial }
        return nil
    }

    // MARK: Role-scoped person extraction

    /// Attribute-suffix variants, in preference order.
    private static let forenameSuffixes = ["forename", "forenames", "first_name", "first_names", "given_name"]
    private static let surnameSuffixes = ["surname", "last_name"]
    private static let titleSuffixes = ["title"]
    private static let sexSuffixes = ["sex"]
    private static let ageSuffixes = ["age"]
    private static let conditionSuffixes = ["condition"]
    private static let statusSuffixes = ["status"]
    private static let occupationSuffixes = ["occupation"]
    private static let abodeSuffixes = ["abode", "residence"]
    /// Own-place context ("Father place"/"Father county") — looked up
    /// ONLY under a non-empty role prefix: the bare "Place"/"County"
    /// labels are the EVENT's parish/county rows, never a person's.
    private static let placeSuffixes = ["place"]
    private static let countySuffixes = ["county"]
    /// Birthplace ("Person place birth" on extended baptisms).
    private static let placeOfBirthSuffixes = ["place_birth", "place_of_birth", "birth_place"]
    private static let countyOfBirthSuffixes = ["county_birth", "county_of_birth", "birth_county"]

    /// Look up `{prefix}_{suffix}` across every prefix/suffix variant; an
    /// EMPTY prefix means the bare suffix key (the principal person's
    /// fields are often unprefixed on the page).
    private static func roleValue(_ map: [String: String], prefixes: [String], suffixes: [String]) -> String? {
        for prefix in prefixes {
            for suffix in suffixes {
                let key = prefix.isEmpty ? suffix : "\(prefix)_\(suffix)"
                if let v = map[key], !v.isEmpty { return v }
            }
        }
        return nil
    }

    private static func person(_ map: [String: String], prefixes: [String]) -> FreeREGPerson {
        // Own-place lookups must never fall through to the event's bare
        // "Place"/"County" rows — restrict them to non-empty prefixes.
        let rolePrefixes = prefixes.filter { !$0.isEmpty }
        return FreeREGPerson(
            forename: roleValue(map, prefixes: prefixes, suffixes: forenameSuffixes),
            surname: roleValue(map, prefixes: prefixes, suffixes: surnameSuffixes),
            title: roleValue(map, prefixes: prefixes, suffixes: titleSuffixes),
            sex: roleValue(map, prefixes: prefixes, suffixes: sexSuffixes),
            age: roleValue(map, prefixes: prefixes, suffixes: ageSuffixes),
            condition: roleValue(map, prefixes: prefixes, suffixes: conditionSuffixes),
            status: roleValue(map, prefixes: prefixes, suffixes: statusSuffixes),
            occupation: roleValue(map, prefixes: prefixes, suffixes: occupationSuffixes),
            abode: roleValue(map, prefixes: prefixes, suffixes: abodeSuffixes),
            place: roleValue(map, prefixes: rolePrefixes, suffixes: placeSuffixes),
            county: roleValue(map, prefixes: rolePrefixes, suffixes: countySuffixes),
            placeOfBirth: roleValue(map, prefixes: prefixes, suffixes: placeOfBirthSuffixes),
            countyOfBirth: roleValue(map, prefixes: prefixes, suffixes: countyOfBirthSuffixes)
        )
    }

    private static func nonEmptyPerson(_ map: [String: String], prefixes: [String]) -> FreeREGPerson? {
        let p = person(map, prefixes: prefixes)
        return p.isEmpty ? nil : p
    }

    private static func value(_ map: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let v = map[key], !v.isEmpty { return v }
        }
        return nil
    }

    /// Boolean fields carry the RAW transcribed value — MyopicVicar's
    /// ingest normalisation to boolean is commented out, and its constants
    /// enumerate the accepted truthy spellings (e.g.
    /// MARRIAGE_BY_LICENCE_OPTIONS includes "licence"/"by licence";
    /// PRIVATE_BAPTISM_OPTIONS includes "private"/"private baptism").
    /// `extraTruthy` carries the per-field vocabulary; unrecognised
    /// non-empty values return nil (the raw text stays in rawFields).
    private static func boolValue(_ map: [String: String], keys: [String], extraTruthy: Set<String> = []) -> Bool? {
        guard let raw = value(map, keys: keys)?.lowercased() else { return nil }
        if ["true", "yes", "y", "1"].contains(raw) || extraTruthy.contains(raw) { return true }
        if ["false", "no", "n", "0"].contains(raw) { return false }
        return nil
    }

    // MARK: Baptism

    private static func baptism(map: [String: String], pairs: [(key: String, value: String)]) -> FreeREGEvent? {
        // Child: explicit person_* first, then bare keys.
        let child = person(map, prefixes: ["person", "persons", ""])
        guard !child.isEmpty else { return nil }

        var mother: FreeREGMother?
        if let motherPerson = nonEmptyPerson(map, prefixes: ["mother", "mothers"]) {
            mother = FreeREGMother(
                person: motherPerson,
                conditionPriorToMarriage: value(map, keys: ["mother_condition_prior_to_marriage", "mothers_condition_prior_to_marriage"]),
                placePriorToMarriage: value(map, keys: ["mother_place_prior_to_marriage", "mothers_place_prior_to_marriage"]),
                countyPriorToMarriage: value(map, keys: ["mother_county_prior_to_marriage", "mothers_county_prior_to_marriage"])
            )
        }

        return .baptism(FreeREGBaptism(
            child: child,
            birthDate: value(map, keys: ["birth_date", "date_of_birth"]),
            baptismDate: value(map, keys: ["baptism_date", "date_of_baptism", "date"]),
            confirmationDate: value(map, keys: ["confirmation_date"]),
            receivedIntoChurchDate: value(map, keys: ["received_into_church_date"]),
            isPrivate: boolValue(map, keys: ["private_baptism"],
                                 extraTruthy: ["private", "private baptism", "private_baptism"]),
            father: nonEmptyPerson(map, prefixes: ["father", "fathers"]),
            mother: mother,
            witnesses: witnesses(pairs: pairs)
        ))
    }

    // MARK: Marriage

    private static func marriage(map: [String: String], pairs: [(key: String, value: String)]) -> FreeREGEvent? {
        let groom = person(map, prefixes: ["groom", "grooms"])
        let bride = person(map, prefixes: ["bride", "brides"])
        // A marriage entry with neither principal identifiable is unusable.
        guard !groom.isEmpty || !bride.isEmpty else { return nil }

        return .marriage(FreeREGMarriage(
            groom: groom,
            bride: bride,
            groomParish: value(map, keys: ["groom_parish", "grooms_parish"]),
            brideParish: value(map, keys: ["bride_parish", "brides_parish"]),
            groomFather: nonEmptyPerson(map, prefixes: ["groom_father", "grooms_father", "grooms_fathers"]),
            groomMother: nonEmptyPerson(map, prefixes: ["groom_mother", "grooms_mother", "grooms_mothers"]),
            brideFather: nonEmptyPerson(map, prefixes: ["bride_father", "brides_father", "brides_fathers"]),
            brideMother: nonEmptyPerson(map, prefixes: ["bride_mother", "brides_mother", "brides_mothers"]),
            marriageDate: value(map, keys: ["marriage_date", "date_of_marriage", "date"]),
            contractDate: value(map, keys: ["contract_date"]),
            byLicence: boolValue(map, keys: ["marriage_by_licence", "by_licence"],
                                 extraTruthy: ["licence", "by licence", "by_licence", "marriage_by_licence"]),
            marriageBy: value(map, keys: ["marriage_by"]),
            groomMarked: value(map, keys: ["groom_marked", "grooms_marked"]),
            brideMarked: value(map, keys: ["bride_marked", "brides_marked"]),
            witnesses: witnesses(pairs: pairs)
        ))
    }

    // MARK: Burial

    private static func burial(map: [String: String]) -> FreeREGEvent? {
        let deceased = person(map, prefixes: ["burial_person", "burial_persons", "person", "persons", ""])
        guard !deceased.isEmpty else { return nil }

        // The relative(s) named on the entry (NOT the deceased). The male
        // and female blocks are DIFFERENT PEOPLE ("son of John and Jane")
        // and must never share suffix hits across prefixes — a mixed
        // lookup welds John's forename onto Jane's surname (verify
        // finding 2026-07-29). Extract each block independently; the
        // shared `relative_surname` backfills a missing surname per
        // block (the female block prefers its own `female_relative_surname`).
        let sharedSurname = value(map, keys: ["relative_surname", "relatives_surname"])
        var maleRelative = nonEmptyPerson(map, prefixes: ["male_relative"])
        if var m = maleRelative, m.surname == nil { m.surname = sharedSurname; maleRelative = m }
        var femaleRelative = nonEmptyPerson(map, prefixes: ["female_relative"])
        if var f = femaleRelative, f.surname == nil { f.surname = sharedSurname; femaleRelative = f }
        // Ungendered block (legacy/odd layouts) — only when no gendered
        // block matched, so it can't double-count.
        var genericRelative: FreeREGPerson?
        if maleRelative == nil, femaleRelative == nil {
            genericRelative = nonEmptyPerson(map, prefixes: ["relative", "relatives"])
            if var g = genericRelative, g.surname == nil { g.surname = sharedSurname; genericRelative = g }
        }
        let relative = maleRelative ?? femaleRelative ?? genericRelative
        let secondRelative = (maleRelative != nil) ? femaleRelative : nil

        return .burial(FreeREGBurial(
            deceased: deceased,
            burialDate: value(map, keys: ["burial_date", "date_of_burial", "date"]),
            deathDate: value(map, keys: ["death_date", "date_of_death"]),
            causeOfDeath: value(map, keys: ["cause_of_death"]),
            placeOfDeath: value(map, keys: ["place_of_death"]),
            relationship: value(map, keys: ["relationship", "persons_relationship", "person_relationship"]),
            relative: relative,
            secondRelative: secondRelative,
            burialParish: value(map, keys: ["burial_parish"]),
            burialLocationInformation: value(map, keys: ["burial_location_information"]),
            memorialInformation: value(map, keys: ["memorial_information"]),
            consecratedGround: value(map, keys: ["consecrated_ground"])
        ))
    }

    // MARK: Witnesses

    /// Extract ordered witnesses from the pair stream.
    ///
    /// THE live shape (verified against MyopicVicar
    /// `order_fields_for_record_type` + `_entry_detail.html.erb`,
    /// 2026-07-29): one row per witness labelled `Witness1`…`Witness8`
    /// (no space, max 8 = `MAXIMUM_WINESSES`), whose VALUE is the
    /// combined "Forename Surname" — split here with the last token as
    /// surname (the same convention as the search-row name resolver).
    /// Two legacy/defensive shapes are also handled: numbered
    /// attribute keys (`witness1_forename`) grouped by number, and
    /// repeated unnumbered attribute keys grouped by adjacency.
    static func witnesses(pairs: [(key: String, value: String)]) -> [FreeREGWitness] {
        // Live shape: bare numbered label, combined-name value.
        let combinedPattern = #"^witness(?:es)?_?(\d+)$"#
        // Legacy shape: numbered-or-not attribute key.
        let attrPattern = #"^witness(?:es)?_?(\d*)_(.+)$"#
        guard let combinedRegex = try? NSRegularExpression(pattern: combinedPattern),
              let attrRegex = try? NSRegularExpression(pattern: attrPattern) else { return [] }

        var combined: [(number: Int, witness: FreeREGWitness)] = []
        var numbered: [Int: FreeREGWitness] = [:]
        var numberedOrder: [Int] = []
        var adjacent: [FreeREGWitness] = []

        for (key, value) in pairs {
            let fullRange = NSRange(key.startIndex..., in: key)

            if let match = combinedRegex.firstMatch(in: key, range: fullRange),
               let numberRange = Range(match.range(at: 1), in: key),
               let number = Int(key[numberRange]) {
                let tokens = value.split(separator: " ").map(String.init)
                guard !tokens.isEmpty else { continue }
                let witness = tokens.count == 1
                    ? FreeREGWitness(forename: tokens[0])
                    : FreeREGWitness(
                        forename: tokens.dropLast().joined(separator: " "),
                        surname: tokens.last
                    )
                combined.append((number, witness))
                continue
            }

            guard let match = attrRegex.firstMatch(in: key, range: fullRange),
                  let attrRange = Range(match.range(at: 2), in: key) else { continue }
            let attr = String(key[attrRange])
            let number: Int? = Range(match.range(at: 1), in: key).flatMap { Int(key[$0]) }

            let isForename = forenameSuffixes.contains(attr)
            let isSurname = surnameSuffixes.contains(attr)
            guard isForename || isSurname else { continue }

            if let number {
                var w = numbered[number] ?? FreeREGWitness()
                if isForename, w.forename == nil { w.forename = value }
                if isSurname, w.surname == nil { w.surname = value }
                if numbered[number] == nil { numberedOrder.append(number) }
                numbered[number] = w
            } else {
                if isForename {
                    // A forename always opens a new witness.
                    adjacent.append(FreeREGWitness(forename: value))
                } else if var last = adjacent.last, last.surname == nil {
                    last.surname = value
                    adjacent[adjacent.count - 1] = last
                } else {
                    // A surname with no open witness — surname-only witness.
                    adjacent.append(FreeREGWitness(surname: value))
                }
            }
        }

        // Live combined shape wins; then numbered attrs; then adjacency.
        let all: [FreeREGWitness]
        if !combined.isEmpty {
            all = combined.sorted { $0.number < $1.number }.map(\.witness)
        } else if !numberedOrder.isEmpty {
            all = numberedOrder.compactMap { numbered[$0] }
        } else {
            all = adjacent
        }
        return all.filter { $0.forename != nil || $0.surname != nil }
    }

    // MARK: Shared blocks

    private static func registerReference(map: [String: String]) -> FreeREGRegisterReference {
        FreeREGRegisterReference(
            register: value(map, keys: ["register"]),
            registerType: value(map, keys: ["register_type"]),
            registerEntryNumber: value(map, keys: ["register_entry_number", "entry_number"]),
            film: value(map, keys: ["film"]),
            filmNumber: value(map, keys: ["film_number"]),
            imageFileName: value(map, keys: ["image_file_name"])
        )
    }

    private static func provenance(map: [String: String]) -> FreeREGProvenance {
        FreeREGProvenance(
            transcribedBy: value(map, keys: ["transcribed_by", "transcriber"]),
            credit: value(map, keys: ["credit"]),
            lineID: value(map, keys: ["line_id"])
        )
    }

    private static func notes(map: [String: String]) -> FreeREGNotes {
        FreeREGNotes(
            notes: value(map, keys: ["notes"]),
            notesFromTranscriber: value(map, keys: ["notes_from_transcriber", "transcriber_notes"])
        )
    }
}
