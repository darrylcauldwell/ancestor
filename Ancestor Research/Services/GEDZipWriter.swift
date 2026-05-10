import Foundation

/// GEDZip (.gdz) container writer (M15).
///
/// Per GEDCOM 7.0 spec, a `.gdz` is a zip archive whose contents are:
///   - `gedcom.ged` at the root — the GEDCOM 7.0 text payload
///   - `media/` directory holding the media files referenced by `OBJE` records
///
/// Implementation mirrors `ProjectArchive`: stage the contents into a temp
/// directory, shell out to `/usr/bin/zip` to produce the archive, read the
/// resulting bytes, and clean up. We return the bytes (rather than writing
/// straight to a final URL) because `GEDCOMDocument` is a `FileDocument`
/// and the SwiftUI `.fileExporter` API hands us a write configuration after
/// the fact — the Document model needs the final bytes in hand.
nonisolated enum GEDZipWriter {
    enum Error: Swift.Error, LocalizedError {
        case archiveCommandFailed(String)
        case missingGEDCOMInArchive
        case unzipFailed(String)

        var errorDescription: String? {
            switch self {
            case .archiveCommandFailed(let detail):
                return "GEDZip archive command failed: \(detail)"
            case .missingGEDCOMInArchive:
                return "GEDZip archive does not contain a gedcom.ged at its root."
            case .unzipFailed(let detail):
                return "GEDZip unzip failed: \(detail)"
            }
        }
    }

    /// Bundle a GEDCOM 7.0 text payload + the project's media files into a
    /// `.gdz` zip archive. Returns the archive bytes.
    ///
    /// Attachments whose file is missing on disk are skipped silently — the
    /// `OBJE` `FILE` reference in the `.ged` will still point at the missing
    /// path, but the archive itself remains valid for the surviving files.
    static func write(
        gedcomText: String,
        attachments: [Attachment],
        projectID: UUID
    ) throws -> Data {
        let fm = FileManager.default
        let stagingURL = fm.temporaryDirectory
            .appendingPathComponent("gedzip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingURL) }

        // 1. Write `gedcom.ged` at the staging root. UTF-8 is mandatory in
        //    GEDCOM 7.0, which is the only spec version that uses GEDZip.
        let gedURL = stagingURL.appendingPathComponent("gedcom.ged")
        try gedcomText.write(to: gedURL, atomically: true, encoding: .utf8)

        // 2. Stage media files under `media/{relativePath}`. Preserve the
        //    relative tree so OBJE FILE references resolve correctly.
        let mediaStaging = stagingURL.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: mediaStaging, withIntermediateDirectories: true)
        for attachment in attachments {
            let source = ProjectStore.absoluteURL(for: attachment, in: projectID)
            guard fm.fileExists(atPath: source.path) else { continue }
            let dest = mediaStaging.appendingPathComponent(attachment.relativePath)
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Defensive: if a previous loop iteration staged the same path,
            // remove it so copyItem doesn't fail on collision.
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
        }

        // 3. Zip the staging dir into an archive inside a sibling temp dir
        //    so the archive itself isn't part of the staged payload. (If we
        //    wrote it inside `stagingURL`, the second `zip -r .` invocation
        //    would try to include the in-progress archive.)
        let archiveURL = fm.temporaryDirectory
            .appendingPathComponent("gedzip-out-\(UUID().uuidString).gdz")
        defer { try? fm.removeItem(at: archiveURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", archiveURL.path, "."]
        process.currentDirectoryURL = stagingURL
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()  // discard
        do {
            try process.run()
        } catch {
            throw Error.archiveCommandFailed("Failed to launch zip: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw Error.archiveCommandFailed("zip exited \(process.terminationStatus): \(message)")
        }

        // 4. Read the resulting bytes back. The caller (GEDCOMDocument)
        //    routes them through `.fileExporter` to the user-picked URL.
        return try Data(contentsOf: archiveURL)
    }
}
