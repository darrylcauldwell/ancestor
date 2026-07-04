import Foundation
import UniformTypeIdentifiers

/// Selectable GEDCOM export format (M15). Combines spec version + container
/// kind so a single enum drives both the on-disk file extension and the
/// branching inside `GEDCOMExporter`.
nonisolated enum GEDCOMFormat: String, CaseIterable, Sendable, Codable {
    /// GEDCOM 5.5.1 plain `.ged` — the legacy interchange format. Default.
    /// Most third-party tools (Ancestry, MyHeritage, FamilySearch) expect this.
    case v5_5_1 = "5.5.1"

    /// GEDCOM 7.0 plain `.ged`. Cleaner tag semantics + UTF-8 mandatory.
    /// Adoption is growing but still patchy in third-party tools.
    case v7_0 = "7.0"

    /// GEDCOM 7.0 inside a `.gdz` GEDZip container — bundles attachments
    /// alongside the `.ged` so the export is self-contained.
    case gedZip_7_0 = "7.0.gdz"

    var displayName: String {
        switch self {
        case .v5_5_1: return "GEDCOM 5.5.1 (most compatible)"
        case .v7_0: return "GEDCOM 7.0"
        case .gedZip_7_0: return "GEDCOM 7.0 + media (.gdz)"
        }
    }

    /// Filename extension (no dot).
    var fileExtension: String {
        switch self {
        case .v5_5_1, .v7_0: return "ged"
        case .gedZip_7_0: return "gdz"
        }
    }

    /// UTType for the export `.fileExporter`. `.gdz` is registered via
    /// `dev.dreamfold.ancestor-archive` parent (zip) — fall back to plain
    /// data when the system doesn't know the extension.
    var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .data
    }

    /// True when the format wraps the `.ged` payload in a zip container
    /// alongside the project's media files.
    var isContainer: Bool {
        switch self {
        case .v5_5_1, .v7_0: return false
        case .gedZip_7_0: return true
        }
    }

    /// Major spec version number — drives branching in the exporter and parser.
    var version: GEDCOMVersion {
        switch self {
        case .v5_5_1: return .v5_5_1
        case .v7_0, .gedZip_7_0: return .v7_0
        }
    }
}

/// Spec version. The exporter and parser branch on this for the small set
/// of structural differences between 5.5.1 and 7.0.
nonisolated enum GEDCOMVersion: String, Sendable, Codable {
    case v5_5_1
    case v7_0

    /// Header version string emitted in `1 GEDC / 2 VERS`.
    var versionString: String {
        switch self {
        case .v5_5_1: return "5.5.1"
        case .v7_0: return "7.0"
        }
    }
}
