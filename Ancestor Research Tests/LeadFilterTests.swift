import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the LeadFilter contract introduced after closed-loop testing
/// found Jennifer Holmes' run jumping 17 → 260 leads with predominantly
/// wrong-person namesakes the pipeline shouldn't have surfaced.
@MainActor
struct LeadFilterTests {

    // MARK: - Fixtures

    /// `birthDate`/`deathDate` strings go through `GenealogicalDate(parsing:)`
    /// — pass "1948" for a precise year, "1945-1950" for a range, or nil
    /// for absent. Mirrors the helper in AuditEngineTests.
    private func makeProfile(
        id: String = "test-1",
        birthDate: String? = nil,
        deathDate: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: "Jennifer",
            lastName: "Holmes",
            gender: .female,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func makeScoredProbate(deathYear: Int = 2020) -> ScoredRecord {
        let common = RecordCommon(
            id: "probate-1", sourceID: "probate",
            name: "Jennifer Holmes", surname: "Holmes", givenName: "Jennifer",
            detailURL: nil, rawFields: [:]
        )
        let probate = ProbateRecord(
            common: common,
            deathDate: nil, deathYear: deathYear, probateDate: nil,
            birthDate: nil, ageAtDeath: nil, address: nil,
            grantType: "PROBATE", registry: nil, probateNumber: nil,
            regimentNumber: nil
        )
        return ScoredRecord.test(record: .probate(probate))
    }

    private func makeScoredBirth(birthYear: Int) -> ScoredRecord {
        let common = RecordCommon(
            id: "birth-\(birthYear)", sourceID: "freebmd",
            name: "Jennifer Holmes", surname: "Holmes", givenName: "Jennifer",
            detailURL: nil, rawFields: [:]
        )
        let birth = BirthRecord(
            common: common,
            birthYear: birthYear, birthDate: nil, birthPlace: nil,
            quarter: nil, district: nil, volume: nil, page: nil,
            mothersMaidenName: nil
        )
        return ScoredRecord.test(record: .birth(birth))
    }

    private func makeScoredBurial(deathYear: Int) -> ScoredRecord {
        let common = RecordCommon(
            id: "burial-\(deathYear)", sourceID: "findagrave",
            name: "Jennifer Holmes", surname: "Holmes", givenName: "Jennifer",
            detailURL: nil, rawFields: [:]
        )
        let burial = BurialRecord(
            common: common,
            deathDate: nil, deathYear: deathYear,
            birthDate: nil, birthYear: nil,
            birthPlace: nil, deathPlace: nil,
            burialLocation: nil, cemetery: nil,
            memorialID: nil, inscription: nil, bio: nil, isVeteran: false
        )
        return ScoredRecord.test(record: .burial(burial))
    }

    private func makeScoredMarriage() -> ScoredRecord {
        let common = RecordCommon(
            id: "marriage-1", sourceID: "freebmd",
            name: "Jennifer Holmes", surname: "Holmes", givenName: "Jennifer",
            detailURL: nil, rawFields: [:]
        )
        let marriage = MarriageRecord(
            common: common,
            marriageYear: 1970, marriageDate: nil, marriagePlace: nil,
            quarter: nil, district: nil, volume: nil, page: nil,
            spouseName: "John"
        )
        return ScoredRecord.test(record: .marriage(marriage))
    }

    // MARK: - deriving(from:)

    @Test func derivingPreciseBirthYearWhenEarliestEqualsLatest() {
        let profile = makeProfile(birthDate: "1948")
        let filter = LeadFilter.deriving(from: profile)
        #expect(filter.preciseBirthYear == 1948)
    }

    @Test func derivingPreciseBirthYearIsNilForBirthRange() {
        let profile = makeProfile(birthDate: "BET 1945 AND 1950")
        let filter = LeadFilter.deriving(from: profile)
        #expect(filter.preciseBirthYear == nil)
    }

    @Test func derivingPreciseBirthYearIsNilWhenNoBirthDate() {
        let profile = makeProfile()
        let filter = LeadFilter.deriving(from: profile)
        #expect(filter.preciseBirthYear == nil)
    }

    @Test func derivingIsAliveOnlyWhenLivingPrivateFlagSet() {
        // Default privacy (.normal) — absence of a death date is NOT
        // sufficient evidence the person is alive. Older relatives often
        // have no death date entered yet, and research is supposed to
        // discover that. Filter 1 must not pre-empt discovery.
        let profile = makeProfile(birthDate: "1948")
        let filter = LeadFilter.deriving(from: profile)
        #expect(filter.isAlive == false)
    }

    @Test func derivingIsAliveTrueWhenPrivacyIsLivingPrivate() {
        // Explicit `livingPrivate` is the only path to isAlive=true.
        var profile = makeProfile(birthDate: "1948")
        profile.attributes = PersonAttributes(
            nameStatus: .known, lifeStatus: .normal, privacy: .livingPrivate
        )
        let filter = LeadFilter.deriving(from: profile)
        #expect(filter.isAlive == true)
    }

    @Test func derivingIsAliveFalseWhenDeathYearKnown() {
        let profile = makeProfile(birthDate: "1916", deathDate: "1999")
        let filter = LeadFilter.deriving(from: profile)
        #expect(filter.isAlive == false)
    }

    @Test func derivingPreciseDeathYearWhenSet() {
        let profile = makeProfile(birthDate: "1916", deathDate: "1999")
        let filter = LeadFilter.deriving(from: profile)
        #expect(filter.preciseDeathYear == 1999)
    }

    @Test func derivingPreciseDeathYearIsNilForLivingProfile() {
        let profile = makeProfile(birthDate: "1948")
        let filter = LeadFilter.deriving(from: profile)
        #expect(filter.preciseDeathYear == nil)
    }

    // MARK: - Filter 3: precise-death-year window (Reginald scenario)

    @Test func deceasedProfileRejectsFarOffNamesakeProbate() {
        // Reginald scenario: died 1999. A 1978 probate for "Reginald Holmes"
        // is provably not him.
        let filter = LeadFilter(
            preciseBirthYear: 1916,
            birthYearTolerance: 5,
            preciseDeathYear: 1999,
            deathYearTolerance: 5,
            isAlive: false
        )
        let probate = makeScoredProbate(deathYear: 1978)
        #expect(filter.accepts(probate) == false)
    }

    @Test func deceasedProfileRejectsFarOffNamesakeBurial() {
        let filter = LeadFilter(
            preciseBirthYear: 1916,
            birthYearTolerance: 5,
            preciseDeathYear: 1999,
            deathYearTolerance: 5,
            isAlive: false
        )
        let burial = makeScoredBurial(deathYear: 1883)  // Brompton 1883 ≠ Reg's 1999
        #expect(filter.accepts(burial) == false)
    }

    @Test func deceasedProfileAcceptsOwnProbate() {
        // Reg's actual ADMINISTRATION 1999-03-26 — exact-year match.
        let filter = LeadFilter(
            preciseBirthYear: 1916,
            birthYearTolerance: 5,
            preciseDeathYear: 1999,
            deathYearTolerance: 5,
            isAlive: false
        )
        let probate = makeScoredProbate(deathYear: 1999)
        #expect(filter.accepts(probate) == true)
    }

    @Test func deceasedProfileAcceptsProbateWithinTolerance() {
        // Death year 2001 — transcription error / probate 2 years after
        // death is realistic. Within ±5 — accept.
        let filter = LeadFilter(
            preciseBirthYear: 1916,
            birthYearTolerance: 5,
            preciseDeathYear: 1999,
            deathYearTolerance: 5,
            isAlive: false
        )
        let probate = makeScoredProbate(deathYear: 2001)
        #expect(filter.accepts(probate) == true)
    }

    @Test func deceasedProfileWithoutPreciseDeathFallsThrough() {
        // If gedcom death is a range (no precise year), filter 3
        // doesn't fire — the namesake probate still surfaces for
        // human review. Conservative.
        let filter = LeadFilter(
            preciseBirthYear: 1916,
            birthYearTolerance: 5,
            preciseDeathYear: nil,
            deathYearTolerance: 5,
            isAlive: false
        )
        let probate = makeScoredProbate(deathYear: 1978)
        #expect(filter.accepts(probate) == true)
    }

    @Test func aliveProfileRejectsPedigreeWithDeathYear() {
        // FamilySearch-style person record returned as .pedigree
        // with a death year — closes the gap that leaked one such
        // record for Kathleen in pass 5. For an alive profile, any
        // record asserting a death year is wrong-person.
        let filter = LeadFilter(
            preciseBirthYear: 1948,
            birthYearTolerance: 5,
            preciseDeathYear: nil,
            deathYearTolerance: 5,
            isAlive: true
        )
        let common = RecordCommon(id: "ped-1", sourceID: "familysearch", name: "Jennifer Holmes", surname: "Holmes", givenName: "Jennifer", detailURL: nil, rawFields: [:])
        let pedigree = PedigreeRecord(common: common, birthYear: nil, deathYear: 2009, spouse: nil, marriageYear: nil, occupation: nil, location: nil, generation: nil)
        let scored = ScoredRecord.test(record: .pedigree(pedigree))
        #expect(filter.accepts(scored) == false)
    }

    @Test func aliveProfileAcceptsPedigreeWithoutDeathYear() {
        // A pedigree record about a living person can carry birth /
        // occupation / location without a death claim. Should pass.
        let filter = LeadFilter(
            preciseBirthYear: 1948,
            birthYearTolerance: 5,
            preciseDeathYear: nil,
            deathYearTolerance: 5,
            isAlive: true
        )
        let common = RecordCommon(id: "ped-2", sourceID: "wirksworth", name: "Jennifer Holmes", surname: "Holmes", givenName: "Jennifer", detailURL: nil, rawFields: [:])
        let pedigree = PedigreeRecord(common: common, birthYear: 1948, deathYear: nil, spouse: nil, marriageYear: nil, occupation: "shepherd", location: "Bolehill", generation: 3)
        let scored = ScoredRecord.test(record: .pedigree(pedigree))
        #expect(filter.accepts(scored) == true)
    }

    @Test func deceasedProfileRejectsPedigreeWithFarOffDeathYear() {
        // Closes the Kathleen leak (2009 vs known 2016, 7 years off).
        let filter = LeadFilter(
            preciseBirthYear: 1922,
            birthYearTolerance: 5,
            preciseDeathYear: 2016,
            deathYearTolerance: 5,
            isAlive: false
        )
        let common = RecordCommon(id: "ped-3", sourceID: "familysearch", name: "Kathleen Wheeldon", surname: "Wheeldon", givenName: "Kathleen", detailURL: nil, rawFields: [:])
        let pedigree = PedigreeRecord(common: common, birthYear: nil, deathYear: 2009, spouse: nil, marriageYear: nil, occupation: nil, location: nil, generation: nil)
        let scored = ScoredRecord.test(record: .pedigree(pedigree))
        #expect(filter.accepts(scored) == false)
    }

    @Test func filter3DoesNotAffectBirthOrMarriageRecords() {
        // Filter 3 only gates death-shaped records. Marriage records
        // shouldn't be rejected by the death-year check even when the
        // profile has a precise death year.
        let filter = LeadFilter(
            preciseBirthYear: nil,
            birthYearTolerance: 5,
            preciseDeathYear: 1999,
            deathYearTolerance: 5,
            isAlive: false
        )
        let marriage = makeScoredMarriage()
        #expect(filter.accepts(marriage) == true)
    }

    // MARK: - Filter 1: alive vs death-shaped records (Jennifer scenario)

    @Test func aliveProfileRejectsProbateRecords() {
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let probate = makeScoredProbate(deathYear: 2020)
        #expect(filter.accepts(probate) == false)
    }

    @Test func aliveProfileRejectsBurialRecords() {
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let burial = makeScoredBurial(deathYear: 2020)
        #expect(filter.accepts(burial) == false)
    }

    @Test func deceasedProfileAcceptsProbateRecords() {
        // Profile Reginald (1916-1999) — his probate should land.
        let filter = LeadFilter(preciseBirthYear: 1916, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: false)
        let probate = makeScoredProbate(deathYear: 1999)
        #expect(filter.accepts(probate) == true)
    }

    @Test func aliveProfileStillAcceptsBirthRecord() {
        // Birth record for a living profile is exactly what we want
        // to surface. Filter 1 must not over-reach.
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let birth = makeScoredBirth(birthYear: 1948)
        #expect(filter.accepts(birth) == true)
    }

    @Test func aliveProfileStillAcceptsMarriageRecord() {
        // Marriage during life is fine for a living profile.
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let marriage = makeScoredMarriage()
        #expect(filter.accepts(marriage) == true)
    }

    // MARK: - Filter 2: precise-birth-year window

    @Test func preciseBirthYearRejectsCandidateOutsideWindow() {
        // Profile born 1948, candidate "Jennifer Holmes" born 1932 →
        // 16 years off, well outside the ±5 tolerance. Reject.
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let birth = makeScoredBirth(birthYear: 1932)
        #expect(filter.accepts(birth) == false)
    }

    @Test func preciseBirthYearAcceptsCandidateInsideWindow() {
        // Within ±5 — could plausibly be a transcription error for
        // the right person. Keep.
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let birth = makeScoredBirth(birthYear: 1950)
        #expect(filter.accepts(birth) == true)
    }

    @Test func preciseBirthYearAcceptsExactMatch() {
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let birth = makeScoredBirth(birthYear: 1948)
        #expect(filter.accepts(birth) == true)
    }

    @Test func preciseBirthYearAcceptsEdgeOfWindow() {
        // |1953 - 1948| == 5 — exactly on the boundary, accept.
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let edge = makeScoredBirth(birthYear: 1953)
        #expect(filter.accepts(edge) == true)
    }

    @Test func preciseBirthYearRejectsJustBeyondWindow() {
        // |1954 - 1948| == 6, beyond ±5.
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let beyond = makeScoredBirth(birthYear: 1954)
        #expect(filter.accepts(beyond) == false)
    }

    @Test func filterFallsThroughWhenNoPreciseBirthYear() {
        // Profile with a birth-year range (or no birth at all) cannot
        // use the precise-window filter — record passes.
        let filter = LeadFilter(preciseBirthYear: nil, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let birth = makeScoredBirth(birthYear: 1900)
        #expect(filter.accepts(birth) == true)
    }

    @Test func filterFallsThroughWhenCandidateHasNoBirthYear() {
        // Marriage records don't carry candidate birth year — filter 2
        // doesn't fire, marriage still accepted (filter 1 already passed).
        let filter = LeadFilter(preciseBirthYear: 1948, birthYearTolerance: 5, preciseDeathYear: nil, deathYearTolerance: 5, isAlive: true)
        let marriage = makeScoredMarriage()
        #expect(filter.accepts(marriage) == true)
    }

    // MARK: - Combined / record-shape predicates

    @Test func isDeathShapedFlagsAllDeathTypes() {
        let common = RecordCommon(id: "x", sourceID: "x", name: nil, surname: nil, givenName: nil, detailURL: nil, rawFields: [:])
        let death = DeathRecord(common: common, deathYear: 1999, deathDate: nil, deathPlace: nil, age: nil, quarter: nil, district: nil, volume: nil, page: nil, spouseSurname: nil)
        let burial = BurialRecord(common: common, deathDate: nil, deathYear: 1999, birthDate: nil, birthYear: nil, birthPlace: nil, deathPlace: nil, burialLocation: nil, cemetery: nil, memorialID: nil, inscription: nil, bio: nil, isVeteran: false)
        let probate = ProbateRecord(common: common, deathDate: nil, deathYear: 1999, probateDate: nil, birthDate: nil, ageAtDeath: nil, address: nil, grantType: nil, registry: nil, probateNumber: nil, regimentNumber: nil)
        let military = MilitaryRecord(common: common, rank: nil, regiment: nil, unit: nil, serviceNumber: nil, dateOfDeath: nil, deathYear: 1999, age: nil, cemetery: nil, graveRef: nil, additionalInfo: nil)
        #expect(LeadFilter.isDeathShaped(.death(death)))
        #expect(LeadFilter.isDeathShaped(.burial(burial)))
        #expect(LeadFilter.isDeathShaped(.probate(probate)))
        #expect(LeadFilter.isDeathShaped(.military(military)))
    }

    @Test func isDeathShapedDoesNotFlagBirthOrMarriageOrCensus() {
        let common = RecordCommon(id: "x", sourceID: "x", name: nil, surname: nil, givenName: nil, detailURL: nil, rawFields: [:])
        let birth = BirthRecord(common: common, birthYear: 1948, birthDate: nil, birthPlace: nil, quarter: nil, district: nil, volume: nil, page: nil, mothersMaidenName: nil)
        let marriage = MarriageRecord(common: common, marriageYear: nil, marriageDate: nil, marriagePlace: nil, quarter: nil, district: nil, volume: nil, page: nil, spouseName: nil)
        let census = CensusRecord(common: common, censusYear: 1939, age: 20, birthYear: 1919, birthPlace: nil, birthCounty: nil, relationship: nil, occupation: nil, address: nil, parish: nil, district: nil, household: nil)
        #expect(LeadFilter.isDeathShaped(.birth(birth)) == false)
        #expect(LeadFilter.isDeathShaped(.marriage(marriage)) == false)
        #expect(LeadFilter.isDeathShaped(.census(census)) == false)
    }
}

// MARK: - ScoredRecord test helper

extension ScoredRecord {
    /// Convenience for tests that don't care about the scorer's
    /// verdict mechanics — just need a `ScoredRecord` wrapping a
    /// `SourceRecord`. Verdict defaults to `.lead` since that's the
    /// path LeadFilter actually filters.
    static func test(record: SourceRecord) -> ScoredRecord {
        ScoredRecord(
            id: record.id,
            record: record,
            verdict: .lead,
            gates: [],
            summary: "test"
        )
    }
}
