import SwiftUI
import UniformTypeIdentifiers

/// FileDocument wrapper for GEDCOM export via .fileExporter.
nonisolated struct GEDCOMDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let content: String

    init(snapshot: FamilyGraphSnapshot) {
        let result = GEDCOMExporter.export(snapshot)
        self.content = result.content
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.content = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = content.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
