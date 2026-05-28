import Testing
import Foundation
@testable import Ancestor_Research

/// Slice 5 of `project_multi_hypothesis_birth_year_plan` — apply path
/// for user-accepted `.birthYearCandidate` hypotheses. Exercises the
/// static `ResearchViewModel.applyBirthYearCandidate(_:snapshot:db:)`
/// helper (testable without an `AppState` harness).
@MainActor
struct BirthYearCandidateAcceptTests {

    // MARK: - DB helpers

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    /// `addProfile` only persists ONE field_source row per field (from
    /// the Profile struct's primary field value, with the `source` arg
    /// as origin). To stage MULTIPLE competing field_sources for
    /// `.birthDate`, this helper first adds the profile with the wide
    /// range, then uses `recordAlternativeFact` to append each precise
    /// source.
    private func seedProfile(
        id: String,
        firstName: String? = "George",
        lastName: String? = "Brooks",
        existingBirthRaw: String? = nil,
        existingBirthOrigin: SourceOrigin = .gedcom,
        preciseSources: [(raw: String, origin: SourceOrigin)] = [],
        db: ProjectDatabase
    ) throws {
        let birthDate = existingBirthRaw.map { GenealogicalDate(parsing: $0) }
        let profile = Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: .male,
            attributes: nil,
            birthDate: birthDate, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: existingBirthOrigin)
        // Append precise sources as alternative facts so they land in
        // field_sources without overwriting Profile.birthDate.
        for src in preciseSources {
            _ = try db.recordAlternativeFact(
                profileID: id, field: .birthDate,
                rawValue: src.raw, source: src.origin
            )
        }
    }

    private func birthYearCandidateHypothesis(
        profileID: String,
        year: Int,
        verdict: ResearchHypothesis.Verdict = .supported,
        isModelAssisted: Bool = false
    ) -> ResearchHypothesis {
        let kind = HypothesisKind.birthYearCandidate(profileID: profileID, year: year)
        let now = Date()
        return ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: profileID),
            subjectProfileID: profileID,
            kind: kind,
            verdict: verdict,
            isModelAssisted: isModelAssisted,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "Test fixture.",
            createdAt: now,
            lastTestedAt: now,
            attempts: 1,
            history: []
        )
    }

    // MARK: - Happy paths

    @Test func apply_writesYearToProfileBirthDate() throws {
        // Existing profile has wide-range birthDate "BET 1869 AND 1896"
        // and two competing precise sources from prior research:
        // "Jun 1870" (freebmd) and "Dec 1883" (freebmd). Slice 4 graded
        // 1883 as supported; user accepts. Result: profile.birthDate
        // narrows to Dec 1883.
        let db = try makeTempDB()
        try seedProfile(
            id: "george",
            existingBirthRaw: "BET 1869 AND 1896",
            existingBirthOrigin: .gedcom,
            preciseSources: [
                (raw: "Jun 1870", origin: .freebmd),
                (raw: "Dec 1883", origin: .freebmd)
            ],
            db: db
        )
        let snapshot = try db.buildSnapshot()
        let h = birthYearCandidateHypothesis(profileID: "george", year: 1883)

        try ResearchViewModel.applyBirthYearCandidate(h, snapshot: snapshot, db: db)

        let updated = try db.buildSnapshot()
        let updatedProfile = try #require(updated.profiles["george"])
        let newDate = try #require(updatedProfile.birthDate)
        // Preserved the precise source's raw — "Dec 1883" not "1883".
        #expect(newDate.original == "Dec 1883")
        #expect(newDate.earliest == 1883)
        #expect(newDate.latest == 1883)
        // And the apply added a new field_source attesting to this year
        // (the existing freebmd source is preserved; the write appends).
        let attestations = updatedProfile.sources[.birthDate] ?? []
        let preciseAttestations = attestations.filter { src in
            let d = GenealogicalDate(parsing: src.raw)
            return d.earliest == 1883 && d.latest == 1883
        }
        #expect(preciseAttestations.count >= 1)
    }

    @Test func apply_preservesOriginFromMatchingPreciseSource() throws {
        // One precise freebmd source for 1883. The accept should reuse
        // its origin — provenance tier carries through.
        let db = try makeTempDB()
        try seedProfile(
            id: "p1",
            existingBirthRaw: "BET 1869 AND 1896",
            preciseSources: [(raw: "Dec 1883", origin: .freebmd)],
            db: db
        )
        let snapshot = try db.buildSnapshot()
        let h = birthYearCandidateHypothesis(profileID: "p1", year: 1883)

        try ResearchViewModel.applyBirthYearCandidate(h, snapshot: snapshot, db: db)

        let updated = try db.buildSnapshot()
        let updatedProfile = try #require(updated.profiles["p1"])
        let attestations = updatedProfile.sources[.birthDate] ?? []
        let freebmd1883 = attestations.filter { src in
            let d = GenealogicalDate(parsing: src.raw)
            return src.origin == .freebmd && d.earliest == 1883 && d.latest == 1883
        }
        // ≥ 2 because the original freebmd source is still there + the write.
        #expect(freebmd1883.count >= 2)
    }

    @Test func apply_bypassesSameSpanOverwriteGuard() throws {
        // The directional-overwrite rule refuses to overwrite same-span
        // values during automated research. But the user explicitly
        // accepting a hypothesis IS the disambiguation — apply must
        // overwrite even when existing year is span-0 (wrong year).
        let db = try makeTempDB()
        try seedProfile(
            id: "subj",
            existingBirthRaw: "Jun 1870",   // span 0 — wrong year
            existingBirthOrigin: .gedcom,
            preciseSources: [
                (raw: "Jun 1870", origin: .freebmd),
                (raw: "Dec 1883", origin: .freebmd)
            ],
            db: db
        )
        let snapshot = try db.buildSnapshot()
        let h = birthYearCandidateHypothesis(profileID: "subj", year: 1883)

        try ResearchViewModel.applyBirthYearCandidate(h, snapshot: snapshot, db: db)

        let updated = try db.buildSnapshot()
        let newDate = try #require(updated.profiles["subj"]?.birthDate)
        #expect(newDate.earliest == 1883)   // overwrote despite same span
    }

    @Test func apply_fallsBackToYearOnlyWhenNoPreciseSourceMatches() throws {
        // Defensive: the generator only emits for years already in the
        // precise sources, so a year with no matching source shouldn't
        // happen — but if it does, write a year-only date with the
        // engineEnrichment origin. Provenance still flows.
        let db = try makeTempDB()
        try seedProfile(
            id: "p1",
            existingBirthRaw: "BET 1869 AND 1896",
            preciseSources: [],   // no precise sources
            db: db
        )
        let snapshot = try db.buildSnapshot()
        let h = birthYearCandidateHypothesis(profileID: "p1", year: 1883)

        try ResearchViewModel.applyBirthYearCandidate(h, snapshot: snapshot, db: db)

        let updated = try db.buildSnapshot()
        let newDate = try #require(updated.profiles["p1"]?.birthDate)
        #expect(newDate.original == "1883")
        #expect(newDate.earliest == 1883)
    }

    // MARK: - Defensive guards

    @Test func apply_throwsNotSupportedForInconclusiveVerdict() throws {
        let db = try makeTempDB()
        try seedProfile(id: "p1", db: db)
        let snapshot = try db.buildSnapshot()
        let h = birthYearCandidateHypothesis(profileID: "p1", year: 1883, verdict: .inconclusive)
        #expect(throws: ResearchViewModel.ApplyBirthYearCandidateError.self) {
            try ResearchViewModel.applyBirthYearCandidate(h, snapshot: snapshot, db: db)
        }
    }

    @Test func apply_throwsNotSupportedWhenModelAssisted() throws {
        // .supported BUT model-assisted → not deterministicallySupported.
        // Defensive — slice 2 grader never sets isModelAssisted = true,
        // but the guard protects against a future model-tier grader.
        let db = try makeTempDB()
        try seedProfile(id: "p1", db: db)
        let snapshot = try db.buildSnapshot()
        let h = birthYearCandidateHypothesis(profileID: "p1", year: 1883, isModelAssisted: true)
        #expect(throws: ResearchViewModel.ApplyBirthYearCandidateError.self) {
            try ResearchViewModel.applyBirthYearCandidate(h, snapshot: snapshot, db: db)
        }
    }

    @Test func apply_throwsWrongKindForNonBirthYearCandidate() throws {
        let db = try makeTempDB()
        let snapshot = try db.buildSnapshot()
        let now = Date()
        let kind = HypothesisKind.parentInferred(gender: .male, surname: "Brooks")
        let h = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "p1"),
            subjectProfileID: "p1",
            kind: kind,
            verdict: .supported,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "",
            createdAt: now, lastTestedAt: now,
            attempts: 1, history: []
        )
        #expect(throws: ResearchViewModel.ApplyBirthYearCandidateError.self) {
            try ResearchViewModel.applyBirthYearCandidate(h, snapshot: snapshot, db: db)
        }
    }

    @Test func apply_throwsProfileMissingForUnknownProfileID() throws {
        let db = try makeTempDB()
        let snapshot = try db.buildSnapshot()  // empty
        let h = birthYearCandidateHypothesis(profileID: "unknown", year: 1883)
        #expect(throws: ResearchViewModel.ApplyBirthYearCandidateError.self) {
            try ResearchViewModel.applyBirthYearCandidate(h, snapshot: snapshot, db: db)
        }
    }
}
