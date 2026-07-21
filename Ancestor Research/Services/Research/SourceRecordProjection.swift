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
                ))
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
                ))
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
                ))
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
            return LifeEvent(
                id: Self.deterministicID(profileID: profileID, sourceRecordID: r.common.id),
                profileID: profileID,
                type: type,
                date: r.eventDate.flatMap { GenealogicalDate.parsePreview($0).parsed }
                    ?? r.eventYear.map(yearOnlyDate),
                location: [r.parish, r.county].compactMap { $0 }.joined(separator: ", ").nilIfEmptyProjection,
                description: nil,
                details: nil
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
        default:
            break
        }
        return events
    }

    /// The off-agenda facts a census volunteers, each routed to its own typed
    /// event. Dated to the census year; located at the household address (or
    /// parish) so the occupation reads with its place. Empty fields yield no
    /// event — we never manufacture a blank occupation/residence row.
    private static func censusDerivedEvents(_ r: CensusRecord, profileID: String) -> [LifeEvent] {
        let date = yearOnlyDate(r.censusYear)
        var out: [LifeEvent] = []
        if let occupation = r.occupation?.trimmingCharacters(in: .whitespaces), !occupation.isEmpty {
            out.append(LifeEvent(
                id: deterministicID(profileID: profileID, sourceRecordID: r.common.id, discriminator: "occupation"),
                profileID: profileID,
                type: .occupation,
                date: date,
                location: r.address ?? r.parish,
                description: occupation,
                details: nil
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
                details: nil
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
            details: nil
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
