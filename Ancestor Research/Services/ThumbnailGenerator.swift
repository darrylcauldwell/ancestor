import Foundation
import AppKit
import PDFKit

/// Generates a 256x256 JPEG thumbnail for an attachment so the gallery grid
/// can render fast without re-decoding originals. Output goes into the
/// project's thumbnails directory; the filename matches the attachment UUID
/// so the AppState delete path can clean it up by id.
nonisolated struct ThumbnailGenerator {
    static let thumbnailSize: CGFloat = 256

    /// Generate a thumbnail JPEG, write to `thumbnailsDir`, return the
    /// relative filename. Returns nil for transcriptions (no visual to show).
    /// Throws on I/O or rendering failure.
    @discardableResult
    static func generate(
        for attachment: Attachment,
        sourceURL: URL,
        thumbnailsDir: URL
    ) throws -> String? {
        switch attachment.mediaType {
        case .photo:
            return try generatePhotoThumbnail(
                attachment: attachment,
                sourceURL: sourceURL,
                thumbnailsDir: thumbnailsDir
            )
        case .document:
            return try generatePDFThumbnail(
                attachment: attachment,
                sourceURL: sourceURL,
                thumbnailsDir: thumbnailsDir
            )
        case .transcription:
            return nil
        }
    }

    private static func generatePhotoThumbnail(
        attachment: Attachment,
        sourceURL: URL,
        thumbnailsDir: URL
    ) throws -> String {
        guard let image = NSImage(contentsOf: sourceURL) else {
            throw ThumbnailError.cannotLoadImage(sourceURL)
        }
        let target = scaledSize(image.size, maxDimension: thumbnailSize)
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        scaled.unlockFocus()
        return try writeJPEG(scaled, attachmentID: attachment.id, dir: thumbnailsDir)
    }

    private static func generatePDFThumbnail(
        attachment: Attachment,
        sourceURL: URL,
        thumbnailsDir: URL
    ) throws -> String {
        guard let document = PDFDocument(url: sourceURL),
              let page = document.page(at: 0) else {
            throw ThumbnailError.cannotLoadPDF(sourceURL)
        }
        let pageBounds = page.bounds(for: .mediaBox)
        let target = scaledSize(pageBounds.size, maxDimension: thumbnailSize)
        let image = NSImage(size: target)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: target).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            let scaleX = target.width / pageBounds.width
            let scaleY = target.height / pageBounds.height
            context.scaleBy(x: scaleX, y: scaleY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        image.unlockFocus()
        return try writeJPEG(image, attachmentID: attachment.id, dir: thumbnailsDir)
    }

    private static func writeJPEG(_ image: NSImage, attachmentID: UUID, dir: URL) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpegData = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.8]
              ) else {
            throw ThumbnailError.encodingFailed
        }
        let filename = "\(attachmentID.uuidString).jpg"
        let destination = dir.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jpegData.write(to: destination, options: .atomic)
        return filename
    }

    /// Aspect-fit a source size into a square box with `maxDimension` on the
    /// longer side. Avoids upscaling — small images stay small.
    private static func scaledSize(_ original: CGSize, maxDimension: CGFloat) -> CGSize {
        guard original.width > 0, original.height > 0 else {
            return CGSize(width: maxDimension, height: maxDimension)
        }
        let scale = min(1.0, maxDimension / max(original.width, original.height))
        return CGSize(
            width: max(1, original.width * scale),
            height: max(1, original.height * scale)
        )
    }
}

nonisolated enum ThumbnailError: Error, LocalizedError {
    case cannotLoadImage(URL)
    case cannotLoadPDF(URL)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .cannotLoadImage(let url): return "Couldn't read image at \(url.lastPathComponent)."
        case .cannotLoadPDF(let url): return "Couldn't read PDF at \(url.lastPathComponent)."
        case .encodingFailed: return "Couldn't encode thumbnail JPEG."
        }
    }
}
