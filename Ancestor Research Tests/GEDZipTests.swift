import Testing
import Foundation
@testable import Ancestor_Research

/// M15 — GEDZip (.gdz) container read + write. Exercises the writer and
/// reader through realistic round-trip scenarios. Tests use the system
/// `/usr/bin/zip` and `/usr/bin/unzip` since the implementation does too.
struct GEDZipTests {

    private static let sampleGEDCOM = """
    0 HEAD
    1 GEDC
    2 VERS 7.0
    1 SOUR Ancestor Research
    0 @I1@ INDI
    1 NAME Test /Person/
    0 TRLR
    """

    /// Build a fake attachment + write a placeholder file at the project's
    /// expected absolute path so the writer has something to stage.
    @discardableResult
    private func makeStagedAttachment(
        projectID: UUID,
        relativePath: String,
        contents: String = "fake-media-bytes"
    ) throws -> Ancestor_Research.Attachment {
        let dest = ProjectStore.absoluteURL(
            for: Ancestor_Research.Attachment(
                id: UUID(),
                filename: relativePath,
                mediaType: .photo,
                caption: nil,
                dateTaken: nil,
                locationTaken: nil,
                relativePath: relativePath,
                attachedTo: .profile(id: "P1"),
                addedAt: Date()
            ),
            in: projectID
        )
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)!.write(to: dest)
        return Ancestor_Research.Attachment(
            id: UUID(),
            filename: relativePath,
            mediaType: .photo,
            caption: nil,
            dateTaken: nil,
            locationTaken: nil,
            relativePath: relativePath,
            attachedTo: .profile(id: "P1"),
            addedAt: Date()
        )
    }

    /// Clean up a per-project media tree to keep test runs hermetic.
    private func cleanupProjectMedia(_ projectID: UUID) {
        try? FileManager.default.removeItem(
            at: ProjectStore.projectsDirectory
                .appendingPathComponent(projectID.uuidString, isDirectory: true)
        )
    }

    // MARK: - Writer

    @Test func gedZipWriterProducesNonEmptyArchive() throws {
        let projectID = UUID()
        defer { cleanupProjectMedia(projectID) }

        let bytes = try GEDZipWriter.write(
            gedcomText: Self.sampleGEDCOM,
            attachments: [],
            projectID: projectID
        )

        #expect(!bytes.isEmpty, "Archive bytes should not be empty")
        // PK\x03\x04 — local file header magic for every well-formed zip.
        #expect(bytes.count >= 4)
        let magic = Array(bytes.prefix(4))
        #expect(
            magic == [0x50, 0x4B, 0x03, 0x04],
            "First four bytes should be the zip local-header magic"
        )
    }

    @Test func gedZipWriterIncludesMediaFiles() throws {
        let projectID = UUID()
        defer { cleanupProjectMedia(projectID) }

        let attachment = try makeStagedAttachment(
            projectID: projectID,
            relativePath: "photos/family.jpg",
            contents: "JPG-PLACEHOLDER"
        )

        let bytes = try GEDZipWriter.write(
            gedcomText: Self.sampleGEDCOM,
            attachments: [attachment],
            projectID: projectID
        )

        // Persist the archive to disk + unzip it into a verification dir
        // so we can check the staged structure on disk.
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-\(UUID().uuidString).gdz")
        try bytes.write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let verifyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: verifyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: verifyDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archiveURL.path, "-d", verifyDir.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "unzip should succeed")

        let mediaPath = verifyDir
            .appendingPathComponent("media")
            .appendingPathComponent("photos")
            .appendingPathComponent("family.jpg")
        #expect(
            FileManager.default.fileExists(atPath: mediaPath.path),
            "media/photos/family.jpg should be present in the unzipped archive"
        )

        let gedPath = verifyDir.appendingPathComponent("gedcom.ged")
        #expect(
            FileManager.default.fileExists(atPath: gedPath.path),
            "gedcom.ged should be at the archive root"
        )
    }

    // MARK: - Reader (round-trip)

    @Test func gedZipReaderRoundTripsGEDCOMText() throws {
        let projectID = UUID()
        defer { cleanupProjectMedia(projectID) }

        let bytes = try GEDZipWriter.write(
            gedcomText: Self.sampleGEDCOM,
            attachments: [],
            projectID: projectID
        )
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(UUID().uuidString).gdz")
        try bytes.write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let result = try GEDZipReader.read(from: archiveURL)
        defer { try? FileManager.default.removeItem(at: result.mediaStagingDir) }

        #expect(result.gedcomText == Self.sampleGEDCOM)
    }

    @Test func gedZipReaderEnumeratesMediaFiles() throws {
        let projectID = UUID()
        defer { cleanupProjectMedia(projectID) }

        let attachments = try [
            makeStagedAttachment(projectID: projectID, relativePath: "a.jpg"),
            makeStagedAttachment(projectID: projectID, relativePath: "sub/b.jpg"),
            makeStagedAttachment(projectID: projectID, relativePath: "sub/deeper/c.jpg")
        ]

        let bytes = try GEDZipWriter.write(
            gedcomText: Self.sampleGEDCOM,
            attachments: attachments,
            projectID: projectID
        )
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-media-\(UUID().uuidString).gdz")
        try bytes.write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let result = try GEDZipReader.read(from: archiveURL)
        defer { try? FileManager.default.removeItem(at: result.mediaStagingDir) }

        #expect(result.mediaFiles.count == 3, "Expected 3 staged media files, got \(result.mediaFiles.count)")
    }

    @Test func gedZipReaderHandlesArchiveWithNoMedia() throws {
        let projectID = UUID()
        defer { cleanupProjectMedia(projectID) }

        let bytes = try GEDZipWriter.write(
            gedcomText: Self.sampleGEDCOM,
            attachments: [],
            projectID: projectID
        )
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-empty-\(UUID().uuidString).gdz")
        try bytes.write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let result = try GEDZipReader.read(from: archiveURL)
        defer { try? FileManager.default.removeItem(at: result.mediaStagingDir) }

        #expect(result.mediaFiles.isEmpty)
        #expect(!result.gedcomText.isEmpty)
        #expect(result.gedcomText.contains("0 HEAD"))
    }
}
