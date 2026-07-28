import SwiftUI
import AncestorKit

/// A per-record "verify at the source" affordance, shared by the cluster-review
/// record detail and the profile evidence expander.
///
/// Two behaviours, best-available per source:
///  - Records that carry a real per-record URL (FreeCEN, FamilySearch, Find a
///    Grave) get a true **View record** deep-link.
///  - Sources with no per-record URL and terms that forbid programmatic
///    access / pre-filling (FreeBMD, FreeREG) get a **Search** link to the
///    source's search page — the user reads the reference (shown in the
///    citation) and types it. No pre-fill, no scraping: just a browser hand-off.
struct SourceVerifyLink: View {
    let sourceID: String
    let citationURL: String?

    var body: some View {
        if let info = Self.info(sourceID: sourceID, citationURL: citationURL) {
            Link(destination: info.url) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.right.square")
                    Text(info.label)
                }
                .font(AppTypography.badge)
                .foregroundStyle(.blue)
            }
            .help(info.isDeepLink
                  ? "Open this record on \(Self.displayName(sourceID))"
                  : "Open \(Self.displayName(sourceID)) search — type the reference shown above to find and verify this entry")
        }
    }

    struct Info {
        let label: String
        let url: URL
        let isDeepLink: Bool
    }

    /// The link to show for a record, or nil when the source has no useful
    /// public destination (e.g. a prose-corpus or MLX pseudo-source).
    static func info(sourceID: String, citationURL: String?) -> Info? {
        // A real per-record URL beats a search page — link straight to it.
        if let raw = citationURL, !raw.isEmpty, let url = URL(string: raw) {
            return Info(label: "View on \(displayName(sourceID)) ↗", url: url, isDeepLink: true)
        }
        // Otherwise a compliant search-page hand-off, for the sources that have one.
        guard let url = searchURL(sourceID) else { return nil }
        return Info(label: "Search \(displayName(sourceID)) ↗", url: url, isDeepLink: false)
    }

    static func displayName(_ sourceID: String) -> String {
        switch sourceID.lowercased() {
        case "freebmd":      "FreeBMD"
        case "freecen":      "FreeCEN"
        case "freereg":      "FreeREG"
        case "familysearch": "FamilySearch"
        case "findagrave":   "Find a Grave"
        case "cwgc":         "CWGC"
        case "probate":      "Probate Search"
        default:              sourceID.uppercased()
        }
    }

    /// The public search page for sources without a per-record URL. Only
    /// FreeBMD/FreeREG rely on this (FreeCEN/FamilySearch/FindAGrave records
    /// carry their own URL); returns nil for sources with nowhere to send the user.
    private static func searchURL(_ sourceID: String) -> URL? {
        switch sourceID.lowercased() {
        case "freebmd": URL(string: "https://www.freebmd.org.uk/search")
        case "freereg": URL(string: "https://www.freereg.org.uk/search_queries/new")
        case "freecen": URL(string: "https://www.freecen.org.uk/search_records")
        default:        nil
        }
    }
}
