import Testing
import Foundation
@testable import Ancestor_Research

// Disambiguate from Swift Testing's own `Attachment` type.
private typealias Attachment = Ancestor_Research.Attachment

/// Tests for OBJE multimedia emission in GEDCOM 5.5.1 export. Per
/// DESIGN.md §5.15, every attachment whose target is a profile (or one
/// of its field sources) becomes a `1 OBJE` block under the individual
/// record, with `2 FILE`, `2 FORM`, and (when present) `2 TITL` children.
struct GEDCOMOBJETests {

    // MARK: - Fixtures

    private func makeProfile(
        id: String = "@I1@",
        firstName: String = "Thomas",
        lastName: String = "Land"
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "25 JAN 1834"),
            birthLocation: "Belper",
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
        relativePath: String = "thomas.jpg",
        caption: String? = "Wedding photo, 1923",
        mediaType: AttachmentType = .photo
    ) -> Ancestor_Research.Attachment {
        Ancestor_Research.Attachment(
            id: UUID(),
            filename: (relativePath as NSString).lastPathComponent,
            mediaType: mediaType,
            caption: caption,
            dateTaken: nil,
            locationTaken: nil,
            relativePath: relativePath,
            attachedTo: target,
            addedAt: Date()
        )
    }

    // MARK: - Tests

    @Test func gedcomExportEmitsOBJEForProfileAttachment() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let attachment = makeAttachment(target: .profile(id: profile.id))

        let result = GEDCOMExporter.export(snapshot, attachments: [attachment])
        let out = result.content

        #expect(out.contains("1 OBJE"))
        #expect(out.contains("2 FILE media/thomas.jpg"))
        #expect(out.contains("2 FORM jpg"))
        #expect(out.contains("2 TITL Wedding photo, 1923"))
    }

    @Test func gedcomExportSkipsTITLWhenCaptionEmpty() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        // Caption nil — TITL must not appear.
        let attachment = makeAttachment(
            target: .profile(id: profile.id),
            caption: nil
        )

        let result = GEDCOMExporter.export(snapshot, attachments: [attachment])
        let out = result.content

        #expect(out.contains("1 OBJE"))
        #expect(out.contains("2 FILE media/thomas.jpg"))
        #expect(out.contains("2 FORM jpg"))
        #expect(!out.contains("2 TITL"))
    }

    @Test func gedcomExportSkipsTITLWhenCaptionWhitespace() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let attachment = makeAttachment(
            target: .profile(id: profile.id),
            caption: "   "
        )

        let out = GEDCOMExporter.export(snapshot, attachments: [attachment]).content
        #expect(!out.contains("2 TITL"))
    }

    @Test func gedcomExportEmitsOBJEForFieldSourceAttachment() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let attachment = makeAttachment(
            target: .fieldSource(entityID: profile.id, field: .birthDate),
            relativePath: "scans/birth.pdf",
            caption: "Birth certificate scan"
        )

        let out = GEDCOMExporter.export(snapshot, attachments: [attachment]).content

        #expect(out.contains("1 OBJE"))
        #expect(out.contains("2 FILE media/scans/birth.pdf"))
        #expect(out.contains("2 FORM pdf"))
        #expect(out.contains("2 TITL Birth certificate scan"))
    }

    @Test func gedcomExportSkipsLifeEventAttachmentsWithoutLifeEventContext() {
        // When the caller doesn't supply the corresponding life event
        // (no `lifeEvents:` parameter), `.lifeEvent` attachments can't be
        // routed to a profile and are skipped. This preserves the pre-M14
        // behaviour for callers that only pass attachments.
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let attachment = makeAttachment(
            target: .lifeEvent(id: UUID()),
            relativePath: "wedding.jpg"
        )

        let out = GEDCOMExporter.export(snapshot, attachments: [attachment]).content
        #expect(!out.contains("1 OBJE"))
    }

    @Test func gedcomExportEmitsMultipleOBJEBlocksForSameProfile() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let one = makeAttachment(
            target: .profile(id: profile.id),
            relativePath: "a.jpg",
            caption: "Portrait"
        )
        let two = makeAttachment(
            target: .fieldSource(entityID: profile.id, field: .deathDate),
            relativePath: "b.heic",
            caption: "Headstone"
        )

        let out = GEDCOMExporter.export(snapshot, attachments: [one, two]).content

        // Two OBJE blocks within the single individual record.
        let occurrences = out.components(separatedBy: "1 OBJE").count - 1
        #expect(occurrences == 2)
        #expect(out.contains("2 FILE media/a.jpg"))
        #expect(out.contains("2 FILE media/b.heic"))
        #expect(out.contains("2 FORM heic"))
    }

    @Test func gedcomExportPlacesOBJEAfterEvents() {
        // OBJE blocks must appear AFTER BIRT/DEAT lines so the structural
        // order matches the spec (events first, multimedia last under INDI).
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )
        let attachment = makeAttachment(target: .profile(id: profile.id))

        let out = GEDCOMExporter.export(snapshot, attachments: [attachment]).content
        let birthIndex = out.range(of: "1 BIRT")!.lowerBound
        let objeIndex = out.range(of: "1 OBJE")!.lowerBound
        #expect(birthIndex < objeIndex)
    }
}
