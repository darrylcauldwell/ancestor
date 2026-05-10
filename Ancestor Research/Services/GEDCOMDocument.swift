import SwiftUI
import UniformTypeIdentifiers

/// FileDocument wrapper for GEDCOM export via .fileExporter. Holds raw
/// bytes so it can serve both the plain-text `.ged` path and the M15
/// GEDZip `.gdz` container path through one type.
nonisolated struct GEDCOMDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .data] }

    let payload: Data
    let format: GEDCOMFormat

    /// Backwards-compat: the text-only string view of the GEDCOM body.
    /// Returns "" for `.gdz` since that's a zip container.
    var content: String {
        format.isContainer ? "" : (String(data: payload, encoding: .utf8) ?? "")
    }

    init(snapshot: FamilyGraphSnapshot) {
        let result = GEDCOMExporter.export(snapshot, format: .v5_5_1)
        self.payload = Data(result.content.utf8)
        self.format = .v5_5_1
    }

    /// Convenience initialiser for the M13/M14/M15 export path. Pulls
    /// attachments + life events off the DB; threads format and the
    /// sensitive filter through. For `.gdz`, the GEDZip writer produces
    /// the zip container; for plain text formats, the bytes are the
    /// `.ged` UTF-8 payload.
    init(
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase,
        projectID: UUID? = nil,
        excludeSensitive: Bool = false,
        format: GEDCOMFormat = .v5_5_1
    ) {
        let attachments = (try? db.loadAttachments()) ?? []
        let lifeEvents = (try? db.loadAllLifeEvents()) ?? []

        // M16.13 — gather workbench-only categories so the export's
        // `dropped[]` log can list exactly what stayed behind. Best-effort:
        // any loader that throws contributes zero rather than aborting the
        // export.
        let summary = WorkbenchExportSummary(
            hypothesisCount: (try? db.loadHypotheses())?.count ?? 0,
            focusSetCount: (try? db.loadFocusSets())?.count ?? 0,
            transactionCount: (try? db.loadTransactions(limit: Int.max))?.count ?? 0,
            workbenchNoteCount: (try? db.loadNotes())?.count ?? 0
        )

        let result = GEDCOMExporter.export(
            snapshot,
            attachments: attachments,
            lifeEvents: lifeEvents,
            excludeSensitive: excludeSensitive,
            format: format,
            workbenchSummary: summary
        )
        if format.isContainer, let projectID {
            // M15 — GEDZip container assembled by GEDZipWriter (Agent Z2).
            // Falls back to the raw text bytes if the writer hasn't been
            // wired yet, so the file picker still gets *something*.
            if let zipped = try? GEDZipWriter.write(
                gedcomText: result.content,
                attachments: attachments,
                projectID: projectID
            ) {
                self.payload = zipped
            } else {
                self.payload = Data(result.content.utf8)
            }
        } else {
            self.payload = Data(result.content.utf8)
        }
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.payload = data
        self.format = .v5_5_1
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: payload)
    }
}
