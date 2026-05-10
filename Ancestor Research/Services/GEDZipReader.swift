import Foundation

/// GEDZip (.gdz) container reader (M15).
///
/// Per GEDCOM 7.0 spec, a `.gdz` is a zip archive containing:
///   - `gedcom.ged` at the root — the GEDCOM 7.0 text payload
///   - `media/` directory with the media files referenced by `OBJE` records
///
/// We unzip the archive into a temp directory, locate `gedcom.ged`, and
/// enumerate any media files. The caller is responsible for copying media
/// out and deleting the staging dir when done. Mirrors the unzip pattern in
/// `ProjectArchive` — shells out to `/usr/bin/unzip` since it's available
/// on every macOS install and works fine inside the sandbox for paths the
/// app already owns (temp dir + a user-granted file URL).
nonisolated enum GEDZipReader {

    /// The result of reading a `.gdz` container. The staging directory
    /// remains on disk after this call returns — the caller must delete it
    /// once any media files have been copied into their final destination.
    nonisolated struct ReadResult: Sendable {
        let gedcomText: String
        /// Caller is responsible for removing this directory after use.
        let mediaStagingDir: URL
        /// Absolute URLs to every file under `media/` (recursive). Empty
        /// when the archive carries no media.
        let mediaFiles: [URL]
    }

    /// Read a `.gdz` archive and return its GEDCOM text + staged media
    /// files. The caller owns `mediaStagingDir` after this call.
    static func read(from archiveURL: URL) throws -> ReadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw GEDZipWriter.Error.unzipFailed("Source archive does not exist at \(archiveURL.path)")
        }

        let stagingURL = fm.temporaryDirectory
            .appendingPathComponent("gedzip-in-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        // Unzip into the staging dir. On any failure we tear the dir down
        // so we don't leak — but on success we hand it back to the caller.
        do {
            try runUnzip(archiveURL: archiveURL, destinationURL: stagingURL)
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw error
        }

        // Locate `gedcom.ged`. Standards-compliant archives put it at the
        // root; some archive tools (or users zipping a folder) wrap the
        // payload one level deep, so fall back to a single nested scan.
        let resolvedRoot: URL
        let rootCandidate = stagingURL.appendingPathComponent("gedcom.ged")
        if fm.fileExists(atPath: rootCandidate.path) {
            resolvedRoot = stagingURL
        } else if let nested = findNestedRoot(in: stagingURL, fm: fm) {
            resolvedRoot = nested
        } else {
            try? fm.removeItem(at: stagingURL)
            throw GEDZipWriter.Error.missingGEDCOMInArchive
        }

        let gedURL = resolvedRoot.appendingPathComponent("gedcom.ged")
        let gedcomText: String
        do {
            gedcomText = try String(contentsOf: gedURL, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw GEDZipWriter.Error.unzipFailed("Failed to read gedcom.ged: \(error.localizedDescription)")
        }

        // Enumerate the `media/` subtree if present. Recursive walk so
        // arbitrary on-disk hierarchies (e.g. `media/photos/2023/foo.jpg`)
        // are surfaced as a flat URL list. The relative path from
        // `media/` is recoverable by stripping `mediaRoot.path` from
        // each URL — left to the caller.
        var mediaFiles: [URL] = []
        let mediaRoot = resolvedRoot.appendingPathComponent("media", isDirectory: true)
        if fm.fileExists(atPath: mediaRoot.path) {
            mediaFiles = enumerateFiles(under: mediaRoot, fm: fm)
        }

        return ReadResult(
            gedcomText: gedcomText,
            mediaStagingDir: stagingURL,
            mediaFiles: mediaFiles
        )
    }

    // MARK: - Internals

    private static func runUnzip(archiveURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archiveURL.path, "-d", destinationURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw GEDZipWriter.Error.unzipFailed("Failed to launch unzip: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw GEDZipWriter.Error.unzipFailed("unzip exited \(process.terminationStatus): \(message)")
        }
    }

    /// Walk one directory level deep to handle archives where the payload
    /// is nested inside a single sub-folder (a common zip convention).
    private static func findNestedRoot(in stagingURL: URL, fm: FileManager) -> URL? {
        guard let entries = try? fm.contentsOfDirectory(
            at: stagingURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: entry.appendingPathComponent("gedcom.ged").path) {
                return entry
            }
        }
        return nil
    }

    /// Recursive file enumeration under `root`. Skips directories and
    /// hidden entries (e.g. macOS `.DS_Store`).
    private static func enumerateFiles(under root: URL, fm: FileManager) -> [URL] {
        var results: [URL] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }
        for case let fileURL as URL in enumerator {
            if let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
               isFile {
                results.append(fileURL)
            }
        }
        return results
    }
}
