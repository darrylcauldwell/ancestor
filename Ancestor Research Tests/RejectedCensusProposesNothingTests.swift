import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// A record the user rejected must never propose anything again.
///
/// Owner dogfood 2026-08-22. Samuel Holmes was offered "Add 1 family member"
/// from the Derby St Werburgh household he had *just rejected* — it would have
/// grafted a Derby silk-mill family's 21-year-old daughter onto him as a sister.
///
/// `censusHouseholdProposal` decides a census is applied from three RETROACTIVE
/// inferences: the evidence status, a projected life event, or a confirmed fact
/// citing the record's URL. The un-apply had left one orphaned birthLocation
/// attestation behind — still citing the Derby detail URL — so the third
/// inference fired and outvoted the user's explicit verdict.
///
/// An inference must never beat an explicit rejection. These pin that.
@MainActor
struct RejectedCensusProposesNothingTests {

    private func makeAppState() throws -> AppState {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        let appState = AppState()
        appState.currentDatabase = db
        return appState
    }

    private let derbyURL = "https://www.freecen.org.uk/search_records/62276facf493fd58148a6511/samuel-holmes-1861-derbyshire-derby-1847-"

    private func member(_ name: String, _ relationship: String, age: Int,
                        sex: String, isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age,
                        birthPlace: "Derby", sex: sex, isTarget: isTarget)
    }

    /// The Derby household, with a sister who is NOT on the tree — so if the
    /// proposal fires at all, it fires with something to offer.
    private func derbyCensus(_ id: String) -> ScoredRecord {
        let record = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen", name: "Samuel HOLMES",
                                 surname: "HOLMES", givenName: "Samuel",
                                 detailURL: derbyURL, rawFields: [:]),
            censusYear: 1861, age: 14, birthYear: 1847,
            birthPlace: "Derby", district: "Derby St Werburgh",
            household: [
                member("Samuel HOLMES", "Head", age: 55, sex: "M"),
                member("Mary HOLMES", "Wife", age: 48, sex: "F"),
                member("Ann HOLMES", "Dau", age: 21, sex: "F"),
                member("Samuel HOLMES", "Son", age: 14, sex: "M", isTarget: true),
            ]))
        return ScoredRecord(id: id, record: record, verdict: .lead, gates: [], summary: "")
    }

    /// Samuel as he stood after the un-apply: an orphaned birthLocation
    /// attestation still citing the rejected Derby record.
    private func samuelWithOrphanedDerbyCitation() -> Profile {
        Profile(
            id: "sam", firstName: "Samuel", lastName: "Holmes",
            gender: .male,
            birthDate: GenealogicalDate.parsePreview("1847").parsed,
            birthLocation: "Stanton-in-Peak, Derbyshire",
            isDeleted: false,
            sources: [
                .birthLocation: [
                    FieldSource(origin: SourceOrigin(identifier: "freecen"),
                                raw: "Derby, Derbyshire", addedAt: Date(),
                                citation: Citation(title: "Census 1861: Samuel HOLMES, Derby St Werburgh",
                                                   url: derbyURL)),
                ],
            ],
            disputes: [:])
    }

    /// THE SPECIMEN. Rejected record + a fact still citing its URL → no offer.
    @Test func aDiscardedCensusProposesNothingEvenWhenAFactStillCitesIt() throws {
        let appState = try makeAppState()
        let db = try #require(appState.currentDatabase)
        let profile = samuelWithOrphanedDerbyCitation()
        _ = try db.addProfile(profile, source: .gedcom)
        try db.saveEvidence(profileID: "sam", scored: derbyCensus("derby"),
                            citationFull: "1861, Derby St Werburgh.", citationURL: derbyURL)
        try db.updateEvidenceUserStatus(profileID: "sam", sourceRecordIDs: ["derby"], status: .discarded)

        let evidence = try db.loadEvidenceForProfile("sam")
        #expect(evidence.first?.userStatus == .discarded, "precondition")

        let proposal = appState.censusHouseholdProposal(for: profile, evidence: evidence)
        #expect(proposal == nil,
                "a rejected household must never be offered for absorption — got \(String(describing: proposal))")
    }

    /// The guard must not over-fire: a KEPT census with net-new family still
    /// proposes. Without this, the fix above would silently kill the feature.
    @Test func aKeptCensusStillProposesItsFamily() throws {
        let appState = try makeAppState()
        let db = try #require(appState.currentDatabase)
        let profile = samuelWithOrphanedDerbyCitation()
        _ = try db.addProfile(profile, source: .gedcom)
        try db.saveEvidence(profileID: "sam", scored: derbyCensus("kept"),
                            citationFull: "1861, Derby St Werburgh.", citationURL: derbyURL)
        try db.updateEvidenceUserStatus(profileID: "sam", sourceRecordIDs: ["kept"], status: .savedAsLead)

        let evidence = try db.loadEvidenceForProfile("sam")
        let proposal = appState.censusHouseholdProposal(for: profile, evidence: evidence)
        #expect(proposal != nil, "a kept census with family not on the tree must still offer them")
    }

    /// An UNREVIEWED census is not applied either — it proposes nothing until
    /// the user acts on it. (Guards the other direction of the same decision.)
    @Test func anUnreviewedCensusProposesNothing() throws {
        let appState = try makeAppState()
        let db = try #require(appState.currentDatabase)
        // No citing fact this time, so no retroactive signal can fire.
        let profile = Profile(
            id: "sam", firstName: "Samuel", lastName: "Holmes",
            gender: .male, isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        try db.saveEvidence(profileID: "sam", scored: derbyCensus("new"),
                            citationFull: "1861, Derby St Werburgh.", citationURL: derbyURL)

        let evidence = try db.loadEvidenceForProfile("sam")
        #expect(appState.censusHouseholdProposal(for: profile, evidence: evidence) == nil)
    }

    /// Rejection outranks EVERY applied-signal, not just the citation one. A
    /// discarded record whose evidence row still reads `savedAsLead` (the
    /// historical quirk noted in the MCP contract) must still propose nothing.
    @Test func rejectionOutranksAStaleSavedAsLeadStatus() throws {
        let appState = try makeAppState()
        let db = try #require(appState.currentDatabase)
        let profile = samuelWithOrphanedDerbyCitation()
        _ = try db.addProfile(profile, source: .gedcom)
        try db.saveEvidence(profileID: "sam", scored: derbyCensus("derby"),
                            citationFull: "1861, Derby St Werburgh.", citationURL: derbyURL)
        try db.updateEvidenceUserStatus(profileID: "sam", sourceRecordIDs: ["derby"], status: .savedAsLead)
        try db.updateEvidenceUserStatus(profileID: "sam", sourceRecordIDs: ["derby"], status: .discarded)

        let evidence = try db.loadEvidenceForProfile("sam")
        #expect(appState.censusHouseholdProposal(for: profile, evidence: evidence) == nil)
    }

    /// A discarded census must not claim the `.needsLoad` fetch either — the
    /// early-return arm sits above the absorb arm and would otherwise offer to
    /// download a rejected record's household.
    @Test func aDiscardedRosterlessCensusDoesNotOfferAFetch() throws {
        let appState = try makeAppState()
        let db = try #require(appState.currentDatabase)
        let profile = samuelWithOrphanedDerbyCitation()
        _ = try db.addProfile(profile, source: .gedcom)
        let rosterless = ScoredRecord(
            id: "bare",
            record: .census(CensusRecord(
                common: RecordCommon(id: "bare", sourceID: "freecen", name: "Samuel HOLMES",
                                     surname: "HOLMES", givenName: "Samuel",
                                     detailURL: derbyURL, rawFields: [:]),
                censusYear: 1861, age: 14, birthYear: 1847,
                birthPlace: "Derby", district: "Derby St Werburgh")),
            verdict: .lead, gates: [], summary: "")
        try db.saveEvidence(profileID: "sam", scored: rosterless,
                            citationFull: "1861, Derby St Werburgh.", citationURL: derbyURL)
        try db.updateEvidenceUserStatus(profileID: "sam", sourceRecordIDs: ["bare"], status: .discarded)

        let evidence = try db.loadEvidenceForProfile("sam")
        #expect(appState.censusHouseholdProposal(for: profile, evidence: evidence) == nil,
                "a rejected census must not offer to fetch its household either")
    }
}
