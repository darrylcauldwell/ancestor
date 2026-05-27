import Testing
import Foundation
@testable import Ancestor_Research

/// Slice 12 — `ResearchViewModel.firstNameUpgrade(for:existing:)` pure
/// gating logic. Returns the canonical first name to write when the
/// existing ghost is surname-only AND the proposal carries a recovered
/// given name; nil otherwise. Closes the gap surfaced by Lilian's
/// Land profile: dedup matched the existing surname-only ghost from a
/// prior run, so accepting "Ida L Land" left the ghost still at "1/7".
@MainActor
struct GivenNameUpgradeOnAcceptTests {

    private func makeProfile(
        id: String = UUID().uuidString,
        surname: String? = "Land",
        firstName: String? = nil,
        gender: Gender = .female
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, middleName: nil, lastName: surname,
            marriedSurname: nil, nickName: nil, mothersMaidenName: nil,
            gender: gender, attributes: nil,
            birthDate: nil, birthLocation: nil, birthLocationCode: nil,
            deathDate: nil, deathLocation: nil, deathLocationCode: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func makeProposal(
        proposedGivenName: String?,
        proposedSurname: String = "Land",
        gender: Gender = .female,
        subjectID: String = "subj"
    ) -> ProposedRelative {
        let rel = ProposedRelationship.parentOf(subjectID)
        return ProposedRelative(
            id: ProposedRelative.stableID(relationship: rel, gender: gender, surname: proposedSurname),
            proposedSurname: proposedSurname,
            proposedGivenName: proposedGivenName,
            gender: gender,
            birthYearLow: 1885, birthYearHigh: 1885,
            relationship: rel,
            evidence: []
        )
    }

    // MARK: - Positive path

    @Test func upgradesSurnameOnlyGhostWithRecoveredGivenName() {
        // Ida L Land case: existing ghost has firstName=nil from a prior
        // run; proposal carries proposedGivenName="Ida L" from the
        // post-slice-6 parent-marriage cross-reference. The upgrade
        // returns "Ida L" so the caller writes it via editProfile.
        let existing = makeProfile(firstName: nil)
        let proposal = makeProposal(proposedGivenName: "Ida L")
        let upgrade = ResearchViewModel.firstNameUpgrade(for: proposal, existing: existing)
        #expect(upgrade == "Ida L")
    }

    @Test func capitalisesProposedName() {
        // Some BMD entries record the given name in all-caps. The accept
        // path should normalise so the profile stores "John" not "JOHN".
        let existing = makeProfile(firstName: nil)
        let proposal = makeProposal(proposedGivenName: "george h")
        let upgrade = ResearchViewModel.firstNameUpgrade(for: proposal, existing: existing)
        #expect(upgrade == "George H")
    }

    // MARK: - Negative paths

    @Test func refusesToOverwriteExistingFirstName() {
        // Identity-shaping invariant: never overwrite a populated
        // first_name. If the existing ghost already has "Mary" and the
        // proposal says "Ida L", that's an identity conflict — surface
        // via discrepancy, don't silently rewrite.
        let existing = makeProfile(firstName: "Mary")
        let proposal = makeProposal(proposedGivenName: "Ida L")
        let upgrade = ResearchViewModel.firstNameUpgrade(for: proposal, existing: existing)
        #expect(upgrade == nil)
    }

    @Test func noUpgradeWhenProposalHasNoGivenName() {
        // Pre-marriage-found proposals carry proposedGivenName=nil.
        // Accepting them shouldn't trigger an upgrade.
        let existing = makeProfile(firstName: nil)
        let proposal = makeProposal(proposedGivenName: nil)
        let upgrade = ResearchViewModel.firstNameUpgrade(for: proposal, existing: existing)
        #expect(upgrade == nil)
    }

    @Test func noUpgradeWhenProposalGivenNameIsWhitespace() {
        let existing = makeProfile(firstName: nil)
        let proposal = makeProposal(proposedGivenName: "   ")
        let upgrade = ResearchViewModel.firstNameUpgrade(for: proposal, existing: existing)
        #expect(upgrade == nil)
    }

    @Test func noUpgradeWhenExistingFirstNameIsWhitespaceOnly() {
        // Edge case — existing.firstName = "   " (whitespace stored).
        // Treat as empty → eligible to upgrade.
        let existing = makeProfile(firstName: "   ")
        let proposal = makeProposal(proposedGivenName: "Ida L")
        let upgrade = ResearchViewModel.firstNameUpgrade(for: proposal, existing: existing)
        #expect(upgrade == "Ida L", "whitespace-only existing treated as empty — upgrade should fire")
    }
}
