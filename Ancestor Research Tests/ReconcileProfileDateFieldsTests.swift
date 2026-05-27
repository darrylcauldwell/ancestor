import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the one-shot reconciliation pass that backfills the apply-path
/// date overwrite policy (#14) across profiles that were applied before
/// the fix. Without this pass, a profile whose `birthDate` was stuck at
/// `BET 1869 AND 1896` after a pre-fix apply stays wide on disk even
/// though precise quarters sit in `field_sources` — the fix is purely
/// write-side and doesn't self-heal existing data.
@MainActor
struct ReconcileProfileDateFieldsTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func wideProfile(id: String) -> Profile {
        // Mirrors a GEDCOM-imported profile: birthDate = wide range, no
        // birthLocation. Death side empty.
        Profile(
            id: id, externalIDs: [:],
            firstName: "George", middleName: "Herbert", lastName: "Brooks",
            gender: .male, attributes: nil,
            birthDate: GenealogicalDate(parsing: "BET 1869 AND 1896"),
            birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    // MARK: - The canonical George case

    @Test func narrowsWideBirthDateWhenSingleUnambiguousNarrowerSourceExists() throws {
        let db = try makeTempDB()
        try db.addProfile(wideProfile(id: "p"), source: .gedcom)

        // Simulate the pre-fix apply: precise FREEBMD quarter gets logged
        // as an alternative fact (the buggy branch), profile.birthDate
        // stays wide.
        try db.recordAlternativeFact(
            profileID: "p", field: .birthDate,
            rawValue: "Dec 1883", source: .freebmd
        )

        let report = try db.reconcileProfileDateFields()

        #expect(report.updates.count == 1)
        #expect(report.updates.first?.profileID == "p")
        #expect(report.updates.first?.field == .birthDate)
        #expect(report.updates.first?.to == "Dec 1883")

        let snap = try db.buildSnapshot()
        #expect(snap.profiles["p"]?.birthDate?.original == "Dec 1883")
        #expect(snap.profiles["p"]?.birthDate?.earliest == 1883)
        #expect(snap.profiles["p"]?.birthDate?.latest == 1883)
    }

    // MARK: - Refuse on ambiguity (mirrors seeding rule)

    @Test func refusesToNarrowWhenMultiplePreciseCandidatesTieOnSpan() throws {
        // George's actual state: Jun 1870 AND Dec 1883 both precise. The
        // reconciler must not pick one — silent disambiguation is exactly
        // what the multi-hypothesis slice is for.
        let db = try makeTempDB()
        try db.addProfile(wideProfile(id: "p"), source: .gedcom)
        try db.recordAlternativeFact(profileID: "p", field: .birthDate, rawValue: "Jun 1870", source: .freebmd)
        try db.recordAlternativeFact(profileID: "p", field: .birthDate, rawValue: "Dec 1883", source: .freebmd)

        let report = try db.reconcileProfileDateFields()

        #expect(report.updates.isEmpty)
        let snap = try db.buildSnapshot()
        // Profile.birthDate stays wide.
        #expect(snap.profiles["p"]?.birthDate?.earliest == 1869)
        #expect(snap.profiles["p"]?.birthDate?.latest == 1896)
    }

    @Test func narrowsWhenDuplicateRowsForSameYearAreNotTrueDisagreement() throws {
        // Same FreeBMD record written twice across scoring passes is one
        // fact, not two — should still narrow.
        let db = try makeTempDB()
        try db.addProfile(wideProfile(id: "p"), source: .gedcom)
        try db.recordAlternativeFact(profileID: "p", field: .birthDate, rawValue: "Dec 1883", source: .freebmd)
        try db.recordAlternativeFact(profileID: "p", field: .birthDate, rawValue: "Dec 1883", source: .freebmd)

        let report = try db.reconcileProfileDateFields()
        #expect(report.updates.count == 1)
        let snap = try db.buildSnapshot()
        #expect(snap.profiles["p"]?.birthDate?.original == "Dec 1883")
    }

    // MARK: - Idempotency

    @Test func reRunningOnAlreadyReconciledProfileIsNoOp() throws {
        let db = try makeTempDB()
        try db.addProfile(wideProfile(id: "p"), source: .gedcom)
        try db.recordAlternativeFact(profileID: "p", field: .birthDate, rawValue: "Dec 1883", source: .freebmd)

        let first = try db.reconcileProfileDateFields()
        #expect(first.updates.count == 1)

        // Second pass — birth is now Dec 1883 (span 0). No source is
        // strictly narrower, so nothing updates.
        let second = try db.reconcileProfileDateFields()
        #expect(second.updates.isEmpty)
    }

    // MARK: - Precision direction (never widens)

    @Test func neverWidensAPrecisePreExistingDate() throws {
        // Profile starts precise (Dec 1883). A later wider field_sources
        // row (e.g. an estimate from another source) must NOT trigger
        // overwrite back to a wider window.
        let p = Profile(
            id: "p", externalIDs: [:],
            firstName: "George", lastName: "Brooks", gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "Dec 1883"),
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        let db = try makeTempDB()
        try db.addProfile(p, source: .freebmd)
        try db.recordAlternativeFact(profileID: "p", field: .birthDate, rawValue: "ABT 1880", source: .gedcom)

        let report = try db.reconcileProfileDateFields()
        #expect(report.updates.isEmpty)
        let snap = try db.buildSnapshot()
        #expect(snap.profiles["p"]?.birthDate?.original == "Dec 1883")
    }

    // MARK: - Cross-field (death side too)

    @Test func reconcilesDeathDateAsWellAsBirthDate() throws {
        let p = Profile(
            id: "p", externalIDs: [:],
            firstName: "George", lastName: "Brooks", gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "BET 1869 AND 1896"),
            birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "BET 1940 AND 1960"),
            deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        let db = try makeTempDB()
        try db.addProfile(p, source: .gedcom)
        try db.recordAlternativeFact(profileID: "p", field: .birthDate, rawValue: "Dec 1883", source: .freebmd)
        try db.recordAlternativeFact(profileID: "p", field: .deathDate, rawValue: "Mar 1952", source: .freebmd)

        let report = try db.reconcileProfileDateFields()
        #expect(report.updates.count == 2)
        let fields = Set(report.updates.map(\.field))
        #expect(fields == [.birthDate, .deathDate])
    }

    // MARK: - Empty state

    @Test func noOpWhenNoProfilesHaveNarrowerSources() throws {
        let db = try makeTempDB()
        try db.addProfile(wideProfile(id: "p"), source: .gedcom)
        // Only the original wide range exists in sources — nothing narrower.

        let report = try db.reconcileProfileDateFields()
        #expect(report.updates.isEmpty)
        #expect(report.profilesScanned == 1)
    }
}
