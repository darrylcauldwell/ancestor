import Foundation
import SwiftUI

/// Copies a user-chosen file into the project's media directory, extracts
/// EXIF metadata for photos, generates a thumbnail, and records the
/// `Attachment` row through `AppState`. Per DESIGN.md §5.15.
@MainActor
@Observable
final class AttachmentImporter {
    /// Last surfaced error, if any. UI may bind to this for an inline message.
    var lastError: String?

    /// Import a file. Returns the persisted `Attachment` or nil on failure.
    func importFile(
        from sourceURL: URL,
        target: AttachmentTarget,
        in appState: AppState
    ) async -> Attachment? {
        guard let project = appState.currentProject else {
            lastError = "No project is open."
            return nil
        }

        let attachmentID = UUID()
        let mediaType = AttachmentImporter.attachmentType(for: sourceURL)
        let ext = sourceURL.pathExtension.isEmpty
            ? defaultExtension(for: mediaType)
            : sourceURL.pathExtension
        let destFilename = "\(attachmentID.uuidString).\(ext)"
        let mediaDir = ProjectStore.mediaDirectory(for: project.id)
        let thumbsDir = ProjectStore.thumbnailsDirectory(for: project.id)
        let destination = mediaDir.appendingPathComponent(destFilename)

        // Security-scoped resource handling for fileImporter URLs. Matches the
        // pattern used by GEDCOM import (commit 28e91ee).
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            // If the destination already exists (rare — UUID collision), drop it.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            lastError = "Couldn't copy file: \(error.localizedDescription)"
            return nil
        }

        // EXIF for photos only.
        var dateTaken: Date?
        var locationTaken: String?
        if mediaType == .photo, let exif = EXIFExtractor.extract(from: destination) {
            dateTaken = exif.dateTaken
            locationTaken = exif.locationTaken
        }

        let attachment = Attachment(
            id: attachmentID,
            filename: sourceURL.lastPathComponent,
            mediaType: mediaType,
            caption: nil,
            dateTaken: dateTaken,
            locationTaken: locationTaken,
            relativePath: destFilename,
            attachedTo: target,
            addedAt: Date()
        )

        // Thumbnails are best-effort — failure shouldn't kill the import. The
        // gallery falls back to the SF Symbol icon.
        do {
            _ = try ThumbnailGenerator.generate(
                for: attachment,
                sourceURL: destination,
                thumbnailsDir: thumbsDir
            )
        } catch {
            lastError = "Thumbnail failed: \(error.localizedDescription)"
        }

        return appState.addAttachment(attachment)
    }

    /// Save typed-in transcription text as a `.txt` file in the media dir,
    /// then persist it as an `Attachment`. Used by the "Type a transcription"
    /// flow in the import sheet.
    func importTranscription(
        text: String,
        caption: String?,
        target: AttachmentTarget,
        in appState: AppState
    ) async -> Attachment? {
        guard let project = appState.currentProject else {
            lastError = "No project is open."
            return nil
        }
        let attachmentID = UUID()
        let mediaDir = ProjectStore.mediaDirectory(for: project.id)
        let destFilename = "\(attachmentID.uuidString).txt"
        let destination = mediaDir.appendingPathComponent(destFilename)
        do {
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            try text.data(using: .utf8)?.write(to: destination, options: .atomic)
        } catch {
            lastError = "Couldn't save transcription: \(error.localizedDescription)"
            return nil
        }
        let attachment = Attachment(
            id: attachmentID,
            filename: destFilename,
            mediaType: .transcription,
            caption: caption,
            dateTaken: nil,
            locationTaken: nil,
            relativePath: destFilename,
            attachedTo: target,
            addedAt: Date()
        )
        return appState.addAttachment(attachment)
    }

    /// Map a file extension to an `AttachmentType`. Defaults to `.document`
    /// for anything we don't recognise as photo/transcription.
    nonisolated static func attachmentType(for url: URL) -> AttachmentType {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "heic", "heif", "png", "tiff", "tif", "gif":
            return .photo
        case "txt", "md", "markdown":
            return .transcription
        default:
            return .document
        }
    }

    private nonisolated func defaultExtension(for type: AttachmentType) -> String {
        switch type {
        case .photo: return "jpg"
        case .document: return "pdf"
        case .transcription: return "txt"
        }
    }
}
