import Foundation
import CryptoKit

/// Maps a research-pipeline `SourceRecord` onto a `LifeEvent` attached to a
/// profile. The projection is the on-ramp from research results into the
/// tree — when the user clicks "Save as lead" on a cluster in
/// `ClusterReviewView`, each constituent record is projected here and saved
/// (idempotently) as a LifeEvent.
///
/// Records that don't map to a LifeEvent return nil:
///   - birth / death — those facts live directly on `Profile`.
///   - marriage — lives on `Relationship`.
///   - pedigree — a navigation/discovery aid, not a fact about the subject.
///
/// IDs are deterministic from (profileID, sourceRecordID) so re-running this
/// path doesn't duplicate the row. `ProjectDatabase.addLifeEventIfAbsent`
/// (INSERT OR IGNORE) is the matching write side.
nonisolated extension SourceRecord {

    /// A citation source carrying a burial record's memorial URL (its stored
    /// `detailURL`, else built from a Find a Grave `memorialID`), so the
    /// projected life event links back to the source.
    private static func burialSource(_ r: BurialRecord) -> [FieldSource] {
        let url = r.common.detailURL ?? r.memorialID.map { "https://www.findagrave.com/memorial/\($0)" }
        guard let url, !url.isEmpty else { return [] }
        return [FieldSource(
            origin: SourceOrigin(identifier: r.common.sourceID),
            raw: r.common.sourceID,
            addedAt: Date(),
            citation: Citation(url: url),
            quality: nil, confidence: nil)]
    }

    /// A citation source carrying a census record's detail URL, so the projected
    /// census life event links back to its source. Also lets the census-household
    /// proposal recognise an applied census by matching this URL (owner report
    /// 2026-08-05: an applied childhood census offered no household load because
    /// its projected life event was un-cited).
    private static func censusSource(_ r: CensusRecord) -> [FieldSource] {
        guard let url = r.common.detailURL, !url.isEmpty else { return [] }
        return [FieldSource(
            origin: SourceOrigin(identifier: r.common.sourceID),
            raw: r.common.sourceID,
            addedAt: Date(),
            citation: Citation(url: url),
            quality: nil, confidence: nil)]
    }

    /// #29 — the parish twin of `censusSource`: the projected baptism/burial
    /// event carries the register's URL on the event row itself. Without it
    /// the applied event read as uncited while the URL sat only in the
    /// profile-level `field_sources` (owner dogfood 2026-08-24: John
    /// Wheeldon jr's Cromford 1848 baptism applied with `sources: []`).
    private static func recordSource(_ common: RecordCommon) -> [FieldSource] {
        guard let url = common.detailURL, !url.isEmpty else { return [] }
        return [FieldSource(
            origin: SourceOrigin(identifier: common.sourceID),
            raw: common.sourceID,
            addedAt: Date(),
            citation: Citation(url: url),
            quality: nil, confidence: nil)]
    }

    func projectToLifeEvent(profileID: String) -> LifeEvent? {
        switch self {
        case .birth, .death, .marriage, .pedigree:
            return nil

        case .burial(let r):
            return LifeEvent(
                id: Self.deterministicID(profileID: profileID, sourceRecordID: r.common.id),
                profileID: profileID,
                type: .burial,
                date: r.deathDate.flatMap { GenealogicalDate.parsePreview($0).parsed }
                    ?? r.deathYear.map(yearOnlyDate),
                location: r.burialLocation,
                description: r.bio,
                details: .burial(BurialDetails(
                    cemetery: r.cemetery,
                    // T1-11 — FindAGrave parses the plot into rawFields;
                    // don't drop it at the projection layer.
                    plot: r.common.rawFields["plot"].flatMap(\.nilIfEmptyProjection),
                    graveRef: nil,
                    inscription: r.inscription,
                    isVeteran: r.isVeteran
                )),
                // Carry the memorial URL onto the life event so it shows a
                // "View source" link (previously the projection dropped it).
                sources: Self.burialSource(r)
            )

        case .military(let r):
            // CWGC / Find a Grave veterans return a military record. The
            // event date is date of death (when the soldier died in
            // service). LifeEventType.militaryService is a duration event
            // historically — but for KIA records the end date is the only
            // meaningful date anyway.
            return LifeEvent(
                id: Self.deterministicID(profileID: profileID, sourceRecordID: r.common.id),
                profileID: profileID,
                type: .militaryService,
                date: r.dateOfDeath.flatMap { GenealogicalDate.parsePreview($0).parsed }
                    ?? r.deathYear.map(yearOnlyDate),
                location: r.cemetery,
                description: r.additionalInfo,
                details: .military(MilitaryDetails(
                    rank: r.rank,
                    regiment: r.regiment,
                    unit: r.unit,
                    serviceNumber: r.serviceNumber,
                    // T1-11 — CWGC parses country of service and honours
                    // into rawFields; the schema fields exist, so carry
                    // them instead of constructing nil with the values
                    // in hand.
                    countryOfService: r.common.rawFields["country_of_service"].flatMap(\.nilIfEmptyProjection),
                    cemetery: r.cemetery,
                    graveRef: r.graveRef,
                    honours: r.common.rawFields["honours"].flatMap(\.nilIfEmptyProjection)
                ))
            )

        case .probate(let r):
            return LifeEvent(
                id: Self.deterministicID(profileID: profileID, sourceRecordID: r.common.id),
                profileID: profileID,
                type: .probate,
                date: r.probateDate.flatMap { GenealogicalDate.parsePreview($0).parsed },
                location: r.address,
                description: nil,
                details: .probate(ProbateDetails(
                    grantType: r.grantType,
                    registry: r.registry,
                    probateNumber: r.probateNumber,
                    address: r.address,
                    ageAtDeath: r.ageAtDeath
                )),
                // EV16 (2026-08-26) — this primary was ALSO built with no
                // `sources:` argument, so it defaulted to []. Left alone it would
                // now read UNCITED directly above the cited residence its own
                // `probateDerivedEvents` emits from the same grant — an
                // incoherence this pass would itself have created. Same helper as
                // the parish primary (#29); the calendar entry's URL is the
                // grant's provenance. (`.military` is the remaining uncited
                // primary — out of EV16's scope, reported not fixed.)
                sources: Self.recordSource(r.common)
            )

        case .census(let r):
            return LifeEvent(
                id: Self.deterministicID(profileID: profileID, sourceRecordID: r.common.id),
                profileID: profileID,
                type: .census,
                date: yearOnlyDate(r.censusYear),
                location: r.address ?? r.parish,
                description: r.occupation,
                details: .census(CensusDetails(
                    occupation: r.occupation,
                    address: r.address,
                    district: r.district,
                    parish: r.parish,
                    household: r.household ?? []
                )),
                sources: Self.censusSource(r)
            )

        case .parish(let r):
            // Parish registers cover baptism / marriage / burial events.
            // Marriage parish records belong on Relationship, not LifeEvent —
            // bail in that case so we don't double-record. Baptism and
            // burial map to their own LifeEventType.
            let type: LifeEventType?
            switch r.eventType?.lowercased() {
            case "baptism", "christening", "ba", "ch": type = .baptism
            case "burial", "bu": type = .burial
            case "marriage", "ma": type = nil
            default: type = .other
            }
            guard let type else { return nil }
            // PARISH_ABSORPTION_SPEC §6 — a burial entry's cause/place of death
            // is genuine content the flat projection dropped; carry it in the
            // event description rather than losing it to the typed payload.
            // #29 — a baptism's parents (and the father's occupation and the
            // register's recorded birth date) are equally genuine content:
            // "son of John Wheeldon (hatter) and Ruth; born 9 Sep 1848".
            let description: String? = {
                switch r.detail?.event {
                case .burial(let b)?:
                    return [b.causeOfDeath, b.placeOfDeath]
                        .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "; ")
                        .nilIfEmptyProjection
                case .baptism(let b)?:
                    var parts: [String] = []
                    let father = [
                        r.fatherName ?? b.father?.displayName,
                        b.father?.occupation.map { "(\($0.lowercased()))" },
                    ].compactMap { $0 }.joined(separator: " ")
                    let mother = r.motherName ?? b.mother?.person.displayName
                    let parents = [father.nilIfEmptyProjection, mother]
                        .compactMap { $0 }.joined(separator: " and ")
                    if !parents.isEmpty { parts.append("child of \(parents)") }
                    if let born = b.birthDate, !born.isEmpty { parts.append("born \(born)") }
                    return parts.joined(separator: "; ").nilIfEmptyProjection
                default:
                    // Flat-only record (detail not yet fetched): the parents
                    // may still ride the flat projection.
                    guard type == .baptism else { return nil }
                    let parents = [r.fatherName, r.motherName]
                        .compactMap { $0?.nilIfEmptyProjection }
                        .joined(separator: " and ")
                    return parents.isEmpty ? nil : "child of \(parents)"
                }
            }()
            return LifeEvent(
                id: Self.deterministicID(profileID: profileID, sourceRecordID: r.common.id),
                profileID: profileID,
                type: type,
                date: r.eventDate.flatMap { GenealogicalDate.parsePreview($0).parsed }
                    ?? r.eventYear.map(yearOnlyDate),
                location: [r.parish, r.county].compactMap { $0 }.joined(separator: ", ").nilIfEmptyProjection,
                description: description,
                details: nil,
                sources: Self.recordSource(r.common)
            )
        }
    }

    /// EVIDENCE_ABSORPTION_SPEC Change 2 — every typed LifeEvent a record
    /// implies, not just one catch-all entry. A census spawns its `.census`
    /// event (unchanged) PLUS a `.occupation` event and a `.residence` event
    /// when it names an occupation / address, so those first-class event
    /// types finally get populated from records instead of the nugget staying
    /// buried in census details. All other records return their single event
    /// (or none), exactly as before. Idempotent: derived events carry a
    /// discriminated deterministic ID so they never collide with the primary.
    func projectToLifeEvents(profileID: String) -> [LifeEvent] {
        var events = projectToLifeEvent(profileID: profileID).map { [$0] } ?? []
        switch self {
        case .census(let r):
            events.append(contentsOf: Self.censusDerivedEvents(r, profileID: profileID))
        case .probate(let r):
            // Change 3 — a probate grant's address is the deceased's last
            // residence ("late of …"); surface it on the residence axis, not
            // only buried in the probate event's details.
            events.append(contentsOf: Self.probateDerivedEvents(r, profileID: profileID))
        case .parish(let r):
            // PARISH_ABSORPTION_SPEC §6 — a marriage names the principal's
            // occupation and abode; fan them onto the occupation/residence
            // axes, mirroring census.
            events.append(contentsOf: Self.parishDerivedEvents(r, profileID: profileID))
        default:
            break
        }
        return events
    }

    /// The off-agenda facts a parish MARRIAGE volunteers about its principal —
    /// occupation and abode — each routed to its own typed event, dated to the
    /// marriage year. The subject is the row principal (name-resolved), so a
    /// bride-subject record contributes the bride's block, not the groom's.
    /// Empty fields yield no event. (PARISH_ABSORPTION_SPEC §6.)
    private static func parishDerivedEvents(_ r: ParishRecord, profileID: String) -> [LifeEvent] {
        guard case .marriage(let m)? = r.detail?.event else { return [] }
        let role = m.role(forGiven: r.common.givenName, surname: r.common.surname, gender: nil)
        let p = m.principal(as: role)
        guard let year = r.eventYear
            ?? m.marriageDate.flatMap({ GenealogicalDate.parsePreview($0).parsed?.bestYear })
        else { return [] }
        let date = yearOnlyDate(year)
        // EV16 (2026-08-26) — the derived events are as evidenced as the primary:
        // they restate fields off the SAME register row. Built without a
        // `sources:` argument they defaulted to [] and rendered with no citation
        // badge beside the fully-cited parish event carrying the identical fact.
        // Same helper the primary uses (#29), so the derived rows carry the
        // register URL verbatim — no second-guessing the tier, which stays
        // URL-derived via SourceTierRegistry.
        let sources = recordSource(r.common)
        var out: [LifeEvent] = []
        if let occupation = p.occupation?.trimmingCharacters(in: .whitespaces), !occupation.isEmpty {
            out.append(LifeEvent(
                id: deterministicID(profileID: profileID, sourceRecordID: r.common.id, discriminator: "occupation"),
                profileID: profileID,
                type: .occupation,
                date: date,
                location: p.abode?.nilIfEmptyProjection ?? r.parish,
                description: occupation,
                details: nil,
                sources: sources
            ))
        }
        if let abode = p.abode?.trimmingCharacters(in: .whitespaces), !abode.isEmpty {
            out.append(LifeEvent(
                id: deterministicID(profileID: profileID, sourceRecordID: r.common.id, discriminator: "residence"),
                profileID: profileID,
                type: .residence,
                // A marriage abode is attested for the wedding only — close the
                // window so it can't shadow the subject's later life (same
                // rationale as the census-derived residence).
                date: date,
                endDate: date,
                location: abode,
                description: nil,
                details: nil,
                sources: sources
            ))
        }
        return out
    }

    /// The off-agenda facts a census volunteers, each routed to its own typed
    /// event. Dated to the census year; located at the household address (or
    /// parish) so the occupation reads with its place. Empty fields yield no
    /// event — we never manufacture a blank occupation/residence row.
    private static func censusDerivedEvents(_ r: CensusRecord, profileID: String) -> [LifeEvent] {
        let date = yearOnlyDate(r.censusYear)
        // EV16 (2026-08-26) — the census fan-out shipped without carrying the
        // record's citation onto the derived rows, so the occupation and
        // residence read UNCITED next to the fully-cited `.census` event that
        // states the identical fact. Observed live on William Gladwin: life
        // events 8DEBEAC0 ("Sawyer", 1881, Handsworth) and B0A6E31A ("Wood
        // Sawyer", 1891, Beighton) both held `sources: []`, plus four other
        // profiles. Same helper as the primary — one household page, one URL.
        let sources = censusSource(r)
        var out: [LifeEvent] = []
        if let occupation = r.occupation?.trimmingCharacters(in: .whitespaces), !occupation.isEmpty {
            out.append(LifeEvent(
                id: deterministicID(profileID: profileID, sourceRecordID: r.common.id, discriminator: "occupation"),
                profileID: profileID,
                type: .occupation,
                date: date,
                location: r.address ?? r.parish,
                description: occupation,
                details: nil,
                sources: sources
            ))
        }
        if let address = r.address?.trimmingCharacters(in: .whitespaces), !address.isEmpty {
            out.append(LifeEvent(
                id: deterministicID(profileID: profileID, sourceRecordID: r.common.id, discriminator: "residence"),
                profileID: profileID,
                type: .residence,
                date: date,
                // A census address is attested for that census year ONLY —
                // close the window so the research residence axes
                // (ResearchSubject.residenceAxes) don't treat it as
                // open-ended-forward and let a one-night address shadow the
                // subject's whole later life.
                endDate: date,
                location: address,
                description: nil,
                details: nil,
                sources: sources
            ))
        }
        return out
    }

    /// Change 3 — the residence a probate grant's address attests. Dated to
    /// the death year (the residence held at death), falling back to the
    /// probate date. Empty address → no event.
    private static func probateDerivedEvents(_ r: ProbateRecord, profileID: String) -> [LifeEvent] {
        guard let address = r.address?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { return [] }
        let date = r.deathYear.map(yearOnlyDate)
            ?? r.probateDate.flatMap { GenealogicalDate.parsePreview($0).parsed }
        return [LifeEvent(
            id: deterministicID(profileID: profileID, sourceRecordID: r.common.id, discriminator: "residence"),
            profileID: profileID,
            type: .residence,
            date: date,
            // The residence held AT DEATH — close the window (see the
            // census-derived residence above for the rationale).
            endDate: date,
            location: address,
            description: nil,
            details: nil,
            // EV16 (2026-08-26) — the "late of …" residence is an assertion of
            // the probate calendar entry, so it carries that entry's URL rather
            // than defaulting to `sources: []`. Same helper as the primary
            // `.probate` event, which this pass also cites.
            sources: recordSource(r.common)
        )]
    }

    /// Stable UUID derived from (profileID, sourceRecordID). Same record
    /// projected onto the same profile always produces the same UUID, so
    /// `INSERT OR IGNORE` makes the projection idempotent. Uses a SHA-256
    /// hash truncated to 16 bytes — sufficient uniqueness across the lifetime
    /// of a tree, and stable across app launches.
    /// Discriminated variant for the derived fan-out events (Change 2): folds
    /// an event-kind suffix into the hash input so a census's occupation and
    /// residence events get distinct, stable IDs that never collide with the
    /// bare-keyed primary `.census` event.
    static func deterministicID(profileID: String, sourceRecordID: String, discriminator: String) -> UUID {
        deterministicID(profileID: profileID, sourceRecordID: "\(sourceRecordID)#\(discriminator)")
    }

    static func deterministicID(profileID: String, sourceRecordID: String) -> UUID {
        let input = "\(profileID)|\(sourceRecordID)"
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 4122 v5-ish marker bits so the UUID is well-formed.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Year-only date helper. The pipeline often only knows the year of a
/// burial / census / probate event; we build a minimal `GenealogicalDate`
/// so the timeline can still sort the event by year.
nonisolated private func yearOnlyDate(_ year: Int) -> GenealogicalDate {
    GenealogicalDate(
        original: String(year),
        earliest: year, latest: year,
        isApproximate: false,
        qualifier: .yearOnly
    )
}

nonisolated private extension String {
    var nilIfEmptyProjection: String? { isEmpty ? nil : self }
}
