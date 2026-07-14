import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// CONFLICT_LAYER_SPEC CL4 — witness identity: DS-03's transcription-
/// inflation fix, F5 same-witness disagreement, R0 auto-resolution, the
/// witness-gated reopen, and the never-persisted key guarantee.
struct WitnessIdentityTests {

    private func common(_ id: String, source: String, given: String = "John",
                        surname: String = "Smith") -> RecordCommon {
        RecordCommon(id: id, sourceID: source, name: "\(given) \(surname)",
                     surname: surname, givenName: given, detailURL: nil, rawFields: [:])
    }

    // MARK: - AC1: three transcriptions of one GRO line = 1 witness

    @Test func threeTranscriptionsOfOneGROLineCountOneWitness() {
        // FreeBMD carries the full reference; FS is vol-less; FAG carries
        // year+name only. Conservative matching: missing components match.
        let freebmd = SourceRecord.death(DeathRecord(
            common: common("f1", source: "freebmd"),
            deathYear: 1860, quarter: "Jun", district: "Belper",
            volume: "7b", page: "143"))
        let familysearch = SourceRecord.death(DeathRecord(
            common: common("s1", source: "familysearch"),
            deathYear: 1860, quarter: "Jun", district: "Belper"))
        let findagrave = SourceRecord.death(DeathRecord(
            common: common("g1", source: "findagrave"),
            deathYear: 1860))

        #expect(WitnessIdentity.independentWitnessCount(
            of: [freebmd, familysearch, findagrave]) == 1)

        // …and sourcing strength reports it (AC6's computation).
        let strength = ConvergenceEngine.sourcingStrength(
            records: [freebmd, familysearch, findagrave], sourceInfoMap: [:])
        #expect(strength.independentWitnessCount == 1)
        #expect(strength.sourceCount == 3)
    }

    // MARK: - AC2: siblings sharing a GRO page = 2 witnesses

    @Test func siblingsSharingGROPageAreTwoWitnesses() {
        // Same vol/page (a GRO index PAGE holds 2-4 entries) but different
        // given initials ⟨G1⟩ — name components split them.
        let john = SourceRecord.birth(BirthRecord(
            common: common("b1", source: "freebmd", given: "John"),
            birthYear: 1860, quarter: "Jun", district: "Belper",
            volume: "7b", page: "143"))
        let mary = SourceRecord.birth(BirthRecord(
            common: common("b2", source: "freebmd", given: "Mary"),
            birthYear: 1860, quarter: "Jun", district: "Belper",
            volume: "7b", page: "143"))
        #expect(WitnessIdentity.independentWitnessCount(of: [john, mary]) == 2)
    }

    @Test func differentEventsAreDifferentWitnesses() {
        let a = SourceRecord.death(DeathRecord(
            common: common("d1", source: "freebmd"), deathYear: 1860, district: "Belper"))
        let b = SourceRecord.death(DeathRecord(
            common: common("d2", source: "freebmd"), deathYear: 1878, district: "Belper"))
        #expect(WitnessIdentity.independentWitnessCount(of: [a, b]) == 2)
        // CWGC is an independent register — never collapses into GRO space.
        let cwgc = SourceRecord.death(DeathRecord(
            common: common("d3", source: "cwgc"), deathYear: 1860, district: "Belper"))
        #expect(WitnessIdentity.independentWitnessCount(of: [a, cwgc]) == 2)
    }

    // MARK: - AC3: same-year census = 1 witness; disagreement = F5 → R0

    @Test func sameYearCensusReducesToOneWitnessAndDisagreementResolvesR0() {
        // Two transcriptions of the 1881 enumeration disagreeing on the
        // implied birth year — transcription variance, not corroboration.
        let freecen = SourceRecord.census(CensusRecord(
            common: common("c1", source: "freecen"), censusYear: 1881, birthYear: 1848))
        let unknownCopy = SourceRecord.census(CensusRecord(
            common: common("c2", source: "ancestry-copy"), censusYear: 1881, birthYear: 1852))

        #expect(WitnessIdentity.independentWitnessCount(of: [freecen, unknownCopy]) == 1)

        let conflicts = ConflictDetector.sameWitnessDisagreements(
            profileID: "p1", records: [freecen, unknownCopy])
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.sameWitness == true)
        #expect(conflicts.first?.severity == .note)

        // R0: freecen (.transcription) strictly outranks the unknown copy
        // (.community) — auto-resolved with the trace naming the winner.
        let adjudication = DisputeResolver.adjudicate(conflicts[0])
        if case .rule(let id, let accepted)? = adjudication.resolution {
            #expect(id == "R0")
            #expect(accepted.origin.identifier == "freecen")
        } else {
            Issue.record("expected R0 resolution, got \(String(describing: adjudication.resolution))")
        }
        #expect(adjudication.trace.contains { $0.rung == "R0" && $0.outcome == "fired" })
    }

    @Test func sameWitnessEqualTierStaysOpenForHuman() {
        let a = SourceRecord.census(CensusRecord(
            common: common("c1", source: "freecen"), censusYear: 1881, birthYear: 1848))
        let b = SourceRecord.census(CensusRecord(
            common: common("c2", source: "familysearch"), censusYear: 1881, birthYear: 1852))
        let conflicts = ConflictDetector.sameWitnessDisagreements(profileID: "p1", records: [a, b])
        #expect(conflicts.count == 1)
        // Both .transcription tier — no strict dominance, no auto-resolve.
        let adjudication = DisputeResolver.adjudicate(conflicts[0])
        #expect(adjudication.resolution == nil)
        #expect(adjudication.trace.contains { $0.rung == "R0" && $0.outcome == "not-fired" })
    }

    @Test func crossWitnessConflictAbstainsAtR0ThenResolvesOnOriginality() {
        // R0 must never silently reduce a genuine cross-witness conflict to
        // transcription variance — that invariant still holds (R0 abstains).
        // CL5: the R2 quality-dominance ladder then resolves on ORIGINALITY,
        // where cwgc (.primary) strictly outranks freebmd
        // (.directTranscription). Per the accepted CL5 posture, quality
        // dominance may resolve even cross-witness date conflicts.
        let conflict = DetectedConflict(
            kind: .fieldValue, profileID: "p1", field: "deathDate",
            reason: .noOverlap, severity: .conflict,
            competingSources: [
                FieldSource(origin: SourceOrigin(identifier: "cwgc"), raw: "1917", addedAt: Date()),
                FieldSource(origin: SourceOrigin(identifier: "freebmd"), raw: "1921", addedAt: Date()),
            ],
            evidenceJSON: nil, reasoning: "test", detectedBy: .applyEngine)
        let adjudication = DisputeResolver.adjudicate(conflict)
        // R0 correctly abstains (cross-witness, not same-witness variance).
        #expect(adjudication.trace.contains { $0.rung == "R0" && $0.outcome == "not-fired" })
        // R2a resolves on originality.
        guard case .rule(let ruleID, let accepted)? = adjudication.resolution else {
            Issue.record("Expected R2a resolution, got \(String(describing: adjudication.resolution))")
            return
        }
        #expect(ruleID == "R2a")
        #expect(accepted.origin.identifier == "cwgc")
    }

    // MARK: - AC4: witness-gated reopen semantics

    @Test func resolvedDisputeReopenSemantics() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "John", lastName: "Smith",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "1901"), deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)

        // Same-class competitors (both freebmd transcriptions) so CL5's R2
        // ladder can't rank them and the dispute STAYS OPEN — the state this
        // reopen-mechanics test needs. (A cross-class conflict would
        // auto-resolve; that path is covered above and in
        // DisputeResolverTests.) The incumbent is a freebmd transcription of
        // 1901; each candidate a freebmd transcription of a rival year.
        func conflict(_ value: String) -> DetectedConflict {
            DetectedConflict(
                kind: .fieldValue, profileID: "p1", field: "deathDate",
                reason: .noOverlap, severity: .conflict,
                competingSources: [
                    FieldSource(origin: SourceOrigin(identifier: "freebmd"), raw: "1901", addedAt: Date()),
                    FieldSource(origin: SourceOrigin(identifier: "freebmd"), raw: value, addedAt: Date()),
                ],
                evidenceJSON: nil, reasoning: "test", detectedBy: .applyEngine)
        }

        // Open, then resolve.
        let first = conflict("1907")
        let rowid = try db.upsertDispute(
            profileID: "p1", conflict: first,
            adjudication: DisputeResolver.adjudicate(first))
        _ = try db.resolveFieldDispute(
            profileID: "p1", field: .deathDate,
            resolution: .manual("kept 1901"))
        #expect(try db.openDisputes(profileID: "p1").isEmpty)

        // Another transcription asserting the ALREADY-WEIGHED value: no
        // reopen (the witness was adjudicated; a copy adds nothing).
        let copy = conflict("1907")
        _ = try db.upsertDispute(
            profileID: "p1", conflict: copy,
            adjudication: DisputeResolver.adjudicate(copy))
        #expect(try db.openDisputes(profileID: "p1").isEmpty)

        // A genuinely NEW conflicting value reopens as a NEW row.
        let novel = conflict("1912")
        let newRowid = try db.upsertDispute(
            profileID: "p1", conflict: novel,
            adjudication: DisputeResolver.adjudicate(novel))
        #expect(newRowid != rowid)
        #expect(try db.openDisputes(profileID: "p1").count == 1)
    }

    // MARK: - AC5: keys are computed, never persisted

    @Test func witnessKeyIsNotCodable() {
        // ⟨G9⟩ compile-level guarantee, asserted at runtime: the key type
        // deliberately conforms to neither Encodable nor Decodable.
        #expect(!(WitnessKey.self is any Encodable.Type))
        #expect(!(WitnessKey.self is any Decodable.Type))
    }

    // MARK: - Value groups collapse witnesses (DS-03 arithmetic)

    @Test func valueGroupConvergenceCollapsesTranscriptionCopies() {
        let freebmd = SourceRecord.death(DeathRecord(
            common: common("f1", source: "freebmd"),
            deathYear: 1860, quarter: "Jun", district: "Belper",
            volume: "7b", page: "143"))
        let familysearch = SourceRecord.death(DeathRecord(
            common: common("s1", source: "familysearch"),
            deathYear: 1860, quarter: "Jun", district: "Belper"))
        let groups = ConvergenceEngine.scoreValueGroups(
            records: [freebmd, familysearch], sourceInfoMap: [:])
        #expect(groups.count == 1)
        // Two transcriptions, one witness → single-source arithmetic.
        #expect(groups.first?.level == .singleSource || groups.first?.level == .uncorroborated)
    }
}
