import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// CONFLICT_LAYER_SPEC CL5 (Half B) — `.deathYearCandidate`: generator,
/// F3-predicate grader (AC4), atomic choose-one contradiction (AC5 core),
/// and accept-resolves-linked-dispute.
@MainActor
struct DeathYearCandidateTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func profileWithTwoDeathYears(
        _ id: String = "p1", years: (Int, Int) = (1905, 1913)
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: "George", lastName: "Brooks",
            gender: .male, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1883"), birthLocation: nil,
            deathDate: GenealogicalDate(parsing: String(years.0)), deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [.deathDate: [
                FieldSource(origin: SourceOrigin(identifier: "freebmd"), raw: "Mar \(years.0)", addedAt: Date(timeIntervalSince1970: 0)),
                FieldSource(origin: SourceOrigin(identifier: "freebmd"), raw: "Dec \(years.1)", addedAt: Date(timeIntervalSince1970: 1)),
            ]],
            disputes: [:]
        )
    }

    private func state(for profile: Profile) -> ResearchState {
        ResearchState(subject: ResearchSubject.fromProfile(
            profile,
            snapshot: FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])))
    }

    /// `verdict` is immutable by design (transitions go through the
    /// engine); tests rebuild the row the way the engine does.
    private func asSupported(_ h: ResearchHypothesis) -> ResearchHypothesis {
        var copy = ResearchHypothesis(
            id: h.id, subjectProfileID: h.subjectProfileID, kind: h.kind,
            origin: h.origin, verdict: .supported, isModelAssisted: false,
            supportingEvidence: ["census 1911"], contradictingEvidence: [],
            reasoning: "alive at 1911", createdAt: h.createdAt,
            lastTestedAt: Date(), attempts: h.attempts, history: h.history)
        copy.candidateGroupID = h.candidateGroupID
        return copy
    }

    // MARK: - Generator: two precise rivals → one shared group

    @Test func generatorEmitsGroupSharingCandidates() {
        let profile = profileWithTwoDeathYears()
        let snapshot = FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])
        let hypotheses = HypothesisEngine.generateDeathYearCandidate(
            state: state(for: profile), snapshot: snapshot)
        #expect(hypotheses.count == 2)
        let groups = Set(hypotheses.compactMap(\.candidateGroupID))
        #expect(groups == ["deathYear:p1"])
        #expect(hypotheses.allSatisfy { $0.verdict == .inconclusive })
    }

    @Test func generatorSilentWithSingleCandidate() {
        var profile = profileWithTwoDeathYears()
        profile.sources[.deathDate] = [profile.sources[.deathDate]![0]]
        let snapshot = FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])
        #expect(HypothesisEngine.generateDeathYearCandidate(
            state: state(for: profile), snapshot: snapshot).isEmpty)
    }

    // MARK: - AC4: grader reuses F3; between-years census decides

    @Test func aliveEvidenceAfterCandidateContradictsIt() {
        let profile = profileWithTwoDeathYears()  // 1905 vs 1913
        let census1911 = LifeEvent(
            id: UUID(), profileID: "p1", type: .census,
            date: GenealogicalDate(parsing: "1911"))
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile], relationships: [],
            lifeEvents: ["p1": [census1911]])
        let hypotheses = HypothesisEngine.generateDeathYearCandidate(
            state: state(for: profile), snapshot: snapshot)

        let candidate1905 = hypotheses.first { $0.kind.identityKey(subjectProfileID: "p1").contains("1905") }!
        let grade1905 = HypothesisEngine.gradeDeathYearCandidate(
            candidate1905, state: state(for: profile), snapshot: snapshot)
        #expect(grade1905.verdict == .contradicted)
        #expect(grade1905.reasoning.contains("1911"))

        // …and the 1913 survivor is supported: alive-at-1911 kills every
        // competitor below it (AC4's between-years rule).
        let candidate1913 = hypotheses.first { $0.kind.identityKey(subjectProfileID: "p1").contains("1913") }!
        let grade1913 = HypothesisEngine.gradeDeathYearCandidate(
            candidate1913, state: state(for: profile), snapshot: snapshot)
        #expect(grade1913.verdict == .supported)
    }

    @Test func noDiscriminatorStaysInconclusive() {
        let profile = profileWithTwoDeathYears()
        let snapshot = FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])
        let hypotheses = HypothesisEngine.generateDeathYearCandidate(
            state: state(for: profile), snapshot: snapshot)
        for hypothesis in hypotheses {
            let grade = HypothesisEngine.gradeDeathYearCandidate(
                hypothesis, state: state(for: profile), snapshot: snapshot)
            #expect(grade.verdict == .inconclusive)
        }
    }

    // MARK: - Deficit ladder: census probes inside the discriminating window

    @Test func deficitProbesTargetWindowBetweenCandidates() {
        let profile = profileWithTwoDeathYears()  // 1905 vs 1913 → 1911 census
        let snapshot = FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])
        let hypotheses = HypothesisEngine.generateDeathYearCandidate(
            state: state(for: profile), snapshot: snapshot)
        var subjectState = state(for: profile)
        subjectState.subject.deathYearFrom = 1905
        subjectState.subject.deathYearTo = 1913
        let probes = HypothesisEngine.deficitQueryDeathYearCandidate(
            for: hypotheses[0], atLevel: 1, state: subjectState)
        #expect(probes.count == 1)
        #expect(probes.first?.yearFrom == 1911)
        #expect(probes.first?.recordType == .census)

        let probate = HypothesisEngine.deficitQueryDeathYearCandidate(
            for: hypotheses[0], atLevel: 2, state: subjectState)
        #expect(probate.count == 1)
        #expect(probate.first?.recordType == .probate)
        #expect(probate.first?.yearTo == 1915)
    }

    // MARK: - AC5 core: accepting one candidate contradicts rivals atomically
    // MARK: - + accept resolves the linked dispute

    @Test func acceptContradictsRivalsAndResolvesLinkedDispute() throws {
        let db = try makeDB()
        let profile = profileWithTwoDeathYears()
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])

        // Open deathDate dispute (the state the R2 ladder leaves behind).
        let conflict = DetectedConflict(
            kind: .fieldValue, profileID: "p1", field: ProfileField.deathDate.rawValue,
            reason: .noOverlap, severity: .conflict,
            competingSources: profile.sources[.deathDate]!,
            evidenceJSON: nil, reasoning: "two freebmd quarters", detectedBy: .applyEngine)
        _ = try db.upsertDispute(profileID: "p1", conflict: conflict,
                                 adjudication: DisputeResolver.adjudicate(conflict))
        #expect(try db.openDisputes(profileID: "p1").count == 1)

        // Persist the candidate group; mark 1913 supported (as the grader
        // would after the 1911 census probe).
        var hypotheses = HypothesisEngine.generateDeathYearCandidate(
            state: state(for: profile), snapshot: snapshot)
        let idx1913 = hypotheses.firstIndex { $0.id.contains("1913") }!
        hypotheses[idx1913] = asSupported(hypotheses[idx1913])
        try db.upsertHypotheses(hypotheses)

        // The human clicks Accept on the supported candidate.
        try ApplyEngine.applyDeathYearCandidate(
            hypotheses[idx1913], snapshot: snapshot, db: db)

        // Rivals contradicted atomically ⟨G5⟩…
        let group = try db.hypotheses(inCandidateGroup: "deathYear:p1")
        #expect(group.count == 2)
        let rival = group.first { $0.id.contains("1905") }
        #expect(rival?.verdict == .contradicted)
        // …the linked dispute is resolved by the user's acceptance…
        #expect(try db.openDisputes(profileID: "p1").isEmpty)
        // …and the field carries the chosen year's attested raw.
        let updated = try db.buildSnapshot().profiles["p1"]
        #expect(updated?.deathDate?.earliest == 1913)
    }

    // MARK: - Verdicts propose; nothing applies without the click (AC6 core)

    @Test func supportedVerdictAloneWritesNothing() throws {
        let db = try makeDB()
        let profile = profileWithTwoDeathYears()
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])
        var hypotheses = HypothesisEngine.generateDeathYearCandidate(
            state: state(for: profile), snapshot: snapshot)
        let idx = hypotheses.firstIndex { $0.id.contains("1913") }!
        hypotheses[idx] = asSupported(hypotheses[idx])
        try db.upsertHypotheses(hypotheses)

        // No Accept click — the profile's death date is untouched.
        let unchanged = try db.buildSnapshot().profiles["p1"]
        #expect(unchanged?.deathDate?.earliest == 1905)
    }
}
