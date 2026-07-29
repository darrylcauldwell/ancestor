import Foundation

// MARK: - FreeREG typed record detail (FREEREG_INTEGRATION_SPEC §2)
//
// Typed model of a FreeREG parish-register entry, derived from the AUTHORITATIVE
// schema — FreeUKGen/MyopicVicar `app/models/freereg1_csv_entry.rb` (Apache-2.0),
// the Rails engine that runs freereg.org.uk — not reverse-engineered from HTML.
//
// This rides on `ParishRecord.detail` as an OPTIONAL payload: the flat
// `ParishRecord` stays the lossy projection the scorer/convergence call sites
// already read (no decision-core rewrite), while the typed detail carries what
// the flat shape drops: occupations, abodes, witnesses, the mother's
// prior-to-marriage context (maiden-origin leads), BOTH spouses' parents on a
// marriage, and the burial relative/relationship distinction. Fields are
// `String?` throughout — volunteer-transcribed data is stored as transcribed
// (ages like "3 mo"/"infant", sexes like "M"/"Male"); never coerce at the
// model layer.

/// The full typed payload of one FreeREG register entry.
public nonisolated struct FreeREGDetail: Codable, Sendable, Equatable {
    /// The event-specific payload — a register entry is exactly one of these.
    public let event: FreeREGEvent
    /// `church_name` — the specific church within the parish.
    public let churchName: String?
    /// `location` — free-text location supplement.
    public let location: String?
    public let register: FreeREGRegisterReference?
    public let provenance: FreeREGProvenance?
    public let notes: FreeREGNotes?

    public init(
        event: FreeREGEvent,
        churchName: String? = nil,
        location: String? = nil,
        register: FreeREGRegisterReference? = nil,
        provenance: FreeREGProvenance? = nil,
        notes: FreeREGNotes? = nil
    ) {
        self.event = event
        self.churchName = churchName
        self.location = location
        self.register = register
        self.provenance = provenance
        self.notes = notes
    }
}

/// Discriminated event payload — baptism / marriage / burial differ
/// structurally (who is named, in what role), so the model does too.
public nonisolated enum FreeREGEvent: Codable, Sendable, Equatable {
    case baptism(FreeREGBaptism)
    case marriage(FreeREGMarriage)
    case burial(FreeREGBurial)

    /// The event-type token the flat `ParishRecord.eventType` uses.
    public var eventTypeToken: String {
        switch self {
        case .baptism: "baptism"
        case .marriage: "marriage"
        case .burial: "burial"
        }
    }
}

/// A named person anywhere in a register entry. All fields as-transcribed.
public nonisolated struct FreeREGPerson: Codable, Sendable, Equatable {
    public var forename: String?
    public var surname: String?
    /// `*_title` — Mr/Mrs/Rev/Dr etc.
    public var title: String?
    /// `person_sex` — as transcribed ("M", "F", "Male"…); not coerced.
    public var sex: String?
    /// `*_age` — free-text ("24", "3 mo", "infant"); never blind-Int.
    public var age: String?
    /// `*_condition` — bachelor/spinster/widow(er).
    public var condition: String?
    /// `person_status` — social status (extended-layout files).
    public var status: String?
    public var occupation: String?
    public var abode: String?
    /// `father_place` / `father_county` — the person's own place context
    /// (extended layouts; distinct from the event parish).
    public var place: String?
    public var county: String?
    /// `person_place_birth` / `person_county_birth` — birthplace as
    /// transcribed (extended baptisms) — direct birthplace evidence.
    public var placeOfBirth: String?
    public var countyOfBirth: String?

    public init(
        forename: String? = nil, surname: String? = nil, title: String? = nil,
        sex: String? = nil, age: String? = nil, condition: String? = nil,
        status: String? = nil,
        occupation: String? = nil, abode: String? = nil,
        place: String? = nil, county: String? = nil,
        placeOfBirth: String? = nil, countyOfBirth: String? = nil
    ) {
        self.forename = forename
        self.surname = surname
        self.title = title
        self.sex = sex
        self.age = age
        self.condition = condition
        self.status = status
        self.occupation = occupation
        self.abode = abode
        self.place = place
        self.county = county
        self.placeOfBirth = placeOfBirth
        self.countyOfBirth = countyOfBirth
    }

    /// Display name assembled from the parts, or nil when both are empty.
    public var displayName: String? {
        let joined = [forename, surname].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// True when no identifying content at all (used to drop empty role blocks).
    public var isEmpty: Bool {
        [forename, surname, title, sex, age, condition, status, occupation,
         abode, place, county, placeOfBirth, countyOfBirth]
            .allSatisfy { ($0 ?? "").isEmpty }
    }
}

/// A witness to a marriage or baptism — MyopicVicar stores up to 8 numbered
/// witness pairs plus an embedded `multiple_witnesses` list; we model the
/// union as an ordered array.
public nonisolated struct FreeREGWitness: Codable, Sendable, Equatable {
    public var forename: String?
    public var surname: String?

    public init(forename: String? = nil, surname: String? = nil) {
        self.forename = forename
        self.surname = surname
    }

    public var displayName: String? {
        let joined = [forename, surname].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}

/// A baptism entry. The single richest FREE parentage source: names BOTH
/// parents, with the father's occupation/abode and the mother's
/// prior-to-marriage context (maiden-origin clues).
public nonisolated struct FreeREGBaptism: Codable, Sendable, Equatable {
    /// `person_*` — the child.
    public var child: FreeREGPerson
    /// `birth_date` — distinct from the baptism date; a late baptism often
    /// records both. Never conflate.
    public var birthDate: String?
    /// `baptism_date`.
    public var baptismDate: String?
    /// `confirmation_date` / `received_into_church_date` (extended
    /// layouts) — the DEFINING date on confirmation and nonconformist
    /// received-into-church entries, which may carry no baptism date.
    public var confirmationDate: String?
    public var receivedIntoChurchDate: String?
    /// `private_baptism`.
    public var isPrivate: Bool?
    /// `father_*` — incl. occupation/abode/place/county.
    public var father: FreeREGPerson?
    /// `mother_*` + the prior-to-marriage context.
    public var mother: FreeREGMother?
    public var witnesses: [FreeREGWitness]

    public init(
        child: FreeREGPerson,
        birthDate: String? = nil, baptismDate: String? = nil,
        confirmationDate: String? = nil, receivedIntoChurchDate: String? = nil,
        isPrivate: Bool? = nil,
        father: FreeREGPerson? = nil, mother: FreeREGMother? = nil,
        witnesses: [FreeREGWitness] = []
    ) {
        self.child = child
        self.birthDate = birthDate
        self.baptismDate = baptismDate
        self.confirmationDate = confirmationDate
        self.receivedIntoChurchDate = receivedIntoChurchDate
        self.isPrivate = isPrivate
        self.father = father
        self.mother = mother
        self.witnesses = witnesses
    }
}

/// The mother on a baptism — her person fields plus the prior-to-marriage
/// context MyopicVicar transcribes. `placePriorToMarriage` is a direct
/// maiden-origin lead (where she lived before marrying).
public nonisolated struct FreeREGMother: Codable, Sendable, Equatable {
    public var person: FreeREGPerson
    /// `mother_condition_prior_to_marriage`.
    public var conditionPriorToMarriage: String?
    /// `mother_place_prior_to_marriage`.
    public var placePriorToMarriage: String?
    /// `mother_county_prior_to_marriage`.
    public var countyPriorToMarriage: String?

    public init(
        person: FreeREGPerson,
        conditionPriorToMarriage: String? = nil,
        placePriorToMarriage: String? = nil,
        countyPriorToMarriage: String? = nil
    ) {
        self.person = person
        self.conditionPriorToMarriage = conditionPriorToMarriage
        self.placePriorToMarriage = placePriorToMarriage
        self.countyPriorToMarriage = countyPriorToMarriage
    }
}

/// A marriage entry — TWO generations from one record: groom + bride each
/// with their own parish/condition/occupation, plus BOTH sets of parents.
public nonisolated struct FreeREGMarriage: Codable, Sendable, Equatable {
    /// `groom_*` (incl. age/condition/occupation/abode).
    public var groom: FreeREGPerson
    /// `bride_*`.
    public var bride: FreeREGPerson
    /// `groom_parish` / `bride_parish` — home parish when it differs from
    /// the marriage parish (a residence lead).
    public var groomParish: String?
    public var brideParish: String?
    /// `groom_father_*` / `groom_mother_*` / `bride_father_*` / `bride_mother_*`
    /// — parentage for BOTH spouses (incl. fathers' occupations).
    public var groomFather: FreeREGPerson?
    public var groomMother: FreeREGPerson?
    public var brideFather: FreeREGPerson?
    public var brideMother: FreeREGPerson?
    /// `marriage_date` (and `contract_date` for pre-1754 contracts/banns).
    public var marriageDate: String?
    public var contractDate: String?
    /// `marriage_by_licence` — licence vs banns.
    public var byLicence: Bool?
    /// `marriage_by` — officiant / rite as transcribed.
    public var marriageBy: String?
    /// `groom_marked` / `bride_marked` (extended layouts) — signed the
    /// register with a MARK rather than a signature; a literacy signal,
    /// as transcribed ("y"/"marked").
    public var groomMarked: String?
    public var brideMarked: String?
    /// Relatives routinely witness marriages — a collateral-kin signal
    /// (CONNECTOR_AUDIT FT-21).
    public var witnesses: [FreeREGWitness]

    public init(
        groom: FreeREGPerson, bride: FreeREGPerson,
        groomParish: String? = nil, brideParish: String? = nil,
        groomFather: FreeREGPerson? = nil, groomMother: FreeREGPerson? = nil,
        brideFather: FreeREGPerson? = nil, brideMother: FreeREGPerson? = nil,
        marriageDate: String? = nil, contractDate: String? = nil,
        byLicence: Bool? = nil, marriageBy: String? = nil,
        groomMarked: String? = nil, brideMarked: String? = nil,
        witnesses: [FreeREGWitness] = []
    ) {
        self.groom = groom
        self.bride = bride
        self.groomParish = groomParish
        self.brideParish = brideParish
        self.groomFather = groomFather
        self.groomMother = groomMother
        self.brideFather = brideFather
        self.brideMother = brideMother
        self.marriageDate = marriageDate
        self.contractDate = contractDate
        self.byLicence = byLicence
        self.marriageBy = marriageBy
        self.groomMarked = groomMarked
        self.brideMarked = brideMarked
        self.witnesses = witnesses
    }
}

/// A burial entry. A burial often identifies the deceased ONLY through a
/// relative ("Mary, dau of John Smith") — `relationship` + `relative` keep
/// that distinction typed instead of mis-reading the relative as the
/// deceased's own identity.
public nonisolated struct FreeREGBurial: Codable, Sendable, Equatable {
    /// `burial_person_*` / `person_*` — the deceased (age via `person_age`).
    public var deceased: FreeREGPerson
    public var burialDate: String?
    /// `death_date` — distinct from the burial date.
    public var deathDate: String?
    public var causeOfDeath: String?
    public var placeOfDeath: String?
    /// `relationship` — the deceased's relation to the named relative(s)
    /// ("dau of", "wife of", "son of John and Jane").
    public var relationship: String?
    /// The first named relative (NOT the deceased) — the male-relative
    /// block when present, else the female/generic block. A burial naming
    /// BOTH ("son of John and Jane") carries the other in
    /// `secondRelative`; the two blocks are never welded into one person
    /// (verify finding 2026-07-29: mixing prefix hits produced a chimera
    /// "John Brown" from John's forename + Jane Brown's surname).
    public var relative: FreeREGPerson?
    /// The OTHER named relative when the entry names two (typically the
    /// mother on a "son of John and Jane" infant burial).
    public var secondRelative: FreeREGPerson?
    /// `burial_parish` — when the burial was recorded away from home.
    public var burialParish: String?
    public var burialLocationInformation: String?
    public var memorialInformation: String?
    public var consecratedGround: String?

    public init(
        deceased: FreeREGPerson,
        burialDate: String? = nil, deathDate: String? = nil,
        causeOfDeath: String? = nil, placeOfDeath: String? = nil,
        relationship: String? = nil, relative: FreeREGPerson? = nil,
        secondRelative: FreeREGPerson? = nil,
        burialParish: String? = nil,
        burialLocationInformation: String? = nil,
        memorialInformation: String? = nil,
        consecratedGround: String? = nil
    ) {
        self.deceased = deceased
        self.burialDate = burialDate
        self.deathDate = deathDate
        self.causeOfDeath = causeOfDeath
        self.placeOfDeath = placeOfDeath
        self.relationship = relationship
        self.relative = relative
        self.secondRelative = secondRelative
        self.burialParish = burialParish
        self.burialLocationInformation = burialLocationInformation
        self.memorialInformation = memorialInformation
        self.consecratedGround = consecratedGround
    }
}

/// Register/archive reference — where the original page lives.
/// `imageFileName` is a media lead (SOURCE_MEDIA_SPEC).
public nonisolated struct FreeREGRegisterReference: Codable, Sendable, Equatable {
    public var register: String?
    /// `register_type` — CofE / Nonconformist / RC etc.; a tiering +
    /// denomination signal.
    public var registerType: String?
    public var registerEntryNumber: String?
    public var film: String?
    public var filmNumber: String?
    public var imageFileName: String?

    public init(
        register: String? = nil, registerType: String? = nil,
        registerEntryNumber: String? = nil,
        film: String? = nil, filmNumber: String? = nil,
        imageFileName: String? = nil
    ) {
        self.register = register
        self.registerType = registerType
        self.registerEntryNumber = registerEntryNumber
        self.film = film
        self.filmNumber = filmNumber
        self.imageFileName = imageFileName
    }

    public var isEmpty: Bool {
        [register, registerType, registerEntryNumber, film, filmNumber, imageFileName]
            .allSatisfy { ($0 ?? "").isEmpty }
    }
}

/// Transcriber attribution — `credit`/`transcribed_by` MUST surface in
/// citations (the transcribers' work is the source's whole value).
public nonisolated struct FreeREGProvenance: Codable, Sendable, Equatable {
    public var transcribedBy: String?
    public var credit: String?
    public var lineID: String?

    public init(transcribedBy: String? = nil, credit: String? = nil, lineID: String? = nil) {
        self.transcribedBy = transcribedBy
        self.credit = credit
        self.lineID = lineID
    }

    public var isEmpty: Bool {
        [transcribedBy, credit, lineID].allSatisfy { ($0 ?? "").isEmpty }
    }
}

public nonisolated struct FreeREGNotes: Codable, Sendable, Equatable {
    public var notes: String?
    public var notesFromTranscriber: String?

    public init(notes: String? = nil, notesFromTranscriber: String? = nil) {
        self.notes = notes
        self.notesFromTranscriber = notesFromTranscriber
    }

    public var isEmpty: Bool {
        [notes, notesFromTranscriber].allSatisfy { ($0 ?? "").isEmpty }
    }
}
