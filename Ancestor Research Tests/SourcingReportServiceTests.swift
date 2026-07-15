import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// SOURCE_WEIGHTING_SPEC Change 8 — per-field evidence-chain verdicts from
/// persisted state. The verdict ladder: contradicted > corroborated >
/// cited > uncorroborated(searched:), with empty fields excluded (gaps are
/// the Research tab's job).
@MainActor
struct SourcingReportServiceTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func deathRecord(id: String, year: Int) -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                 surname: "Cauldwell", givenName: "George",
                                 detailURL: nil, rawFields: [:]),
            deathYear: year, deathDate: nil, deathPlace: nil, age: nil,
            quarter: nil, district: "Belper", volume: nil, page: nil,
            spouseSurname: nil))
    }

    private func verdict(_ field: ProfileField, in report: ProfileSourcingReport) -> FactSourcingVerdict? {
        report.rows.first { $0.field == field }?.verdict
    }

    @Test func verdictLadderPerField() throws {
        let db = try makeTempDB()
        let cited = FieldSource(
            origin: SourceOrigin(identifier: "freebmd"), raw: "Belper", addedAt: Date(),
            citation: Citation(url: "https://www.freebmd.org.uk/x"))
        let profile = Profile(
            id: "@P@", externalIDs: [:], firstName: "George", lastName: "Cauldwell",
            gender: .male, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1900"),
            birthLocation: "Somewhere",
            deathDate: GenealogicalDate(parsing: "1986"),
            deathLocation: "Belper",
            bio: nil, isDeleted: false,
            sources: [.deathLocation: [cited]], disputes: [:])

        // death:1986 has a persisted three-witness chain.
        let group = ConvergenceEngine.ValueGroup(
            key: "death:1986", records: [deathRecord(id: "d1", year: 1986)],
            level: .confirmed,
            sourcing: SourcingStrength(sourceCount: 3, independentLineageCount: 3,
                                       topTrustTier: .primary, independentWitnessCount: 3))
        try db.upsertEvidenceConvergence(profileID: "@P@", groups: [group])
        // Birth-kind negative search: birth fields are searched-but-empty.
        try db.saveNegativeSearch(profileID: "@P@", sourceID: "freebmd",
                                  recordType: "birth", params: nil)

        let report = SourcingReportService.report(profile: profile, db: db)
        #expect(report.rows.count == 4, "all four populated identity fields report")
        #expect(verdict(.deathDate, in: report) ==
                .corroborated(level: .confirmed, independentWitnesses: 3))
        #expect(verdict(.deathLocation, in: report) == .cited)
        #expect(verdict(.birthDate, in: report) == .uncorroborated(searched: true))
        #expect(verdict(.birthLocation, in: report) == .uncorroborated(searched: true))
    }

    @Test func unsearchedFieldsSaySo() throws {
        let db = try makeTempDB()
        let profile = Profile(
            id: "@Q@", externalIDs: [:], firstName: "Ada", lastName: "Rose",
            gender: .female, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1901"), birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
        let report = SourcingReportService.report(profile: profile, db: db)
        #expect(report.rows.count == 1, "only the populated field reports")
        #expect(verdict(.birthDate, in: report) == .uncorroborated(searched: false),
                "no negative_searches rows → 'never searched', not 'searched, empty'")
    }

    @Test func contradictedOutranksTheChain() throws {
        let db = try makeTempDB()
        let existingSource = FieldSource(
            origin: SourceOrigin(identifier: "freebmd"), raw: "1901", addedAt: Date())
        let profile = Profile(
            id: "@R@", externalIDs: [:], firstName: "William", lastName: "Cauldwell",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "1901"), deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [.deathDate: [existingSource]], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)

        // A same-span incompatible candidate opens a deathDate dispute.
        let conflict = try #require(ConflictDetector.dateFieldConflict(
            field: .deathDate, existing: profile.deathDate,
            existingSources: [existingSource],
            candidate: GenealogicalDate(parsing: "1900"),
            candidateOrigin: SourceOrigin(identifier: "freebmd"),
            profileID: "@R@"))
        let adjudication = DisputeResolver.adjudicate(conflict)
        _ = try db.upsertDispute(profileID: "@R@", conflict: conflict,
                                 adjudication: adjudication, transactionID: nil)
        // Even with a persisted chain, contradiction wins the verdict.
        let group = ConvergenceEngine.ValueGroup(
            key: "death:1901", records: [deathRecord(id: "d2", year: 1901)],
            level: .probable,
            sourcing: SourcingStrength(sourceCount: 2, independentLineageCount: 2,
                                       topTrustTier: .transcription, independentWitnessCount: 2))
        try db.upsertEvidenceConvergence(profileID: "@R@", groups: [group])

        let report = SourcingReportService.report(profile: profile, db: db)
        #expect(verdict(.deathDate, in: report) == .contradicted(openDisputes: 1))
    }

    @Test func treeReportsSortWorstFirst() throws {
        let db = try makeTempDB()
        let clean = Profile(
            id: "@A@", externalIDs: [:], firstName: "Ann", lastName: "Zed",
            gender: .female, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1900"), birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [.birthDate: [FieldSource(
                origin: SourceOrigin(identifier: "freebmd"), raw: "1900", addedAt: Date(),
                citation: Citation(url: "https://x"))]], disputes: [:])
        let needy = Profile(
            id: "@B@", externalIDs: [:], firstName: "Bob", lastName: "Able",
            gender: .male, attributes: nil,
            birthDate: GenealogicalDate(parsing: "1890"), birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
        let snapshot = FamilyGraphSnapshot(
            profiles: [clean.id: clean, needy.id: needy], relationships: [])

        let reports = SourcingReportService.treeReports(snapshot: snapshot, db: db)
        #expect(reports.count == 2)
        #expect(reports.first?.profileID == "@B@",
                "uncorroborated outranks cited in the worst-first ordering")
    }
}
