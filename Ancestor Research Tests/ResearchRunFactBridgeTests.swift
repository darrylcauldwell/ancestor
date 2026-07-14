import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Tests for `ResearchRunFactBridge` — the watcher-side bridge that queues
/// confirmed research-run facts into `pending_facts` for human review.
///
/// Anchored to the George Eric Vaughn Cauldwell UX gap (2026-07-14): a
/// watcher run confirmed his 1986 death (run envelope `supported`, evidence
/// persisted) yet Triage showed "No Pending Findings" and the tree panel
/// still offered "Research death" — the confirmed fact was reachable
/// nowhere. The bridge closes that gap; these tests lock its rules.
struct ResearchRunFactBridgeTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = "@GEORGE@",
        birthDate: String? = "19 Jul 1915",
        deathDate: String? = nil,
        deathLocation: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: "George Eric Vaughn",
            lastName: "Cauldwell",
            gender: .male,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: "Loscoe, Derbyshire, England",
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func scoredDeath(
        verdict: RecordVerdict = .fact,
        deathDate: String? = "1986",
        deathYear: Int? = 1986,
        deathPlace: String? = "Derbyshire, England, United Kingdom",
        ark: String = "https://www.familysearch.org/ark:/61903/1:1:p_100845597241"
    ) -> ScoredRecord {
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(
                id: "p_100845597241",
                sourceID: "familysearch",
                name: "Vaughan Eric Cauldwell",
                surname: "Cauldwell",
                givenName: "Vaughan Eric",
                detailURL: ark,
                rawFields: ["collection.title": "England and Wales Death Registration Index"]
            ),
            deathYear: deathYear, deathDate: deathDate, deathPlace: deathPlace,
            age: nil, quarter: nil, district: nil, volume: nil, page: nil,
            spouseSurname: nil
        ))
        return ScoredRecord(
            id: record.id, record: record, verdict: verdict,
            gates: [
                GateResult(gate: .name, outcome: .pass, reason: "rescued by exact birth-date match"),
                GateResult(gate: .date, outcome: .pass, reason: "age at death plausible"),
            ],
            summary: "Vaughan Eric Cauldwell,  1986,"
        )
    }

    // MARK: - Emission

    @Test func confirmedDeathOnDeathlessProfileEmitsDateAndLocation() {
        let facts = ResearchRunFactBridge.pendingFacts(
            from: [scoredDeath()], profile: makeProfile(), runID: "RUN-1"
        )
        #expect(facts.count == 2, "expected deathDate + deathLocation; got \(facts.map(\.field))")
        let byField = Dictionary(uniqueKeysWithValues: facts.map { ($0.field, $0) })
        #expect(byField["deathDate"]?.value == "1986")
        #expect(byField["deathLocation"]?.value == "Derbyshire, England, United Kingdom")
        // Citation + provenance ride along.
        #expect(byField["deathDate"]?.sourceURL.contains("ark:/61903") == true)
        #expect(byField["deathDate"]?.sourceTitle == "England and Wales Death Registration Index")
        #expect(byField["deathDate"]?.agentID == "research-run")
        #expect(byField["deathDate"]?.reasoning.contains("RUN-1") == true)
    }

    @Test func populatedDeathDateEmitsNothingForThatField() {
        // Check-before-overwrite: an unattended run must never queue an
        // overwrite of existing data for one-click approval.
        let facts = ResearchRunFactBridge.pendingFacts(
            from: [scoredDeath()],
            profile: makeProfile(deathDate: "1986", deathLocation: "Heanor"),
            runID: nil
        )
        #expect(facts.isEmpty, "populated fields must not re-queue; got \(facts.map(\.field))")
    }

    @Test func leadVerdictEmitsNothing() {
        let facts = ResearchRunFactBridge.pendingFacts(
            from: [scoredDeath(verdict: .lead)], profile: makeProfile(), runID: nil
        )
        #expect(facts.isEmpty, "leads are not sandwich verdicts; got \(facts.map(\.field))")
    }

    @Test func duplicateWitnessesCollapseToOnePendingFactPerFieldValue() {
        // Two records attesting the same value → one review card, not two.
        let facts = ResearchRunFactBridge.pendingFacts(
            from: [
                scoredDeath(),
                scoredDeath(ark: "https://www.familysearch.org/ark:/61903/1:1:p_OTHERWITNESS"),
            ],
            profile: makeProfile(), runID: nil
        )
        #expect(facts.filter { $0.field == "deathDate" }.count == 1)
        #expect(facts.filter { $0.field == "deathLocation" }.count == 1)
    }

    @Test func yearOnlyFallbackWhenNoExactDate() {
        let facts = ResearchRunFactBridge.pendingFacts(
            from: [scoredDeath(deathDate: nil, deathYear: 1986)],
            profile: makeProfile(), runID: nil
        )
        #expect(facts.first { $0.field == "deathDate" }?.value == "1986")
    }

    @Test func idempotencyKeyIsStableAcrossRuns() {
        // Same (profile, field, value, URL) → same id → INSERT OR IGNORE
        // makes the re-run a no-op at the database layer.
        let a = ResearchRunFactBridge.pendingFacts(from: [scoredDeath()], profile: makeProfile(), runID: "A")
        let b = ResearchRunFactBridge.pendingFacts(from: [scoredDeath()], profile: makeProfile(), runID: "B")
        #expect(a.first?.id == b.first?.id)
    }
}

// MARK: - FS-ark URL verification carve-out

/// `EvidenceFirewall.verifyURL` must classify FamilySearch ark URLs as
/// `.restricted` WITHOUT fetching — record content is licence-walled behind
/// sign-in, so content verification against an unauthenticated fetch would
/// auto-reject every legitimate FS-cited pending fact at Triage load
/// (FAMILYSEARCH_SOURCE_SPEC §16.1(3): pointer-only, no content caching).
struct EvidenceFirewallFSArkTests {

    @Test func familySearchArkClassifiesAsRestrictedWithoutFetch() async {
        let result = await EvidenceFirewall.verifyURL(
            url: "https://www.familysearch.org/ark:/61903/1:1:p_100845597241",
            evidenceText: "Vaughan Eric Cauldwell, 1986"
        )
        guard case .restricted(let reason) = result else {
            Issue.record("expected .restricted, got \(result)")
            return
        }
        #expect(reason.contains("pointer-only"))
    }

    @Test func syntheticRecordCarriesProfileNameAndSurvivesScorer() {
        // The Triage re-score builds a synthetic record from the pending
        // fact. It must carry the PROFILE's name — the fact is a claim about
        // this profile, identity was established upstream — because a
        // nameless record can never pass the name gate, and in .extend mode
        // a name-gate fail classifies .impossible, auto-rejecting every
        // date-carrying card at load (Kenneth's 2007 deathDate regression).
        let profile = Profile(
            id: "@KENNETH@", externalIDs: [:],
            firstName: "Kenneth Howard", lastName: "Cauldwell",
            gender: .male, attributes: nil,
            birthDate: GenealogicalDate(parsing: "13 July 1917"),
            birthLocation: "Loscoe, Derbyshire, England",
            deathDate: nil, deathLocation: nil, bio: nil,
            isDeleted: false, sources: [:], disputes: [:]
        )
        let finding = PendingFact(
            id: "pf-1", profileID: profile.id,
            field: "deathDate", value: "25 Oct 2007",
            sourceURL: "https://www.familysearch.org/ark:/61903/1:1:p_301639472418",
            sourceTitle: "United Kingdom, Funeral Notices, 1914-2023",
            evidenceText: "Kenneth Howard Cauldwell, 2007",
            reasoning: "bridged", confidence: "high",
            agentID: "research-run", submittedAt: Date(),
            verificationStatus: .pending
        )
        guard let record = PendingFactsProcessor.syntheticRecord(from: finding, profile: profile) else {
            Issue.record("expected a synthetic death record"); return
        }
        #expect(record.surname == "Cauldwell")
        #expect(record.givenName == "Kenneth Howard")

        let subject = ResearchSubject(
            surname: "Cauldwell", givenName: "Kenneth Howard",
            birthYearFrom: 1917, birthYearTo: 1917,
            gender: .male, region: .englandAndWales, mode: .extend
        )
        let scored = RecordScorer.classify(record: record, subject: subject, searchType: .death)
        #expect(scored.verdict != .impossible,
                "synthetic re-score must not hard-reject its own profile's fact; gates=\(scored.gates.map { "\($0.gate.rawValue):\($0.outcome)" })")
    }

    @Test func arkPredicateScopedToFamilySearchArkPaths() {
        // Hermetic predicate coverage — no network.
        #expect(EvidenceFirewall.isFamilySearchArk(url: "https://www.familysearch.org/ark:/61903/1:1:p_1"))
        #expect(EvidenceFirewall.isFamilySearchArk(url: "https://beta.familysearch.org/ark:/61903/4:1:X"))
        // Non-ark FS URL: normal verification path.
        #expect(!EvidenceFirewall.isFamilySearchArk(url: "https://www.familysearch.org/en/about"))
        // Ark on a different host: not FS's licence wall.
        #expect(!EvidenceFirewall.isFamilySearchArk(url: "https://example.org/ark:/12345/xyz"))
        // Lookalike host suffix must not match.
        #expect(!EvidenceFirewall.isFamilySearchArk(url: "https://notfamilysearch.org/ark:/1/2"))
        #expect(!EvidenceFirewall.isFamilySearchArk(url: "not a url"))
    }
}
