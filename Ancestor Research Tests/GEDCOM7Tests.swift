import Testing
import Foundation
@testable import Ancestor_Research

// Disambiguate from Swift Testing's own `Attachment` type.
private typealias Attachment = Ancestor_Research.Attachment

/// Tests for GEDCOM 7.0 dialect support (M15). Covers:
///   - Header version stamping + `2 FORM LINEAGE-LINKED` removal
///   - Top-level `0 @M{n}@ OBJE` records + INDI references in 7.0
///   - Inline OBJE preservation in 5.5.1
///   - GIVN/SURN substructures in 7.0 NAME emission
///   - Parser version detection from the HEAD/GEDC/VERS chain
///   - Tolerance of 7.0-only constructs the parser doesn't yet model
///   - Round-trip (export 7.0 → parse → semantic match)
struct GEDCOM7Tests {

    // MARK: - Fixtures

    private func makeProfile(
        id: String = "@I1@",
        firstName: String? = "Mary",
        lastName: String? = "Smith"
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .female,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "12 MAR 1850"),
            birthLocation: "Derby",
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func makeAttachment(
        target: AttachmentTarget,
        relativePath: String = "wedding.jpg",
        caption: String? = "Wedding photo, 1923"
    ) -> Ancestor_Research.Attachment {
        Ancestor_Research.Attachment(
            id: UUID(),
            filename: (relativePath as NSString).lastPathComponent,
            mediaType: .photo,
            caption: caption,
            dateTaken: nil,
            locationTaken: nil,
            relativePath: relativePath,
            attachedTo: target,
            addedAt: Date()
        )
    }

    // MARK: - Header

    @Test func gedcom7HeaderEmitsVERS70() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile], relationships: []
        )
        let out = GEDCOMExporter.export(snapshot, format: .v7_0).content
        #expect(out.contains("2 VERS 7.0"))
        // FORM LINEAGE-LINKED was removed from the GEDC substructure in
        // 7.0 — emitting it would invalidate the file against the spec.
        #expect(!out.contains("2 FORM LINEAGE-LINKED"))
    }

    @Test func gedcom551HeaderStillEmitsVERS551AndForm() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile], relationships: []
        )
        let out = GEDCOMExporter.export(snapshot, format: .v5_5_1).content
        #expect(out.contains("2 VERS 5.5.1"))
        #expect(out.contains("2 FORM LINEAGE-LINKED"))
    }

    // MARK: - OBJE structural shift

    @Test func gedcom7EmitsTopLevelOBJE() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile], relationships: []
        )
        let attachment = makeAttachment(target: .profile(id: profile.id))

        let out = GEDCOMExporter.export(
            snapshot, attachments: [attachment], format: .v7_0
        ).content

        // Top-level OBJE record present, INDI references it via @M1@.
        #expect(out.contains("0 @M1@ OBJE"))
        #expect(out.contains("1 OBJE @M1@"))

        // The 5.5.1 inline pattern must NOT appear — i.e. a bare `1 OBJE`
        // immediately followed by `2 FILE`. Because `1 OBJE @M1@` legitimately
        // contains the substring "1 OBJE", check the inline pair explicitly.
        #expect(!out.contains("1 OBJE\n2 FILE"))
    }

    @Test func gedcom551EmitsInlineOBJE() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile], relationships: []
        )
        let attachment = makeAttachment(target: .profile(id: profile.id))

        let out = GEDCOMExporter.export(
            snapshot, attachments: [attachment], format: .v5_5_1
        ).content

        // Inline pattern present (1 OBJE then 2 FILE).
        #expect(out.contains("1 OBJE\n2 FILE"))
        // No top-level @M1@ record in 5.5.1.
        #expect(!out.contains("0 @M1@ OBJE"))
    }

    // MARK: - NAME substructures

    @Test func gedcom7NameEmitsGivnSurnSubstructures() {
        let profile = makeProfile(firstName: "Mary", lastName: "Smith")
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile], relationships: []
        )
        let out = GEDCOMExporter.export(snapshot, format: .v7_0).content
        #expect(out.contains("1 NAME Mary /Smith/"))
        #expect(out.contains("2 GIVN Mary"))
        #expect(out.contains("2 SURN Smith"))
    }

    // MARK: - Parser version detection

    @Test func parserDetectsVersion70FromHeader() {
        let gedcom = """
        0 HEAD
        1 CHAR UTF-8
        1 GEDC
        2 VERS 7.0
        0 @I1@ INDI
        1 NAME John /Smith/
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        #expect(result.version == .v7_0)
    }

    @Test func parserDetectsVersion551AsDefault() {
        let gedcom = """
        0 HEAD
        1 CHAR UTF-8
        1 GEDC
        2 VERS 5.5.1
        2 FORM LINEAGE-LINKED
        0 @I1@ INDI
        1 NAME John /Smith/
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        #expect(result.version == .v5_5_1)
    }

    @Test func parserDefaultsTo551WhenHeaderMissing() {
        // No GEDC/VERS in HEAD — defaults to .v5_5_1 rather than crashing.
        let gedcom = """
        0 HEAD
        1 CHAR UTF-8
        0 @I1@ INDI
        1 NAME John /Smith/
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        #expect(result.version == .v5_5_1)
    }

    // MARK: - Parser tolerance for 7.0-only constructs

    @Test func parserToleratesTopLevelOBJERecords() {
        // GEDCOM 7.0 emits OBJE as top-level records. We don't import them
        // into our model (attachments come from the project DB / GEDZip
        // extraction), but we must not crash or fail to parse the rest.
        let gedcom = """
        0 HEAD
        1 GEDC
        2 VERS 7.0
        1 CHAR UTF-8
        0 @I1@ INDI
        1 NAME John /Smith/
        0 @M1@ OBJE
        1 FILE media/photo.jpg
        2 FORM jpg
        1 TITL Wedding portrait
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        #expect(result.individualCount == 1)
        #expect(result.snapshot.profiles["@I1@"]?.firstName == "John")
        #expect(result.snapshot.profiles["@I1@"]?.lastName == "Smith")
    }

    @Test func parserToleratesInlineOBJEReferences() {
        // 7.0 INDI may carry `1 OBJE @M1@` — a pointer to a top-level
        // OBJE record. The MVP parser ignores the pointer (no attachment
        // model created) but must continue parsing the rest of the INDI.
        let gedcom = """
        0 HEAD
        1 GEDC
        2 VERS 7.0
        1 CHAR UTF-8
        0 @I1@ INDI
        1 NAME Mary /Jones/
        1 SEX F
        1 BIRT
        2 DATE 5 JUN 1880
        1 OBJE @M1@
        0 @M1@ OBJE
        1 FILE media/portrait.jpg
        2 FORM jpg
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        let profile = result.snapshot.profiles["@I1@"]
        #expect(profile?.firstName == "Mary")
        #expect(profile?.lastName == "Jones")
        #expect(profile?.gender == .female)
        #expect(profile?.birthDate?.earliest == 1880)
    }

    // MARK: - Round-trip

    @Test func gedcom7RoundTrip() {
        // Snapshot with a single individual + a couple, exported in 7.0
        // and re-parsed. Names, gender, dates, and family edges should
        // survive intact.
        let mary = Profile(
            id: "@I1@",
            externalIDs: [:],
            firstName: "Mary",
            lastName: "Smith",
            gender: .female,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "12 MAR 1850"),
            birthLocation: "Derby",
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
        let john = Profile(
            id: "@I2@",
            externalIDs: [:],
            firstName: "John",
            lastName: "Smith",
            gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1845"),
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
        let marriage = Relationship(
            id: UUID(), from: john.id, to: mary.id,
            type: .spouse,
            role: nil,
            subtype: .unknown,
            marriageDate: GenealogicalDate(parsing: "1870"),
            marriageLocation: nil,
            divorceDate: nil
        )
        let snapshot = FamilyGraphSnapshot(
            profiles: [mary.id: mary, john.id: john],
            relationships: [marriage]
        )

        let exported = GEDCOMExporter.export(snapshot, format: .v7_0)
        #expect(exported.content.contains("2 VERS 7.0"))

        let reimported = GEDCOMParser.parse(content: exported.content)
        #expect(reimported.version == .v7_0)
        #expect(reimported.individualCount == 2)

        let reMary = reimported.snapshot.profiles["@I1@"]
        #expect(reMary?.firstName == "Mary")
        #expect(reMary?.lastName == "Smith")
        #expect(reMary?.gender == .female)
        #expect(reMary?.birthDate?.earliest == 1850)
        #expect(reMary?.birthLocation == "Derby")

        let reJohn = reimported.snapshot.profiles["@I2@"]
        #expect(reJohn?.firstName == "John")
        #expect(reJohn?.gender == .male)

        // Spouse relationship survived
        let spouses = reimported.snapshot.spousesOf("@I1@")
        #expect(spouses.first?.id == "@I2@")
    }

    @Test func gedcom7RoundTripWithAttachments() {
        // OBJE blocks should round-trip cleanly: exporter writes top-level
        // records + INDI references; parser tolerates both and still
        // produces correct profiles.
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile], relationships: []
        )
        let attachment = makeAttachment(target: .profile(id: profile.id))

        let exported = GEDCOMExporter.export(
            snapshot, attachments: [attachment], format: .v7_0
        )
        let reimported = GEDCOMParser.parse(content: exported.content)
        #expect(reimported.version == .v7_0)
        let re = reimported.snapshot.profiles["@I1@"]
        #expect(re?.firstName == "Mary")
        #expect(re?.lastName == "Smith")
    }
}
