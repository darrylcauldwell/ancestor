import Testing
import Foundation
@testable import Ancestor_Research

/// M13 — Attachments. Pure-data + DB tests. EXIF/thumbnail tests are out of
/// scope (need real test fixtures); skipped here.
struct AttachmentTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeAttachment(
        id: UUID = UUID(),
        target: AttachmentTarget,
        type: AttachmentType = .photo,
        relativePath: String = "media.jpg"
    ) -> Ancestor_Research.Attachment {
        Ancestor_Research.Attachment(
            id: id,
            filename: "input.jpg",
            mediaType: type,
            caption: nil,
            dateTaken: nil,
            locationTaken: nil,
            relativePath: relativePath,
            attachedTo: target,
            addedAt: Date()
        )
    }

    // MARK: - AttachmentTarget encoding

    @Test func attachmentTargetEncodesAndDecodesEachVariant() throws {
        let cases: [AttachmentTarget] = [
            .profile(id: "P1"),
            .lifeEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            .fieldSource(entityID: "P1", field: .birthDate)
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in cases {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(AttachmentTarget.self, from: data)
            #expect(decoded == original, "Round-trip failed for \(original)")
        }
    }

    @Test func attachmentTargetPrimaryIDIsStable() {
        #expect(AttachmentTarget.profile(id: "P1").primaryID == "P1")

        let lifeEventID = UUID()
        #expect(AttachmentTarget.lifeEvent(id: lifeEventID).primaryID == lifeEventID.uuidString)

        let fieldTarget = AttachmentTarget.fieldSource(entityID: "P1", field: .birthDate)
        #expect(fieldTarget.primaryID == "P1:birthDate")

        // kind is stable string, exposed for SQL keying.
        #expect(AttachmentTarget.profile(id: "P1").kind == "profile")
        #expect(AttachmentTarget.lifeEvent(id: lifeEventID).kind == "lifeEvent")
        #expect(fieldTarget.kind == "fieldSource")
    }

    // MARK: - DB persistence

    @Test func addingAttachmentPersists() throws {
        let db = try makeTempDB()
        let attachment = makeAttachment(target: .profile(id: "P1"))
        try db.addAttachment(attachment)

        let reloaded = try db.loadAttachments()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == attachment.id)
        #expect(reloaded.first?.attachedTo == .profile(id: "P1"))
    }

    @Test func loadAttachmentsForProfileIncludesFieldSourceAttachments() throws {
        let db = try makeTempDB()
        let direct = makeAttachment(target: .profile(id: "P1"))
        let viaField = makeAttachment(target: .fieldSource(entityID: "P1", field: .birthDate))
        let unrelated = makeAttachment(target: .profile(id: "P2"))
        try db.addAttachment(direct)
        try db.addAttachment(viaField)
        try db.addAttachment(unrelated)

        let forP1 = try db.loadAttachmentsForProfile("P1")
        let ids = Set(forP1.map(\.id))
        #expect(ids.contains(direct.id))
        #expect(ids.contains(viaField.id))
        #expect(!ids.contains(unrelated.id))
        #expect(forP1.count == 2)
    }

    @Test func deletingAttachmentRemovesIt() throws {
        let db = try makeTempDB()
        let attachment = makeAttachment(target: .profile(id: "P1"))
        try db.addAttachment(attachment)
        #expect(try db.loadAttachments().count == 1)

        try db.deleteAttachment(id: attachment.id)
        #expect(try db.loadAttachments().isEmpty)
    }

    @Test func updatingAttachmentMutatesMetadata() throws {
        let db = try makeTempDB()
        var attachment = makeAttachment(target: .profile(id: "P1"))
        try db.addAttachment(attachment)

        attachment.caption = "Belper census 1881"
        attachment.locationTaken = "53.0234,-1.4789"
        try db.updateAttachment(attachment)

        let reloaded = try db.loadAttachments().first
        #expect(reloaded?.caption == "Belper census 1881")
        #expect(reloaded?.locationTaken == "53.0234,-1.4789")
    }

    // MARK: - Extension → AttachmentType matrix

    @Test func attachmentTypeFromExtensionMatrix() {
        let cases: [(String, AttachmentType)] = [
            ("photo.jpg", .photo),
            ("photo.JPEG", .photo),
            ("scan.heic", .photo),
            ("scan.HEIF", .photo),
            ("snap.png", .photo),
            ("old.tiff", .photo),
            ("doc.pdf", .document),
            ("scan.PDF", .document),
            ("notes.txt", .transcription),
            ("notes.md", .transcription),
            ("unknown.xyz", .document),       // unknown → document fallback
        ]
        for (filename, expected) in cases {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            #expect(
                AttachmentImporter.attachmentType(for: url) == expected,
                "Wrong type for \(filename)"
            )
        }
    }
}
