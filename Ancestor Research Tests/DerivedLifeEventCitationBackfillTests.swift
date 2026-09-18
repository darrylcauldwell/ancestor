import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// EV16 backfill (2026-08-26). The construction fix (`b5c8165`) is write-only:
/// every derived life event ALREADY in a tree still holds `sources: []`, so an
/// occupation the census proves sits uncited next to the fully-cited census
/// event stating the identical fact.
///
/// The repair is a preimage proof, not a similarity match. A projected event's
/// id is `SHA256(profileID | sourceRecordID [#discriminator])`, so re-deriving
/// that id from a record still in the database and hitting the persisted row
/// EXHIBITS the preimage — the row was written by that record. It writes only
/// what `projectToLifeEvents` produces today, so a repaired row is identical
/// to a fresh apply, and a record with no URL heals nothing.
///
/// Half of these tests exist to pin what it must REFUSE. A guessed citation is
/// manufactured evidence and is strictly worse than a blank field.
///
/// Review F01 (2026-08-26): that preimage argument holds for a record STORED in
/// `evidence_records`, but not for pass B's synthesised member records —
/// `CensusBackfill.memberRecord` mints its id from `sourceID + member name +
/// census year`, so two unrelated households naming a namesake hash to the same
/// event id. Pass B is therefore additionally pinned here: every id-matching
/// household registers as a rival even when it has no URL to offer, and a
/// household may only WRITE onto profiles its own subject is linked to — the
/// sole edge `absorbCensusForRelative` can cross — while keeping its veto
/// everywhere. `aURLLessRivalHouseholdBlocksTheRepairItCannotItselfMake`,
/// `aHouseholdWhoseSubjectIsNotARelativeCannotRepairTheRow` and
/// `anIneligibleHouseholdStillVetoesARepairItCouldNotMake` are the rows that
/// would otherwise have been stamped with a stranger's census page;
/// `aURLLessIneligibleRivalStillVetoesAnEligibleRepair` (2026-08-27) is their
/// intersection and fails under EITHER half of the fix taken alone. Its
/// complement is `twoCopiesOfOneHouseholdCitingTheSameURLAgreeAndRepair` —
/// identical provenance must read as agreement, or the ledger refuses most of
/// what the backfill exists to repair.
struct DerivedLifeEventCitationBackfillTests {

    // MARK: - Scaffolding

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        return db
    }

    private func save(_ record: SourceRecord, on profileID: String, db: ProjectDatabase) throws {
        try db.saveEvidence(
            profileID: profileID,
            scored: ScoredRecord(id: record.id, record: record, verdict: .fact,
                                 gates: [], summary: ""),
            citationFull: "test", citationURL: record.common.detailURL)
    }

    /// Write the PRE-FIX state: the projection at HEAD would cite it, so the
    /// uncited row has to be forced.
    private func writeUncited(_ event: LifeEvent, db: ProjectDatabase) throws {
        var bare = event
        bare.sources = []
        _ = try db.addLifeEventIfAbsent(bare)
    }

    private func stored(_ id: UUID, profileID: String, db: ProjectDatabase) throws -> LifeEvent {
        let events = try db.loadLifeEvents(profileID: profileID)
        return try #require(events.first { $0.id == id })
    }

    /// Review F01 (2026-08-26): a household is only offered to profiles that
    /// are graph NEIGHBOURS of its own subject, because
    /// `CensusBackfill.proposals`/`.citations`/`.corroborations` only ever
    /// propose `linkedRelatives(of: subjectID)` and `absorbCensusForRelative`
    /// is the only thing that writes those rows. So every household test needs
    /// the edge the absorb path would have crossed to actually exist.
    private func makeFamily(_ ids: [String], parents: [(String, String)],
                            db: ProjectDatabase) throws {
        let profiles = ids.map {
            Profile(id: $0, lastName: "Gladwin",
                    attributes: PersonAttributes(nameStatus: .placeholder,
                                                 lifeStatus: .normal, privacy: .normal),
                    isDeleted: false, sources: [:], disputes: [:])
        }
        let edges = parents.map { parent, child in
            Relationship(id: UUID(), from: parent, to: child,
                         type: .parent, role: .unspecified, subtype: .biological,
                         marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        }
        _ = try db.addFamily(profiles: profiles, relationships: edges, source: .manualMemory)
    }

    /// The uncited row the absorb path leaves on a household member: keyed by
    /// the SYNTHESISED member-record id, which carries no household identity.
    @discardableResult
    private func writeUncitedMemberEvent(
        profileID: String, memberName: String, year: Int = 1881,
        type: LifeEventType, location: String, description: String?,
        db: ProjectDatabase
    ) throws -> UUID {
        let memberID = "field-researcher_hh_\(memberName.replacingOccurrences(of: " ", with: "_"))_\(year)"
        let eventID = SourceRecord.deterministicID(
            profileID: profileID, sourceRecordID: memberID,
            discriminator: type == .occupation ? "occupation" : "residence")
        try writeUncited(LifeEvent(
            id: eventID, profileID: profileID, type: type,
            date: GenealogicalDate(original: String(year), earliest: year, latest: year,
                                   isApproximate: false, qualifier: .yearOnly),
            location: location, description: description), db: db)
        return eventID
    }

    private func urls(_ event: LifeEvent) -> [String] {
        event.sources.compactMap { $0.citation?.url }
    }

    // MARK: - Fixtures

    private let censusURL = "https://www.freecen.org.uk/search_records/6a2f/gladwin-1881"
    private let arkURL = "https://www.familysearch.org/ark:/61903/1:1:Q27Y-2JHF"
    private let registerURL = "https://www.freereg.org.uk/search_records/682f9727/x"
    private let probateURL = "https://probatesearch.service.gov.uk/search-results?grant=1902-4471"

    private func census(detailURL: String?) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(
                id: "freecen_gladwin_1881", sourceID: "freecen",
                name: "William Gladwin", surname: "Gladwin", givenName: "William",
                detailURL: detailURL, rawFields: [:]),
            censusYear: 1881,
            occupation: "Sawyer", address: "12 Bramley Row", parish: "Handsworth"))
    }

    /// Emma's own 1881 household — the shape the filed defect has. William is
    /// a roster row on HER census; nothing writes an evidence row on his
    /// profile, so his occupation event is reachable only through her page.
    private func householdCensus(id: String, detailURL: String?,
                                 head: String = "Emma Gladwin",
                                 headRole: String = "Head",
                                 occupation: String = "Coal Carve Mender",
                                 address: String = "12 Bramley Row") -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(
                id: id, sourceID: "field-researcher",
                name: head, surname: "Gladwin",
                givenName: head.split(separator: " ").first.map(String.init),
                detailURL: detailURL, rawFields: [:]),
            censusYear: 1881, address: address, parish: "Handsworth",
            household: [
                HouseholdMember(name: head, relationship: headRole, age: 43),
                HouseholdMember(name: "William Gladwin", relationship: "Son", age: 15,
                                occupation: occupation),
            ]))
    }

    private func parishMarriage(detailURL: String?) -> SourceRecord {
        let marriage = FreeREGMarriage(
            groom: FreeREGPerson(forename: "Ernest", surname: "Cauldwell", age: "26",
                                 condition: "bachelor", occupation: "Collier",
                                 abode: "Loscoe, Heanor"),
            bride: FreeREGPerson(forename: "Mary", surname: "Ward", age: "25",
                                 condition: "spinster"),
            marriageDate: "30 Jan 1915")
        return .parish(ParishRecord(
            common: RecordCommon(
                id: "freereg_cauldwell_ward_1915", sourceID: "freereg",
                name: "Ernest Cauldwell", surname: "Cauldwell", givenName: "Ernest",
                detailURL: detailURL, rawFields: [:]),
            eventType: "marriage", eventDate: "30 Jan 1915", eventYear: 1915,
            parish: "Kirk Ireton", county: "Derbyshire",
            detail: FreeREGDetail(event: .marriage(marriage), churchName: "Holy Trinity")))
    }

    private func probate(detailURL: String?) -> SourceRecord {
        .probate(ProbateRecord(
            common: RecordCommon(
                id: "probate_gladwin_1902", sourceID: "probate",
                name: "William Gladwin", surname: "Gladwin", givenName: "William",
                detailURL: detailURL, rawFields: [:]),
            deathDate: "3 Feb 1902", deathYear: 1902,
            probateDate: "14 Mar 1902",
            address: "12 Bramley Row, Handsworth",
            grantType: "Probate", registry: "Derby"))
    }

    // MARK: - What it repairs

    @Test func censusDerivedOccupationRegainsItsOwnCensusCitation() throws {
        let db = try makeDB()
        let record = census(detailURL: censusURL)
        try save(record, on: "p", db: db)
        let occupation = try #require(
            record.projectToLifeEvents(profileID: "p").first { $0.type == .occupation })
        try writeUncited(occupation, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 1)
        let healed = try stored(occupation.id, profileID: "p", db: db)
        #expect(urls(healed) == [censusURL])
        #expect(healed.sources.count == 1)
        #expect(healed.sources.first?.origin.identifier == "freecen")
    }

    /// The regression for the FILED row. The parent evidence lives on ANOTHER
    /// profile: a backfill scoped to each profile's own `evidence_records`
    /// would leave this exactly as broken as it was found.
    @Test func aHouseholdMemberEventIsRepairedFromTheSubjectsCensus() throws {
        let db = try makeDB()
        try makeFamily(["emma", "will"], parents: [("emma", "will")], db: db)
        try save(householdCensus(id: "fr_emma_1881", detailURL: arkURL), on: "emma", db: db)

        let eventID = try writeUncitedMemberEvent(
            profileID: "will", memberName: "William Gladwin", type: .occupation,
            location: "12 Bramley Row", description: "Coal Carve Mender", db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 1)
        #expect(urls(try stored(eventID, profileID: "will", db: db)) == [arkURL])
    }

    @Test func parishAndProbateDerivedEventsAreRepairedToo() throws {
        let db = try makeDB()
        let parish = parishMarriage(detailURL: registerURL)
        let grant = probate(detailURL: probateURL)
        try save(parish, on: "p", db: db)
        try save(grant, on: "p", db: db)

        // A parish MARRIAGE has no primary event at all — its occupation and
        // abode rows are the only events it produces.
        let abode = try #require(
            parish.projectToLifeEvents(profileID: "p").first { $0.type == .residence })
        let lateOf = try #require(
            grant.projectToLifeEvents(profileID: "p").first { $0.type == .residence })
        try writeUncited(abode, db: db)
        try writeUncited(lateOf, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 2)
        #expect(urls(try stored(abode.id, profileID: "p", db: db)) == [registerURL])
        #expect(urls(try stored(lateOf.id, profileID: "p", db: db)) == [probateURL])
    }

    /// `PlaceTextCorrection` rewrites `location` in place, so a corrected
    /// place must not be mistaken for a hand-edited fact.
    @Test func aCorrectedPlaceDoesNotBlockTheRepair() throws {
        let db = try makeDB()
        let record = census(detailURL: censusURL)
        try save(record, on: "p", db: db)
        var occupation = try #require(
            record.projectToLifeEvents(profileID: "p").first { $0.type == .occupation })
        occupation.location = "Handsworth, Yorkshire"
        try writeUncited(occupation, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 1)
        #expect(urls(try stored(occupation.id, profileID: "p", db: db)) == [censusURL])
    }

    @Test func theBackfillIsIdempotent() throws {
        let db = try makeDB()
        let record = census(detailURL: censusURL)
        try save(record, on: "p", db: db)
        let occupation = try #require(
            record.projectToLifeEvents(profileID: "p").first { $0.type == .occupation })
        try writeUncited(occupation, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 1)
        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(occupation.id, profileID: "p", db: db).sources.count == 1,
                "a second pass must not stack a duplicate citation")
    }

    // MARK: - What it must refuse

    @Test func anEventThatAlreadyCarriesACitationIsNeverTouched() throws {
        let db = try makeDB()
        let record = census(detailURL: censusURL)
        try save(record, on: "p", db: db)
        var occupation = try #require(
            record.projectToLifeEvents(profileID: "p").first { $0.type == .occupation })
        occupation.sources = [FieldSource(
            origin: .manualRecord, raw: "hand-entered", addedAt: Date(),
            citation: Citation(url: "https://example.org/the-users-own-source"))]
        _ = try db.addLifeEventIfAbsent(occupation)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        let untouched = try stored(occupation.id, profileID: "p", db: db)
        #expect(urls(untouched) == ["https://example.org/the-users-own-source"])
    }

    /// The never-manufacture rule: no URL on the parent record means the row
    /// stays blank. A blank field is honest.
    @Test func aRecordWithNoDetailURLLeavesTheEventUncited() throws {
        let db = try makeDB()
        let record = census(detailURL: nil)
        try save(record, on: "p", db: db)
        let occupation = try #require(
            record.projectToLifeEvents(profileID: "p").first { $0.type == .occupation })
        try writeUncited(occupation, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(occupation.id, profileID: "p", db: db).sources.isEmpty)
    }

    @Test func aHandEditedDescriptionBlocksTheRepair() throws {
        let db = try makeDB()
        let record = census(detailURL: censusURL)
        try save(record, on: "p", db: db)
        var occupation = try #require(
            record.projectToLifeEvents(profileID: "p").first { $0.type == .occupation })
        occupation.description = "Farmer"
        try writeUncited(occupation, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(occupation.id, profileID: "p", db: db).sources.isEmpty,
                "the stored value is no longer this record's fact — citing it would be a lie")
    }

    /// A GEDCOM-imported or hand-added event has a random UUID: no preimage
    /// exists, so nothing can ever prove where it came from.
    @Test func aManualLifeEventWithARandomIDIsNeverTouched() throws {
        let db = try makeDB()
        try save(census(detailURL: censusURL), on: "p", db: db)
        let manual = LifeEvent(
            id: UUID(), profileID: "p", type: .occupation,
            date: GenealogicalDate(original: "1881", earliest: 1881, latest: 1881,
                                   isApproximate: false, qualifier: .yearOnly),
            location: "Handsworth", description: "Sawyer")
        try writeUncited(manual, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(manual.id, profileID: "p", db: db).sources.isEmpty)
    }

    /// The preimage proves provenance only when it is UNIQUE. Two 1881
    /// households from the same source, each holding a "William Gladwin" doing
    /// the same work, mint the same member-record id and therefore the same
    /// event id — so the stored row genuinely could have come from either.
    /// Picking one by iteration order would manufacture a citation.
    @Test func twoRivalHouseholdsThatMintTheSameEventIDRepairNeither() throws {
        let db = try makeDB()
        // Emma's children: Will (the target) and Sarah, so BOTH households are
        // filed against a graph neighbour of Will and both genuinely reach him.
        try makeFamily(["emma", "will", "sarah"],
                       parents: [("emma", "will"), ("emma", "sarah")], db: db)
        try save(householdCensus(id: "fr_emma_1881", detailURL: arkURL,
                                 address: "12 Bramley Row"),
                 on: "emma", db: db)
        try save(householdCensus(id: "fr_sarah_1881",
                                 detailURL: "https://www.familysearch.org/ark:/61903/1:1:XXXX-YYY",
                                 head: "Sarah Gladwin",
                                 address: "4 Pump Yard"),
                 on: "sarah", db: db)

        let eventID = try writeUncitedMemberEvent(
            profileID: "will", memberName: "William Gladwin", type: .occupation,
            location: "12 Bramley Row", description: "Coal Carve Mender", db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(eventID, profileID: "will", db: db).sources.isEmpty,
                "ambiguous provenance must leave the field blank, not guess a household")
    }

    /// Review F01 (2026-08-26) — THE REGRESSION. The rival that actually
    /// authored the row was accepted with a TEXT-ONLY citation (a purchased
    /// record-office reference), so it has no `detailURL` and
    /// `censusSource` projects NO source for it. The ambiguity guard used to
    /// sit behind `!projected.sources.isEmpty`, so that rival `continue`d out
    /// before it could register as a rival at all — and the one household that
    /// DID carry a URL won uncontested and stamped a stranger's census page
    /// onto Will's row. Silently: the migration writes no transaction and no
    /// `field_change`, so the fabricated badge is the only trace.
    ///
    /// A URL-less household is still a rival claim. Neither event may heal.
    @Test func aURLLessRivalHouseholdBlocksTheRepairItCannotItselfMake() throws {
        let db = try makeDB()
        try makeFamily(["emma", "will", "sarah"],
                       parents: [("emma", "will"), ("emma", "sarah")], db: db)
        // (A) The household that authored Will's rows — text-only citation.
        try save(householdCensus(id: "fr_emma_1881", detailURL: nil,
                                 address: "12 Bramley Row"),
                 on: "emma", db: db)
        // (B) His sister's unrelated 1881 household, which happens to list a
        //     namesake "William Gladwin" — and carries a real URL.
        try save(householdCensus(id: "fr_sarah_1881", detailURL: arkURL,
                                 head: "Sarah Gladwin",
                                 address: "4 Pump Yard"),
                 on: "sarah", db: db)

        let occupationID = try writeUncitedMemberEvent(
            profileID: "will", memberName: "William Gladwin", type: .occupation,
            location: "12 Bramley Row", description: "Coal Carve Mender", db: db)
        // The residence row is the sharper half: census-derived residences
        // carry `description: nil`, so nil == nil passes the shape guard and
        // the differing address is deliberately never compared.
        let residenceID = try writeUncitedMemberEvent(
            profileID: "will", memberName: "William Gladwin", type: .residence,
            location: "12 Bramley Row", description: nil, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(occupationID, profileID: "will", db: db).sources.isEmpty,
                "a rival with no URL is still a rival — guessing its neighbour's URL is manufactured evidence")
        #expect(try stored(residenceID, profileID: "will", db: db).sources.isEmpty,
                "the residence has no description to discriminate on, so it must refuse too")
    }

    /// Review F01 (2026-08-26), second half. The member-record id carries no
    /// household identity, so a stranger's household mints the same id as the
    /// one that authored the row. `absorbCensusForRelative` — the only writer
    /// of these rows — can only ever target `linkedRelatives(of: subjectID)`,
    /// so a household filed against a profile with NO edge to the target is
    /// not a candidate at all. Without the scope it would be the sole
    /// candidate, face no rival, and win.
    @Test func aHouseholdWhoseSubjectIsNotARelativeCannotRepairTheRow() throws {
        let db = try makeDB()
        // Will and the stranger's household subject share no edge.
        try makeFamily(["emma", "will", "stranger"],
                       parents: [("emma", "will")], db: db)
        try save(householdCensus(id: "fr_stranger_1881", detailURL: arkURL,
                                 head: "Hannah Land", address: "4 Pump Yard"),
                 on: "stranger", db: db)

        let eventID = try writeUncitedMemberEvent(
            profileID: "will", memberName: "William Gladwin", type: .occupation,
            location: "12 Bramley Row", description: "Coal Carve Mender", db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(eventID, profileID: "will", db: db).sources.isEmpty,
                "the absorb path could never have written this row from that household")
    }

    /// The other side of that scope: a household is judged on the WIDEST field
    /// and writes on the narrowest. The stranger's household cannot have
    /// authored Will's row, but it mints the same member id, so the hash cannot
    /// tell the two apart — and the row a relationship has since been deleted
    /// from would otherwise be healed from whichever household still has an
    /// edge. An ineligible household therefore keeps its veto even though it
    /// has no vote.
    @Test func anIneligibleHouseholdStillVetoesARepairItCouldNotMake() throws {
        let db = try makeDB()
        try makeFamily(["emma", "will", "stranger"],
                       parents: [("emma", "will")], db: db)
        try save(householdCensus(id: "fr_emma_1881", detailURL: arkURL,
                                 address: "12 Bramley Row"),
                 on: "emma", db: db)
        try save(householdCensus(id: "fr_stranger_1881", detailURL: censusURL,
                                 head: "Hannah Land", address: "4 Pump Yard"),
                 on: "stranger", db: db)

        let eventID = try writeUncitedMemberEvent(
            profileID: "will", memberName: "William Gladwin", type: .occupation,
            location: "12 Bramley Row", description: "Coal Carve Mender", db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(eventID, profileID: "will", db: db).sources.isEmpty,
                "two households mint this id; a blank field is honest, a coin-flip citation is not")
    }

    /// Review F01 (2026-08-27) — the INTERSECTION of the two halves, and the
    /// single test that fails under either half-fix taken alone. The rival is
    /// both ineligible to write (its subject has no edge to Will) AND
    /// URL-less (so it projects no source at all). It must still veto:
    ///
    ///   • a "guard first" implementation (`!projected.sources.isEmpty` back in
    ///     the guard) never reaches the claims ledger for it, and Emma's URL is
    ///     stamped on uncontested;
    ///   • a "scope by skipping" implementation (`continue` when the household
    ///     cannot write, instead of registering a mute claim) drops it for the
    ///     same reason.
    ///
    /// Widest possible contest, narrowest possible write — a household with
    /// nothing to cite and nowhere to write is still asserting the row is its
    /// own fact, and that contradicts Emma.
    @Test func aURLLessIneligibleRivalStillVetoesAnEligibleRepair() throws {
        let db = try makeDB()
        try makeFamily(["emma", "will", "stranger"],
                       parents: [("emma", "will")], db: db)
        // Eligible AND citable — on its own this repairs the row.
        try save(householdCensus(id: "fr_emma_1881", detailURL: arkURL,
                                 address: "12 Bramley Row"),
                 on: "emma", db: db)
        // Neither: no edge to Will, and a text-only citation so no detailURL.
        try save(householdCensus(id: "fr_stranger_1881", detailURL: nil,
                                 head: "Hannah Land", address: "4 Pump Yard"),
                 on: "stranger", db: db)

        let eventID = try writeUncitedMemberEvent(
            profileID: "will", memberName: "William Gladwin", type: .occupation,
            location: "12 Bramley Row", description: "Coal Carve Mender", db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(eventID, profileID: "will", db: db).sources.isEmpty,
                "a rival that can neither cite nor write still contests the id — it keeps its veto")
    }

    /// The other edge of the ambiguity ledger, and the reason it is keyed on the
    /// WRITE (`origin|url`) rather than on the owning record's identity as the
    /// review suggested. The ordinary tree has the same household accepted on
    /// two relatives — and `saveAcceptedCensusEvidence` mints a per-PROFILE
    /// record id (`fieldresearcher_census_<profileID>_<year>`), so the two rows
    /// are different records carrying identical provenance. Keyed on record
    /// identity they would read as rivals and refuse every such row, which is
    /// most of what the backfill exists to repair. Keyed on the write they
    /// agree, because they would produce byte-identical sources.
    @Test func twoCopiesOfOneHouseholdCitingTheSameURLAgreeAndRepair() throws {
        let db = try makeDB()
        try makeFamily(["emma", "will", "sarah"],
                       parents: [("emma", "will"), ("emma", "sarah")], db: db)
        // Same household, same URL, saved twice under the per-profile mint.
        try save(householdCensus(id: "fr_emma_1881", detailURL: arkURL,
                                 address: "12 Bramley Row"),
                 on: "emma", db: db)
        try save(householdCensus(id: "fr_sarah_1881", detailURL: arkURL,
                                 address: "12 Bramley Row"),
                 on: "sarah", db: db)

        let eventID = try writeUncitedMemberEvent(
            profileID: "will", memberName: "William Gladwin", type: .occupation,
            location: "12 Bramley Row", description: "Coal Carve Mender", db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 1)
        #expect(urls(try stored(eventID, profileID: "will", db: db)) == [arkURL],
                "identical provenance is agreement, not ambiguity")
    }

    /// Pass A is profile-SCOPED: a record filed against "p" may only repair
    /// "p"'s rows, even though the hash for "q" is equally computable. The one
    /// deliberate exception is the census roster — `absorbCensus` writes no
    /// evidence row on the relative, so a member record is the only way that
    /// row's provenance exists anywhere (see the household test above).
    @Test func aRecordFiledAgainstAnotherProfileDoesNotRepairThisOne() throws {
        let db = try makeDB()
        let record = census(detailURL: censusURL)     // no household roster
        try save(record, on: "p", db: db)
        let strayID = SourceRecord.deterministicID(
            profileID: "q", sourceRecordID: record.id, discriminator: "occupation")
        try writeUncited(LifeEvent(
            id: strayID, profileID: "q", type: .occupation,
            description: "Sawyer"), db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 0)
        #expect(try stored(strayID, profileID: "q", db: db).sources.isEmpty)
    }

    /// An evidence row whose `record_json` no longer decodes must not abort
    /// the migration — a frozen migration has to survive a future Codable
    /// change on rows it can no longer read.
    @Test func anUndecodableEvidenceRowIsSkippedNotThrown() throws {
        let db = try makeDB()
        let record = census(detailURL: censusURL)
        try save(record, on: "p", db: db)
        try db.dbQueue.write { sql in
            try sql.execute(sql: """
                INSERT INTO evidence_records
                (id, profile_id, source_id, source_record_id, record_type, verdict,
                 record_json, scored_at)
                VALUES ('p|junk','p','freecen','junk','census','fact','{not json',?)
                """, arguments: [Date()])
        }
        let occupation = try #require(
            record.projectToLifeEvents(profileID: "p").first { $0.type == .occupation })
        try writeUncited(occupation, db: db)

        #expect(try db.backfillDerivedLifeEventCitations() == 1)
    }

    // MARK: - Migration wiring

    @Test func v64AppendsToTheMigrationChain() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let applied = try dbQueue.read { db in
            try ProjectDatabase.makeMigrator().appliedIdentifiers(db)
        }
        #expect(applied.contains("v64_backfill_derived_life_event_citations"))
        #expect(applied.contains("v63_collapse_duplicate_parent_edges"))
    }
}
