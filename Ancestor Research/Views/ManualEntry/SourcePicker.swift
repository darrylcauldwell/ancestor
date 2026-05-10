import SwiftUI

/// Picker for the source of a manually-entered fact.
/// Shows the 5 manual source options with short labels.
struct SourcePicker: View {
    @Binding var selection: SourceOrigin
    var label: String = "Source"

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Personal Memory").tag(SourceOrigin.manualMemory)
            Text("Document").tag(SourceOrigin.manualDocument)
            Text("Record").tag(SourceOrigin.manualRecord)
            Text("Estimate").tag(SourceOrigin.manualEstimate)
            Text("Manual (other)").tag(SourceOrigin.manual)
        }
    }

    /// Human-readable label for any source — used by callers showing the
    /// current selection inline (e.g. EditPersonView field rows).
    static func displayName(for origin: SourceOrigin) -> String {
        switch origin {
        case .manualMemory: return "Personal Memory"
        case .manualDocument: return "Document"
        case .manualRecord: return "Record"
        case .manualEstimate: return "Estimate"
        case .manual: return "Manual"
        case .gedcom: return "GEDCOM"
        case .wikitree: return "WikiTree"
        case .freebmd: return "FreeBMD"
        case .freecen: return "FreeCEN"
        case .freereg: return "FreeREG"
        case .familysearch: return "FamilySearch"
        case .cwgc: return "CWGC"
        default: return origin.identifier
        }
    }
}
