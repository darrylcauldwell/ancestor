import Testing
import Foundation
@testable import Ancestor_Research

/// RESEARCH_PIPELINE_SPEC §5.15 Slice 1 — the `.parentCandidates` kind
/// (Decision E1) and the `origin` provenance field. Covers:
///   • Codable round-trip for the new kind (full and partial hints).
///   • identityKey composition: nil-hint normalisation, case folding,
///     window bounds, per-payload uniqueness.
///   • Backwards compatibility: hypothesis JSON encoded before `origin`
///     existed still decodes (defaulting to `.engine`).
///   • Persistence: `origin` survives the v32 column round-trip, and is
///     insert-only under upsert — an engine-side re-grade can never flip
///     a `.user` row back to 'engine'.
@MainActor
struct ParentCandidatesHypothesisTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeKind(
        fatherGiven: String? = "Bob",
        fatherSurname: String? = "Wheeldon",
        motherGiven: String? = "Sue",
        motherMaidenSurname: String? = "Smith",
        window: ClosedRange<Int> = 1850...1881
    ) -> HypothesisKind {
        .parentCandidates(
            fatherGiven: fatherGiven,
            fatherSurname: fatherSurname,
            motherGiven: motherGiven,
            motherMaidenSurname: motherMaidenSurname,
            marriageWindow: window
        )
    }

    private func makeHypothesis(
        kind: HypothesisKind,
        origin: ResearchHypothesis.Origin = .user
    ) -> ResearchHypothesis {
        ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "subj-1"),
            subjectProfileID: nil,
            kind: kind,
            origin: origin,
            verdict: .inconclusive,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "seeded",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            lastTestedAt: Date(timeIntervalSince1970: 1_000_000),
            attempts: 0,
            history: []
        )
    }

    // MARK: - Kind shape

    @Test func discriminatorIsStable() {
        #expect(makeKind().discriminator == "parentCandidates")
    }

    @Test func kindRoundTripsThroughCodable() throws {
        let kind = makeKind()
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == kind)
    }

    @Test func kindRoundTripsWithNilHints() throws {
        // "Sue, maiden surname unknown" — partial hints are the honest
        // encoding the interim placeholder path can't express (§5.15.9).
        let kind = makeKind(fatherGiven: nil, fatherSurname: nil, motherMaidenSurname: nil)
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == kind)
    }

    // MARK: - identityKey (§5.15.1)

    @Test func identityKeyComposesAllHintsUppercased() {
        let key = makeKind().identityKey(subjectProfileID: "subj-1")
        #expect(key == "parentCandidates:subj-1:BOBxWHEELDONxSUExSMITH:1850-1881")
    }

    @Test func identityKeyNormalisesNilHintsToEmpty() {
        let kind = makeKind(fatherGiven: nil, fatherSurname: nil,
                            motherGiven: "Sue", motherMaidenSurname: nil)
        let key = kind.identityKey(subjectProfileID: "subj-1")
        #expect(key == "parentCandidates:subj-1:xxSUEx:1850-1881")
    }

    @Test func identityKeyIsCaseInsensitiveOnHints() {
        let k1 = makeKind(fatherGiven: "bob").identityKey(subjectProfileID: "s")
        let k2 = makeKind(fatherGiven: "BOB").identityKey(subjectProfileID: "s")
        #expect(k1 == k2)
    }

    @Test func identityKeyDiffersByWindow() {
        let k1 = makeKind(window: 1850...1881).identityKey(subjectProfileID: "s")
        let k2 = makeKind(window: 1855...1881).identityKey(subjectProfileID: "s")
        #expect(k1 != k2)
    }

    @Test func identityKeyDiffersBySubject() {
        #expect(makeKind().identityKey(subjectProfileID: "a")
            != makeKind().identityKey(subjectProfileID: "b"))
    }

    // MARK: - origin Codable backwards compatibility

    @Test func hypothesisJSONWithoutOriginDecodesAsEngine() throws {
        // Simulate pre-v32 persisted JSON: encode a current hypothesis,
        // strip the origin key, decode — legacy rows/backups have no
        // origin field and must keep decoding.
        let h = makeHypothesis(kind: makeKind(), origin: .user)
        let data = try JSONEncoder().encode(h)
        var dict = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        dict.removeValue(forKey: "origin")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ResearchHypothesis.self, from: legacyData)
        #expect(decoded.origin == .engine)
        #expect(decoded.kind == h.kind)
    }

    @Test func originRoundTripsThroughCodable() throws {
        let h = makeHypothesis(kind: makeKind(), origin: .user)
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(ResearchHypothesis.self, from: data)
        #expect(decoded.origin == .user)
    }

    @Test func legacyKindsStillDecodeAlongsideNewCase() throws {
        // Adding a case must not disturb decoding of existing payloads.
        let legacy = HypothesisKind.parentMarriage(
            motherSurname: "HOLMES", fatherSurname: "CAULDWELL",
            windowYears: 1850...1881
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(HypothesisKind.self, from: data)
        #expect(decoded == legacy)
    }

    // MARK: - Persistence (v32 origin column)

    @Test func userOriginSurvivesPersistenceRoundTrip() throws {
        let db = try makeTempDB()
        let h = makeHypothesis(kind: makeKind(), origin: .user)
        try db.upsertHypothesis(h)
        let loaded = try #require(try db.loadHypothesis(id: h.id))
        #expect(loaded.origin == .user)
        #expect(loaded.kind == h.kind)
        #expect(loaded.verdict == .inconclusive)
        #expect(loaded.attempts == 0)
    }

    @Test func upsertNeverFlipsUserOriginBackToEngine() throws {
        // §5.15.1: the engine's regeneration cycle never reshapes `.user`
        // rows. Even if an engine-side copy loses the origin in memory,
        // the upsert's ON CONFLICT clause must not overwrite the column.
        let db = try makeTempDB()
        let kind = makeKind()
        try db.upsertHypothesis(makeHypothesis(kind: kind, origin: .user))
        try db.upsertHypothesis(makeHypothesis(kind: kind, origin: .engine))
        let loaded = try #require(
            try db.loadHypothesis(id: kind.identityKey(subjectProfileID: "subj-1"))
        )
        #expect(loaded.origin == .user)
    }
}
