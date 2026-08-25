import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// One job, one button. A `censusRelationship` finding and a `censusUnabsorbed`
/// household proposal over the same census create the same people from the same
/// schedule, and stacked on one card they read as two different offers (owner
/// dogfood 2026-08-25). The household row wins — it takes its source id and
/// citation straight off the record whose roster is on screen — so the bulk
/// "Add all N" stands down when their years coincide.
struct CensusAddAffordanceTests {

    @Test func bulkAddStandsDownWhenTheHouseholdRowCoversEveryMissingPerson() {
        #expect(AuditFixButton.bulkAddSuppressed(
            missingYears: [1871, 1871], householdRowYears: [1871]))
    }

    /// A finding spanning a year the household row does not cover keeps its bulk
    /// add — otherwise those people lose their only whole-set affordance.
    @Test func bulkAddSurvivesAnUncoveredYear() {
        #expect(!AuditFixButton.bulkAddSuppressed(
            missingYears: [1871, 1881], householdRowYears: [1871]))
    }

    /// An undated missing relative can't be matched to a household row, so it is
    /// never treated as covered ("when in doubt, split").
    @Test func undatedMissingRelativeIsNeverCovered() {
        #expect(!AuditFixButton.bulkAddSuppressed(
            missingYears: [1871, nil], householdRowYears: [1871]))
    }

    @Test func nothingIsSuppressedWithoutAHouseholdRow() {
        #expect(!AuditFixButton.bulkAddSuppressed(missingYears: [1871], householdRowYears: []))
        #expect(!AuditFixButton.bulkAddSuppressed(missingYears: [], householdRowYears: [1871]))
    }

    /// The census year is what both surfaces key the one-affordance rule on, so
    /// it has to read the same out of either proposal case.
    @MainActor @Test func proposalReportsItsCensusYear() {
        #expect(AppState.CensusHouseholdProposal
            .needsLoad(sourceRecordID: "rec-1", censusYear: 1861).censusYear == 1861)
        #expect(AppState.CensusHouseholdProposal
            .canAbsorb(links: [], censusYear: 1891, sourceID: "freecen",
                       household: [], inLawCount: 0, citationURL: nil).censusYear == 1891)
    }

    /// The per-row Add exists to end "clicked it, nothing happened", so it must
    /// not offer a row the add path will skip. A sibling is wired as a child of
    /// the SUBJECT'S parents, and the proposal counts one as net-new when a
    /// parent is coming from the same roster — true of the whole-household add,
    /// never of a single row.
    @Test func perRowSiblingAddNeedsAParentToHangOn() {
        #expect(!CensusHouseholdFixRow.perRowAddLands(
            relation: .sibling, subjectHasParent: false))
        #expect(CensusHouseholdFixRow.perRowAddLands(
            relation: .sibling, subjectHasParent: true))
    }

    /// Parents, spouses and children link straight to the subject, so they land
    /// whatever the tree already holds.
    @Test func perRowAddLandsForDirectRelations() {
        for relation: CensusRelation in [.parent, .spouse, .child] {
            #expect(CensusHouseholdFixRow.perRowAddLands(
                relation: relation, subjectHasParent: false))
        }
    }

    /// The profile's Cite-census hint has two producers and they say different
    /// things: corroborate-mode evidences an UNCITED year, cite-mode's year is
    /// already research-backed and it is the census EVENT that is missing.
    /// Claiming "currently uncited" for the second is untrue (owner dogfood
    /// 2026-08-25), and the birth-date provenance is what tells them apart.
    @Test func citeHintModeFollowsBirthDateProvenance() {
        func fs(_ origin: String) -> FieldSource {
            FieldSource(origin: SourceOrigin(identifier: origin), raw: "1871",
                        addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        // No provenance at all, or import/manual only → corroborate mode.
        #expect(SharedProfileLayout.censusOfferCorroboratesBirthYear(birthDateSources: []))
        #expect(SharedProfileLayout.censusOfferCorroboratesBirthYear(
            birthDateSources: [fs("gedcom"), fs("manual")]))
        // A research source backs the year → the offer is cite-mode.
        #expect(!SharedProfileLayout.censusOfferCorroboratesBirthYear(
            birthDateSources: [fs("gedcom"), fs("freecen")]))
    }
}
