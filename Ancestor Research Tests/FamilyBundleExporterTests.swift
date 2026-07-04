import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

// PUBLISHER_SPEC Change 2 acceptance — the bundle is the §4 viewer
// contract on disk: redaction invariants hold on the artifact, media
// copies are opt-in, identities are permanent, re-export is
// byte-identical for the same `now`, and published_state is untouched.
@MainActor
struct FamilyBundleExporterTests {

    // MARK: - Fixture

    private struct Fixture {
        let db: ProjectDatabase
        let mediaSource: URL
        let workDir: URL
        let attachmentID: UUID
    }

    private func makeFixture(optInMedia: Bool = true) throws -> Fixture {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let db = try ProjectDatabase(path: workDir.appendingPathComponent("p.sqlite").path)

        // George: deceased ⇒ full. Lily: no death date, born 1990 ⇒ redacted.
        // Walter: deceased but explicitly omitted.
        let george = Profile(
            id: "@G@", externalIDs: [:], firstName: "George", lastName: "Brooks",
            gender: .male,
            birthDate: GenealogicalDate(parsing: "1883"), birthLocation: "Belper",
            deathDate: GenealogicalDate(parsing: "1946"), deathLocation: "Derby",
            isDeleted: false, sources: [:], disputes: [:])
        let lily = Profile(
            id: "@L@", externalIDs: [:], firstName: "Lily", lastName: "Brooks",
            gender: .female,
            birthDate: GenealogicalDate(parsing: "1990"), birthLocation: "Derby",
            deathDate: nil, deathLocation: nil,
            isDeleted: false, sources: [:], disputes: [:])
        let walter = Profile(
            id: "@W@", externalIDs: [:], firstName: "Walter", lastName: "Brooks",
            gender: .male,
            birthDate: GenealogicalDate(parsing: "1850"), birthLocation: "Belper",
            deathDate: GenealogicalDate(parsing: "1920"), deathLocation: "Belper",
            isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(george, source: SourceOrigin(identifier: "gedcom"))
        _ = try db.addProfile(lily, source: SourceOrigin(identifier: "gedcom"))
        _ = try db.addProfile(walter, source: SourceOrigin(identifier: "gedcom"))
        try db.setPublishPolicy(profileID: "@W@", policy: .omit)

        _ = try db.addRelationship(Relationship(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
            from: "@G@", to: "@L@", type: .spouse, role: nil, subtype: .biological,
            marriageDate: GenealogicalDate(parsing: "1912"),
            marriageLocation: "Belper", divorceDate: nil))
        _ = try db.addRelationship(Relationship(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
            from: "@W@", to: "@G@", type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil))

        // 1911 census with household (historical ⇒ roster publishes) and a
        // sensitive residence event (never publishes).
        _ = try db.addLifeEvent(LifeEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
            profileID: "@G@", type: .census,
            date: GenealogicalDate(parsing: "1911"), location: "Belper",
            details: .census(CensusDetails(
                household: [HouseholdMember(name: "Ida Brooks", relationship: "Wife")]))))
        _ = try db.addLifeEvent(LifeEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!,
            profileID: "@G@", type: .residence,
            date: GenealogicalDate(parsing: "1930"), location: "Derby",
            sensitive: true))

        // One opted-in photo with a real file behind it.
        let mediaSource = workDir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaSource, withIntermediateDirectories: true)
        try Data("jpeg-bytes".utf8).write(to: mediaSource.appendingPathComponent("portrait.jpg"))
        let attachment = AncestorKit.Attachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            filename: "portrait.jpg", mediaType: .photo, caption: "George, 1920",
            relativePath: "portrait.jpg", attachedTo: .profile(id: "@G@"),
            addedAt: Date(timeIntervalSince1970: 0))
        _ = try db.addAttachment(attachment)
        if optInMedia {
            try db.setPublishMediaOptIn(attachmentID: attachment.id, optedIn: true)
        }

        return Fixture(db: db, mediaSource: mediaSource, workDir: workDir,
                       attachmentID: attachment.id)
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)

    private func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    // MARK: - Acceptance

    @Test func bundleAppliesRedactionInvariants() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workDir) }
        let dest = fixture.workDir.appendingPathComponent("Bundle A")
        let summary = try FamilyBundleExporter.export(
            db: fixture.db, mediaSourceDirectory: fixture.mediaSource,
            to: dest, now: fixedNow)

        let persons = try decode([PublishedPerson].self, dest.appendingPathComponent("people.json"))
        #expect(persons.count == 2, "Walter is omitted")
        let george = try #require(persons.first { !$0.isRedacted })
        let lily = try #require(persons.first { $0.isRedacted })
        #expect(george.givenName == "George" && george.birth?.earliest == 1883)
        #expect(lily.givenName == nil && lily.birth == nil && lily.birthPlace == nil)

        let rels = try decode([PublishedRelationship].self, dest.appendingPathComponent("relationships.json"))
        #expect(rels.count == 1, "Walter's parent edge dropped with him")
        #expect(rels[0].typeRaw == "spouse")
        #expect(rels[0].marriage == nil && rels[0].marriageLocation == nil,
                "marriage stripped — Lily is redacted")

        let events = try decode([PublishedLifeEvent].self, dest.appendingPathComponent("events.json"))
        #expect(events.count == 1, "sensitive residence event excluded")
        #expect(events[0].kindRaw == "census")
        let details = try #require(events[0].detailsJSON)
        #expect(details.contains("Ida Brooks"), "1911 household is historical — publishes")

        #expect(summary.personCount == 2 && summary.relationshipCount == 1)
        #expect(summary.missingMediaPaths.isEmpty)
    }

    @Test func mediaCopiedOnlyWhenOptedIn() throws {
        let optedIn = try makeFixture(optInMedia: true)
        defer { try? FileManager.default.removeItem(at: optedIn.workDir) }
        let destA = optedIn.workDir.appendingPathComponent("Bundle")
        let summaryA = try FamilyBundleExporter.export(
            db: optedIn.db, mediaSourceDirectory: optedIn.mediaSource, to: destA, now: fixedNow)
        #expect(summaryA.mediaCopied == 1)
        let copied = destA.appendingPathComponent("media/portrait.jpg")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        let media = try decode([PublishedMedia].self, destA.appendingPathComponent("media.json"))
        #expect(media.count == 1 && media[0].kind == "portrait")

        let notOptedIn = try makeFixture(optInMedia: false)
        defer { try? FileManager.default.removeItem(at: notOptedIn.workDir) }
        let destB = notOptedIn.workDir.appendingPathComponent("Bundle")
        let summaryB = try FamilyBundleExporter.export(
            db: notOptedIn.db, mediaSourceDirectory: notOptedIn.mediaSource, to: destB, now: fixedNow)
        #expect(summaryB.mediaCopied == 0)
        let mediaB = try decode([PublishedMedia].self, destB.appendingPathComponent("media.json"))
        #expect(mediaB.isEmpty)
    }

    @Test func reExportIsByteIdenticalAndIdentityIsPermanent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workDir) }
        let destA = fixture.workDir.appendingPathComponent("Bundle A")
        let destB = fixture.workDir.appendingPathComponent("Bundle B")
        _ = try FamilyBundleExporter.export(
            db: fixture.db, mediaSourceDirectory: fixture.mediaSource, to: destA, now: fixedNow)
        _ = try FamilyBundleExporter.export(
            db: fixture.db, mediaSourceDirectory: fixture.mediaSource, to: destB, now: fixedNow)

        for file in ["manifest.json", "people.json", "relationships.json", "events.json", "media.json"] {
            let a = try Data(contentsOf: destA.appendingPathComponent(file))
            let b = try Data(contentsOf: destB.appendingPathComponent(file))
            #expect(a == b, "\(file) must be byte-identical for the same `now` — §4.1 identity + deterministic serialization")
        }

        let map = try fixture.db.loadPublishedIdentityMap()
        #expect(!map.isEmpty, "minted identities persisted to published_ids")
    }

    @Test func exportNeverTouchesPublishedStateOrMeta() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workDir) }
        _ = try FamilyBundleExporter.export(
            db: fixture.db, mediaSourceDirectory: fixture.mediaSource,
            to: fixture.workDir.appendingPathComponent("Bundle"), now: fixedNow)

        let (stateRows, generation) = try fixture.db.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM published_state") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM publish_meta") ?? -1)
        }
        #expect(stateRows == 0, "the first CloudKit publish must still see everything as new")
        #expect(generation == 0, "generation bumps belong to CloudKit publishes only")
    }

    @Test func existingDestinationRefusedRatherThanOverwritten() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workDir) }
        let dest = fixture.workDir.appendingPathComponent("Bundle")
        _ = try FamilyBundleExporter.export(
            db: fixture.db, mediaSourceDirectory: fixture.mediaSource, to: dest, now: fixedNow)
        #expect(throws: FamilyBundleExportError.self) {
            _ = try FamilyBundleExporter.export(
                db: fixture.db, mediaSourceDirectory: fixture.mediaSource, to: dest, now: fixedNow)
        }
    }

    @Test func missingMediaFileSurfacedNotSilent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workDir) }
        try FileManager.default.removeItem(
            at: fixture.mediaSource.appendingPathComponent("portrait.jpg"))
        let summary = try FamilyBundleExporter.export(
            db: fixture.db, mediaSourceDirectory: fixture.mediaSource,
            to: fixture.workDir.appendingPathComponent("Bundle"), now: fixedNow)
        #expect(summary.mediaCopied == 0)
        #expect(summary.missingMediaPaths == ["portrait.jpg"])
    }
}
