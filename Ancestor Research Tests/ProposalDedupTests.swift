import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `ProposalDedup` — the pre-insert dedup that gates
/// both `acceptSibling` and `acceptProposedRelative`. Mirrors
/// `PromoteLeadDedupTests` in the MCP package so the three
/// proposal-accept paths (sibling, parent-inferred, MCP promote)
/// stay behaviourally aligned per ENGINE_FOUNDATION_SPEC §Change3.
@MainActor
struct ProposalDedupTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = UUID().uuidString,
        surname: String? = "Brooks",
        given: String? = "George",
        birthYear: Int? = 1916,
        isDeleted: Bool = false
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: given,
            lastName: surname,
            gender: .male,
            attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: isDeleted,
            sources: [:],
            disputes: [:]
        )
    }

    private func query(
        surname: String? = "Brooks",
        given: String? = "George",
        earliest: Int? = 1916,
        latest: Int? = 1916
    ) -> ProposalDedup.Query {
        ProposalDedup.Query(
            surname: surname,
            givenName: given,
            birthYearEarliest: earliest,
            birthYearLatest: latest
        )
    }

    // MARK: - Strict match (both have given names)

    @Test func surnameAndGivenNameAndYearAllMatchYieldsMatched() {
        let existing = makeProfile(id: "p1")
        let result = ProposalDedup.decide(query: query(), candidates: [existing])
        #expect(result == .matched(profileID: "p1"))
    }

    @Test func differentGivenNameYieldsNoMatch() {
        // Surname + year align, but given differs → not the same person.
        let existing = makeProfile(given: "Henry")
        let result = ProposalDedup.decide(query: query(given: "George"), candidates: [existing])
        #expect(result == .noMatch)
    }

    @Test func differentSurnameYieldsNoMatch() {
        let existing = makeProfile(surname: "Smith")
        let result = ProposalDedup.decide(query: query(surname: "Brooks"), candidates: [existing])
        #expect(result == .noMatch)
    }

    @Test func caseInsensitiveSurnameAndGivenMatch() {
        let existing = makeProfile(surname: "BROOKS", given: "GEORGE")
        let result = ProposalDedup.decide(query: query(surname: "brooks", given: "george"), candidates: [existing])
        #expect(result == .matched(profileID: existing.id))
    }

    // MARK: - Year window

    @Test func yearWithinPlusMinusTwoMatches() {
        // ±2 fudge: 1916 query, 1918 candidate → diff 2, in window.
        let existing = makeProfile(birthYear: 1918)
        let result = ProposalDedup.decide(query: query(earliest: 1916, latest: 1916), candidates: [existing])
        #expect(result == .matched(profileID: existing.id))
    }

    @Test func yearOutsidePlusMinusTwoNoMatch() {
        let existing = makeProfile(birthYear: 1920)
        let result = ProposalDedup.decide(query: query(earliest: 1916, latest: 1916), candidates: [existing])
        #expect(result == .noMatch)
    }

    @Test func nilQueryYearDefersToSurnameAndGivenAlone() {
        // No year on the query (rare for siblings, common for
        // surname-only parent placeholders). Surname + given alone
        // should still match — the count gate handles the "too many"
        // case.
        let existing = makeProfile(birthYear: 1916)
        let result = ProposalDedup.decide(query: query(earliest: nil, latest: nil), candidates: [existing])
        #expect(result == .matched(profileID: existing.id))
    }

    @Test func wideParentYearRangeOverlapsExistingProfile() {
        // Parent proposal uses a derived range (1871–1898 for a
        // subject born ~1916). Existing profile at 1882 should
        // match.
        let existing = makeProfile(birthYear: 1882)
        let result = ProposalDedup.decide(
            query: query(earliest: 1871, latest: 1898),
            candidates: [existing]
        )
        #expect(result == .matched(profileID: existing.id))
    }

    // MARK: - Asymmetric (one side surname-only)

    @Test func proposalLacksGivenNameMatchesOnSurnameAndYear() {
        // Surname-only proposal (no given) — match the single
        // same-surname candidate within year window.
        let existing = makeProfile(given: "George")
        let result = ProposalDedup.decide(query: query(given: nil), candidates: [existing])
        #expect(result == .matched(profileID: existing.id))
    }

    @Test func candidateLacksGivenNameMatchesOnSurnameAndYear() {
        // Mirror — existing placeholder profile with no given name.
        let existing = makeProfile(given: nil)
        let result = ProposalDedup.decide(query: query(given: "George"), candidates: [existing])
        #expect(result == .matched(profileID: existing.id))
    }

    // MARK: - Edge cases

    @Test func emptyCandidatesYieldsNoMatch() {
        #expect(ProposalDedup.decide(query: query(), candidates: []) == .noMatch)
    }

    @Test func multipleSurnameAndGivenMatchesYieldsMultipleMatches() {
        // Two existing duplicates → don't auto-merge. Per CLAUDE.md
        // "When in doubt, split". The audit's duplicateDetection
        // rule surfaces them for the user to resolve manually.
        let dup1 = makeProfile(id: "dup1")
        let dup2 = makeProfile(id: "dup2")
        let result = ProposalDedup.decide(query: query(), candidates: [dup1, dup2])
        #expect(result == .multipleMatches)
    }

    @Test func deletedProfilesIgnored() {
        // Soft-deleted profile shouldn't satisfy a dedup match.
        let deleted = makeProfile(id: "dead", isDeleted: true)
        let result = ProposalDedup.decide(query: query(), candidates: [deleted])
        #expect(result == .noMatch)
    }

    @Test func emptyQuerySurnameYieldsNoMatch() {
        // Defensive — a proposal with no surname can't match anything
        // meaningfully (surname is the gate).
        let result = ProposalDedup.decide(query: query(surname: nil), candidates: [makeProfile()])
        #expect(result == .noMatch)
    }

    // MARK: - Proposal type adapters

    @Test func siblingProposalAdapterPopulatesPointYearRange() {
        let proposal = SiblingProposal(
            id: "sib1", candidateRecordID: "rec1",
            proposedSurname: "Brooks", proposedGivenName: "George",
            gender: .male, birthYear: 1916, district: "Belper",
            fatherID: "fa", motherID: "mo",
            evidence: []
        )
        let q = ProposalDedup.Query(siblingProposal: proposal)
        #expect(q.surname == "Brooks")
        #expect(q.givenName == "George")
        #expect(q.birthYearEarliest == 1916)
        #expect(q.birthYearLatest == 1916)
    }

    @Test func parentProposalAdapterCarriesYearRange() {
        let proposal = ProposedRelative(
            id: "par1",
            proposedSurname: "Thompson",
            proposedGivenName: "Mary E",
            gender: .female,
            birthYearLow: 1871, birthYearHigh: 1898,
            relationship: .parentOf("subj"),
            evidence: []
        )
        let q = ProposalDedup.Query(parentProposal: proposal)
        #expect(q.surname == "Thompson")
        #expect(q.givenName == "Mary E")
        #expect(q.birthYearEarliest == 1871)
        #expect(q.birthYearLatest == 1898)
    }

    // MARK: - Slice 10 — strong-beats-weak match collection

    /// The Hilda Brooks cascade pattern. Without strong-beats-weak:
    ///   • Lilian Brooks (b.1914, given=Lilian) — given mismatch → not matched.
    ///   • Brooks-placeholder (no given, no birth) — asymmetric → matched (WEAK).
    ///   • Hilda#1 (given=Hilda, b.ABT 1912) — given match → matched (STRONG).
    ///   • Old behaviour: matched.count == 2 → .multipleMatches → cascade ghost #2.
    ///   • New behaviour: strong exists → ignore weak → matched.count == 1 →
    ///     .matched(Hilda#1) → idempotent edge → no duplicate.
    @Test func hildaCascade_strongBeatsWeakWhenPlaceholderPresent() {
        let lilian = makeProfile(id: "lilian", surname: "Brooks", given: "Lilian", birthYear: 1914)
        let brooksPlaceholder = makeProfile(id: "brooks-placeholder", surname: "Brooks", given: nil, birthYear: nil)
        let hildaGhost = makeProfile(id: "hilda-1", surname: "Brooks", given: "Hilda", birthYear: 1912)
        let candidates = [lilian, brooksPlaceholder, hildaGhost]

        let result = ProposalDedup.decide(
            query: query(surname: "Brooks", given: "Hilda", earliest: 1912, latest: 1912),
            candidates: candidates
        )
        #expect(result == .matched(profileID: "hilda-1"),
                "named sibling proposal must match the existing named ghost, NOT cascade into .multipleMatches because of the surname-only placeholder")
    }

    /// Variant of the cascade: TWO existing Hilda ghosts (legitimate
    /// ambiguity — two real Hilda Brookses?). Strong matches both →
    /// .multipleMatches is correct (genuine "split" case from
    /// CLAUDE.md's "when in doubt, split" doctrine).
    @Test func twoStrongMatchesGenuinelySplit() {
        let hilda1 = makeProfile(id: "hilda-1", surname: "Brooks", given: "Hilda", birthYear: 1912)
        let hilda2 = makeProfile(id: "hilda-2", surname: "Brooks", given: "Hilda", birthYear: 1913)
        let result = ProposalDedup.decide(
            query: query(surname: "Brooks", given: "Hilda", earliest: 1912, latest: 1912),
            candidates: [hilda1, hilda2]
        )
        #expect(result == .multipleMatches,
                "two real named matches with overlapping year windows is the legitimate ambiguity case — split.")
    }

    /// Weak-only path is preserved: parent inference often produces
    /// surname-only proposals (proposedGivenName=nil) which should still
    /// dedup against an existing surname-only ghost of the same surname.
    @Test func weakOnlyPathStillMatches_surnameOnlyParentInference() {
        let brooksGhost = makeProfile(id: "brooks-ghost", surname: "Brooks", given: nil, birthYear: nil)
        let result = ProposalDedup.decide(
            query: query(surname: "Brooks", given: nil, earliest: nil, latest: nil),
            candidates: [brooksGhost]
        )
        #expect(result == .matched(profileID: "brooks-ghost"),
                "surname-only-on-both-sides is the legitimate weak-match case — must still dedup.")
    }

    /// Edge case: only weak matches AND multiple → still .multipleMatches.
    /// Two surname-only ghosts with no disambiguating data, surname-only
    /// query. Genuine ambiguity at the surname-only-on-both-sides level.
    @Test func multipleWeakOnlyMatchesStillSplit() {
        let brooksA = makeProfile(id: "brooks-a", surname: "Brooks", given: nil, birthYear: nil)
        let brooksB = makeProfile(id: "brooks-b", surname: "Brooks", given: nil, birthYear: nil)
        let result = ProposalDedup.decide(
            query: query(surname: "Brooks", given: nil, earliest: nil, latest: nil),
            candidates: [brooksA, brooksB]
        )
        #expect(result == .multipleMatches)
    }

    /// Strong present + weak present, both single → strong wins. No cascade.
    @Test func singleStrongAndSingleWeakResolvesToStrongOnly() {
        let placeholder = makeProfile(id: "placeholder", surname: "Brooks", given: nil, birthYear: nil)
        let named = makeProfile(id: "named", surname: "Brooks", given: "Henry", birthYear: 1880)
        let result = ProposalDedup.decide(
            query: query(surname: "Brooks", given: "Henry", earliest: 1880, latest: 1880),
            candidates: [placeholder, named]
        )
        #expect(result == .matched(profileID: "named"))
    }
}
