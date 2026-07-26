import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// CONFLICT_LAYER_SPEC §4.4 T-A — the apply-time producer, wired through
/// `ApplyEngine`. Kills the audit scenarios CL1 owns:
///
/// - DS-13/DS-08: a second same-span conflicting date was preserved as
///   data (`recordAlternativeFact`) and lost as signal → now opens exactly
///   one dispute, idempotently (AC1).
/// - DS-12: a marriage record naming a different spouse applied as a
///   silent no-op at the `guard … return` → now writes a `spouseIdentity`
///   dispute and reports on the outcome channel (AC2).
/// - DS-26: accepting a second biological parent into an occupied role was
///   invisible forever → the accept proceeds AND opens a `parentRole`
///   dispute, with a pre-computed UI warning (AC3).
/// - AC5: zero write-outcome change — canonical columns and field_sources
///   behave byte-identically; dispute rows are the only new persistence.
@MainActor
struct ApplyEngineConflictHookTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(
        id: String = "p1",
        firstName: String? = "William",
        lastName: String? = "Cauldwell",
        gender: Gender = .male,
        deathDateRaw: String? = nil,
        deathSources: [FieldSource] = [],
        birthLocation: String? = nil,
        birthLocationSources: [FieldSource] = []
    ) -> Profile {
        var sources: [ProfileField: [FieldSource]] = [:]
        if !deathSources.isEmpty { sources[.deathDate] = deathSources }
        if !birthLocationSources.isEmpty { sources[.birthLocation] = birthLocationSources }
        return Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName,
            gender: gender, attributes: nil,
            birthDate: nil, birthLocation: birthLocation,
            deathDate: deathDateRaw.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil,
            bio: nil, isDeleted: false, sources: sources, disputes: [:]
        )
    }

    private func common(id: String, sourceID: String = "freebmd") -> RecordCommon {
        RecordCommon(id: id, sourceID: sourceID, name: "William Cauldwell",
                     surname: "Cauldwell", givenName: "William",
                     detailURL: nil, rawFields: [:])
    }

    private func scoredDeath(
        id: String = "d1", year: Int, quarter: String? = "Dec"
    ) -> ScoredRecord {
        let record = SourceRecord.death(DeathRecord(
            common: common(id: id), deathYear: year,
            deathDate: nil, deathPlace: nil, age: nil, quarter: quarter,
            district: "Belper", volume: "7b", page: "143", spouseSurname: nil
        ))
        return ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
    }

    private func scoredMarriage(
        id: String = "m1", year: Int = 1921, spouseName: String?,
        partnerSurnameFromSamePage: String? = nil,
        corroboratingSpouseProfileID: String? = nil
    ) -> ScoredRecord {
        let record = SourceRecord.marriage(MarriageRecord(
            common: common(id: id), marriageYear: year,
            marriageDate: nil, marriagePlace: nil, quarter: "Jun",
            district: "Belper", volume: "7b", page: "1402", spouseName: spouseName,
            partnerSurnameFromSamePage: partnerSurnameFromSamePage,
            corroboratingSpouseProfileID: corroboratingSpouseProfileID
        ))
        return ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
    }

    // MARK: - AC1: same-span conflicting deathDate opens exactly one dispute

    @Test func secondSameSpanConflictingDeathDateOpensExactlyOneDispute() throws {
        let db = try makeDB()
        // Same-class incumbent (freebmd, like scoredDeath) so CL5's R2
        // ladder can't rank the rivals: the conflict genuinely stays OPEN
        // rather than DS-09-displacing, which is the dispute-mechanics state
        // this test exercises. (DS-09 cross-class displacement is covered by
        // DisputeResolverTests.r2aOriginalityDominanceResolvesDateConflict.)
        let incumbentSource = FieldSource(origin: .freebmd, raw: "1901", addedAt: Date())
        let profile = makeProfile(deathDateRaw: "1901", deathSources: [incumbentSource])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let failures = ApplyEngine.applyFactToSubject(
            scoredDeath(year: 1900), profile: profile, snapshot: snapshot, db: db
        )
        // No persistence failures (the ConflictNotice channel is only used
        // by the marriage path).
        #expect(failures.isEmpty)

        let open = try db.openDisputes(profileID: profile.id)
        #expect(open.count == 1)
        let dispute = open[0]
        #expect(dispute.kind == .fieldValue)
        #expect(dispute.field == "deathDate")
        // Reason from the GenealogicalDate comparison: [1900,1900] vs
        // [1901,1901] are disjoint.
        #expect(dispute.reason == .noOverlap)
        #expect(dispute.detectedBy == .applyEngine)
        // Both competing sources present.
        #expect(dispute.competingSources.contains { $0.raw == "1901" })
        #expect(dispute.competingSources.contains { $0.raw == "Dec 1900" })
        // ladder_trace records the R3/R1 evaluations (and the honestly
        // inert R0/R2).
        let trace = try JSONDecoder().decode(
            [DisputeResolver.RungEvaluation].self,
            from: Data((dispute.ladderTrace ?? "[]").utf8)
        )
        #expect(trace.contains { $0.rung == "R3" && $0.outcome == "not-fired" })
        #expect(trace.contains { $0.rung == "R1" && $0.outcome == "not-fired" })
    }

    @Test func reapplyingTheSameConflictingRecordIsIdempotent() throws {
        let db = try makeDB()
        let profile = makeProfile(
            deathDateRaw: "1901",
            deathSources: [FieldSource(origin: .freebmd, raw: "1901", addedAt: Date())]  // same-class: dispute stays open under DS-09
        )
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        _ = ApplyEngine.applyFactToSubject(scoredDeath(year: 1900), profile: profile, snapshot: snapshot, db: db)
        _ = ApplyEngine.applyFactToSubject(scoredDeath(year: 1900), profile: profile, snapshot: snapshot, db: db)

        // No second row — the unique partial index and the upsert agree.
        #expect(try db.openDisputes(profileID: profile.id).count == 1)
        #expect(try db.allDisputes(profileID: profile.id).count == 1)
    }

    // MARK: - AC5: zero write-outcome change

    @Test func conflictingApplyLeavesCanonicalValueAndAlternativeFactExactlyAsBefore() throws {
        let db = try makeDB()
        let profile = makeProfile(
            deathDateRaw: "1901",
            deathSources: [FieldSource(origin: .freebmd, raw: "1901", addedAt: Date())]  // same-class: dispute stays open under DS-09
        )
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        _ = ApplyEngine.applyFactToSubject(scoredDeath(year: 1900), profile: profile, snapshot: snapshot, db: db)

        // Canonical column untouched (first-writer value stands, exactly
        // today's overwrite policy).
        let reloaded = try db.buildSnapshot().profiles[profile.id]
        #expect(reloaded?.deathDate?.original == "1901")
        // The alternative fact landed in field_sources exactly as before.
        #expect(reloaded?.sources[.deathDate]?.contains { $0.raw == "Dec 1900" } == true)
        // The ONLY new persistence class is the dispute row.
        #expect(try db.openDisputeCount() == 1)
    }

    @Test func compatibleRefinementOpensNoDispute() throws {
        // Wide existing window, precise candidate → overwrite path (the
        // narrower-span rule) — no dispute anywhere.
        let db = try makeDB()
        let profile = makeProfile(
            deathDateRaw: "BET 1899 AND 1903",
            deathSources: [FieldSource(origin: .gedcom, raw: "BET 1899 AND 1903", addedAt: Date())]
        )
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        _ = ApplyEngine.applyFactToSubject(scoredDeath(year: 1900), profile: profile, snapshot: snapshot, db: db)

        #expect(try db.openDisputeCount() == 0)
        let reloaded = try db.buildSnapshot().profiles[profile.id]
        #expect(reloaded?.deathDate?.original == "Dec 1900")
    }

    @Test func agreeingSameSpanValueOpensNoDispute() throws {
        // Same year, different quarter — identical year-window, provably
        // compatible: alternative fact only, no dispute (the pre-CL1
        // behaviour is preserved bit-for-bit for non-conflicts).
        let db = try makeDB()
        let profile = makeProfile(
            deathDateRaw: "Mar 1901",
            deathSources: [FieldSource(origin: .freebmd, raw: "Mar 1901", addedAt: Date())]
        )
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        _ = ApplyEngine.applyFactToSubject(scoredDeath(id: "d2", year: 1901, quarter: "Jun"), profile: profile, snapshot: snapshot, db: db)

        #expect(try db.openDisputeCount() == 0)
        let reloaded = try db.buildSnapshot().profiles[profile.id]
        #expect(reloaded?.deathDate?.original == "Mar 1901")
        #expect(reloaded?.sources[.deathDate]?.contains { $0.raw == "Jun 1901" } == true)
    }

    // MARK: - AC2: DS-12 — the silent marriage no-op is gone

    @Test func marriageNamingUnknownSpouseWritesDisputeAndReportsOutcome() throws {
        let db = try makeDB()
        let subject = makeProfile(id: "s", firstName: "Ernest", lastName: "Cauldwell")
        let wife = makeProfile(id: "w", firstName: "Gertrude", lastName: "Jones", gender: .female)
        _ = try db.addProfile(subject, source: .gedcom)
        _ = try db.addProfile(wife, source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "s", to: "w", type: .spouse, role: nil,
            subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        ))
        let snapshot = try db.buildSnapshot()

        // DS-12's exact scenario: post-1912 index row naming SMITH while
        // the tree knows JONES.
        let failures = ApplyEngine.applyFactToSubject(
            scoredMarriage(spouseName: "SMITH"),
            profile: snapshot.profiles["s"]!, snapshot: snapshot, db: db
        )

        // Reported outcome — the silent return is gone.
        #expect(failures.contains { $0.error is ApplyEngine.ConflictNotice })

        let open = try db.openDisputes(profileID: "s")
        #expect(open.count == 1)
        #expect(open[0].kind == .spouseIdentity)
        #expect(open[0].field == "spouse")
        #expect(open[0].detectedBy == .applyEngine)
        #expect(open[0].severity == .conflict)
        #expect(open[0].competingSources.contains { $0.raw.contains("SMITH") })
        #expect(open[0].competingSources.contains { $0.raw.contains("Gertrude Jones") })
    }

    @Test func marriageMatchingKnownSpouseStillFillsEdgeWithNoDispute() throws {
        // Regression guard: the happy path is untouched.
        let db = try makeDB()
        let subject = makeProfile(id: "s", firstName: "Ernest", lastName: "Cauldwell")
        let wife = makeProfile(id: "w", firstName: "Gertrude", lastName: "Jones", gender: .female)
        _ = try db.addProfile(subject, source: .gedcom)
        _ = try db.addProfile(wife, source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "s", to: "w", type: .spouse, role: nil,
            subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        ))
        let snapshot = try db.buildSnapshot()

        let failures = ApplyEngine.applyFactToSubject(
            scoredMarriage(spouseName: "JONES"),
            profile: snapshot.profiles["s"]!, snapshot: snapshot, db: db
        )
        #expect(failures.isEmpty)
        #expect(try db.openDisputeCount() == 0)

        let reloaded = try db.buildSnapshot()
        let edge = reloaded.relationships.first { $0.type == .spouse }
        #expect(edge?.marriageDate?.original == "Jun 1921")
    }

    @Test func marriageWithNoSpouseNameStaysSilent() throws {
        // The early guard (no spouse surname on the record AND none recovered
        // from same-page pairing) is not the DS-12 predicate — no data means
        // nothing to conflict with.
        let db = try makeDB()
        let subject = makeProfile(id: "s", firstName: "Ernest", lastName: "Cauldwell")
        _ = try db.addProfile(subject, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let failures = ApplyEngine.applyFactToSubject(
            scoredMarriage(spouseName: nil),
            profile: snapshot.profiles["s"]!, snapshot: snapshot, db: db
        )
        #expect(failures.isEmpty)
        #expect(try db.openDisputeCount() == 0)
    }

    // MARK: - #CPC follow-up — pre-1912 same-page partner fills the edge

    @Test func pre1912MarriageWithSamePagePartnerFillsEdge() throws {
        // Ida × George class: pre-1912 record carries NO spouse column, but
        // the same-page pairing recovered the partner surname. The edge must
        // now get its marriage date — previously a silent no-op.
        let db = try makeDB()
        let subject = makeProfile(id: "s", firstName: "Ernest", lastName: "Cauldwell")
        let wife = makeProfile(id: "w", firstName: "Gertrude", lastName: "Jones", gender: .female)
        _ = try db.addProfile(subject, source: .gedcom)
        _ = try db.addProfile(wife, source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "s", to: "w", type: .spouse, role: nil,
            subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        ))
        let snapshot = try db.buildSnapshot()

        let failures = ApplyEngine.applyFactToSubject(
            scoredMarriage(year: 1911, spouseName: nil, partnerSurnameFromSamePage: "JONES"),
            profile: snapshot.profiles["s"]!, snapshot: snapshot, db: db
        )
        #expect(failures.isEmpty)
        #expect(try db.openDisputeCount() == 0)

        let edge = try db.buildSnapshot().relationships.first { $0.type == .spouse }
        #expect(edge?.marriageDate?.original == "Jun 1911",
                "pre-1912 marriage must fill the edge via the recovered same-page partner")
    }

    @Test func corroborationAnnotationFillsEdgeByProfileIDWithNoSurname() throws {
        // The pure demonstrator gap: a record naming NO spouse column AND no
        // recovered surname, but carrying the cross-profile annotation
        // (`corroboratingSpouseProfileID`). Surname matching has nothing to
        // work with; the direct profile-id link must fill the edge.
        let db = try makeDB()
        let subject = makeProfile(id: "s", firstName: "Ernest", lastName: "Cauldwell")
        let wife = makeProfile(id: "w", firstName: "Gertrude", lastName: "Jones", gender: .female)
        _ = try db.addProfile(subject, source: .gedcom)
        _ = try db.addProfile(wife, source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "s", to: "w", type: .spouse, role: nil,
            subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        ))
        let snapshot = try db.buildSnapshot()

        let failures = ApplyEngine.applyFactToSubject(
            scoredMarriage(year: 1911, spouseName: nil,
                           partnerSurnameFromSamePage: nil,
                           corroboratingSpouseProfileID: "w"),
            profile: snapshot.profiles["s"]!, snapshot: snapshot, db: db
        )
        #expect(failures.isEmpty)
        #expect(try db.openDisputeCount() == 0)
        let edge = try db.buildSnapshot().relationships.first { $0.type == .spouse }
        #expect(edge?.marriageDate?.original == "Jun 1911",
                "the cross-profile annotation names the exact partner — fill the edge directly")
    }

    @Test func samePageInferredPartnerMismatchStaysSilentWithNoDispute() throws {
        // A same-page inference is a WEAKER signal than a stated column: if
        // it matches no linked spouse it must NOT open a DS-12 dispute (that
        // would over-claim from an inference the family-context gate already
        // vetted). Silent no-op.
        let db = try makeDB()
        let subject = makeProfile(id: "s", firstName: "Ernest", lastName: "Cauldwell")
        let wife = makeProfile(id: "w", firstName: "Gertrude", lastName: "Jones", gender: .female)
        _ = try db.addProfile(subject, source: .gedcom)
        _ = try db.addProfile(wife, source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "s", to: "w", type: .spouse, role: nil,
            subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        ))
        let snapshot = try db.buildSnapshot()

        let failures = ApplyEngine.applyFactToSubject(
            scoredMarriage(year: 1911, spouseName: nil, partnerSurnameFromSamePage: "SMITH"),
            profile: snapshot.profiles["s"]!, snapshot: snapshot, db: db
        )
        #expect(failures.isEmpty)
        #expect(try db.openDisputeCount() == 0,
                "an inference mismatch must not manufacture a spouse-identity dispute")
        let edge = try db.buildSnapshot().relationships.first { $0.type == .spouse }
        #expect(edge?.marriageDate == nil)
    }

    // MARK: - AC3: DS-26 — parent accept onto an occupied role

    private func makeParentProposal(
        subjectID: String, surname: String, given: String? = nil, gender: Gender
    ) -> ProposedRelative {
        let rel = ProposedRelationship.parentOf(subjectID)
        return ProposedRelative(
            id: ProposedRelative.stableID(relationship: rel, gender: gender, surname: surname),
            proposedSurname: surname,
            proposedGivenName: given,
            gender: gender,
            birthYearLow: 1850, birthYearHigh: 1870,
            relationship: rel,
            evidence: []
        )
    }

    @Test func acceptOntoOccupiedRoleProceedsAndOpensParentRoleDispute() throws {
        let db = try makeDB()
        let subject = makeProfile(id: "s")
        let mother = makeProfile(id: "m", firstName: "Mary", lastName: "Bown", gender: .female)
        _ = try db.addProfile(subject, source: .gedcom)
        _ = try db.addProfile(mother, source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "m", to: "s", type: .parent, role: .mother,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        ))
        let snapshot = try db.buildSnapshot()

        // A rival mother (different surname — dedup cannot match Mary Bown).
        let proposal = makeParentProposal(subjectID: "s", surname: "Land", gender: .female)
        var failures: [ApplyEngine.WriteFailure] = []
        let outcome = try ApplyEngine.acceptParentProposal(
            proposal, subjectID: "s", snapshot: snapshot, db: db, failures: &failures
        )

        // The accept PROCEEDS (human decided) …
        guard case .createdNew = outcome else {
            Issue.record("Expected .createdNew, got \(outcome)")
            return
        }
        // … and the DS-26 state is no longer invisible.
        let open = try db.openDisputes(profileID: "s")
        #expect(open.count == 1)
        #expect(open[0].kind == .parentRole)
        #expect(open[0].field == "mother")
        #expect(open[0].detectedBy == .applyEngine)
        #expect(open[0].competingSources.contains { $0.raw.contains("Mary Bown") })
        #expect(open[0].competingSources.contains { $0.raw.contains("Land") })
    }

    @Test func acceptUIWarningIsPreComputedFromTheSharedPredicate() throws {
        let db = try makeDB()
        let subject = makeProfile(id: "s")
        let mother = makeProfile(id: "m", firstName: "Mary", lastName: "Bown", gender: .female)
        _ = try db.addProfile(subject, source: .gedcom)
        _ = try db.addProfile(mother, source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "m", to: "s", type: .parent, role: .mother,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        ))
        let snapshot = try db.buildSnapshot()

        let rival = makeParentProposal(subjectID: "s", surname: "Land", gender: .female)
        let warning = ApplyEngine.parentRoleConflictWarning(
            for: rival, subjectID: "s", snapshot: snapshot
        )
        #expect(warning == "Subject already has a mother: Mary Bown")

        // A father proposal warns about nothing — the father role is free.
        let father = makeParentProposal(subjectID: "s", surname: "Cauldwell", gender: .male)
        #expect(ApplyEngine.parentRoleConflictWarning(
            for: father, subjectID: "s", snapshot: snapshot
        ) == nil)
    }

    @Test func acceptIntoUnoccupiedRoleOpensNoDispute() throws {
        let db = try makeDB()
        let subject = makeProfile(id: "s")
        _ = try db.addProfile(subject, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let proposal = makeParentProposal(subjectID: "s", surname: "Bown", gender: .female)
        var failures: [ApplyEngine.WriteFailure] = []
        _ = try ApplyEngine.acceptParentProposal(
            proposal, subjectID: "s", snapshot: snapshot, db: db, failures: &failures
        )
        #expect(try db.openDisputeCount() == 0)
    }

    // MARK: - Pending-fact post-write hook (T-A fourth trigger)

    @Test func acceptedPendingFactConflictingWithDisplacedValueOpensDispute() throws {
        let db = try makeDB()
        let profile = makeProfile(deathDateRaw: "1901")
        _ = try db.addProfile(profile, source: .gedcom)

        // The human accepts 1899 through the pending-facts queue (which
        // deliberately bypasses the overwrite policy). Write proceeds …
        try db.applyAcceptedPendingFact(profileID: profile.id, field: "deathDate", value: "1899")
        let reloaded = try db.buildSnapshot().profiles[profile.id]
        #expect(reloaded?.deathDate?.original == "1899")

        // … and the displaced 1901 surfaces as a dispute instead of
        // vanishing.
        let open = try db.openDisputes(profileID: profile.id)
        #expect(open.count == 1)
        #expect(open[0].kind == .fieldValue)
        #expect(open[0].field == "deathDate")
        #expect(open[0].detectedBy == .applyEngine)
        #expect(open[0].competingSources.contains { $0.raw == "1901" })
        #expect(open[0].competingSources.contains { $0.raw == "1899" })
    }

    @Test func acceptedPendingFactAgreeingWithTreeOpensNoDispute() throws {
        let db = try makeDB()
        let profile = makeProfile(deathDateRaw: "1901")
        _ = try db.addProfile(profile, source: .gedcom)

        try db.applyAcceptedPendingFact(profileID: profile.id, field: "deathDate", value: "1901")
        #expect(try db.openDisputeCount() == 0)
    }
}
