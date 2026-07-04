import Foundation

/// One of the four report shapes per DESIGN.md §7.9.
nonisolated enum ReportType: String, CaseIterable, Identifiable, Sendable {
    case pedigree           // Pedigree chart — ancestors of the subject
    case familyGroupSheet   // One family unit per page
    case narrative          // Biographical prose with citation footnotes
    case research           // Workbench-as-document

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pedigree: return "Pedigree chart"
        case .familyGroupSheet: return "Family group sheet"
        case .narrative: return "Narrative report"
        case .research: return "Research report"
        }
    }

    var systemImage: String {
        switch self {
        case .pedigree: return "tree"
        case .familyGroupSheet: return "person.3"
        case .narrative: return "doc.text"
        case .research: return "magnifyingglass.circle"
        }
    }

    var description: String {
        switch self {
        case .pedigree:
            return "Ancestors of one person in a traditional layout. Suitable for printing or sharing."
        case .familyGroupSheet:
            return "Parents and children with dates, locations, sources, and any attached notes."
        case .narrative:
            return "Plain-English biography with citations as footnotes. PDF and Markdown."
        case .research:
            return "What was investigated, what was found, what's still open. PDF and Markdown."
        }
    }

    /// Output formats this report can produce.
    var supportedFormats: [ReportFormat] {
        switch self {
        case .pedigree: return [.pdf]
        case .familyGroupSheet: return [.pdf]
        case .narrative: return [.pdf, .markdown]
        case .research: return [.pdf, .markdown]
        }
    }
}

/// Pedigree-specific generation count. 4-gen and 5-gen ship in M10; fan
/// and hourglass are designed but deferred to a future polish pass.
nonisolated enum PedigreeGenerations: Int, CaseIterable, Sendable {
    case four = 4
    case five = 5

    var displayName: String {
        switch self {
        case .four: return "4 generations (15 people)"
        case .five: return "5 generations (31 people)"
        }
    }
}

/// Pedigree layout style. The rectangular layout (default) puts the subject
/// on the left and ancestors fanning right in columns. The fan layout per
/// DESIGN.md §7.9.2 places the subject at the bottom centre with generations
/// as concentric semicircular arcs above — compact and visually appealing
/// for sharing. The hourglass layout puts the subject in the centre, with
/// ancestors flowing upward and descendants flowing downward — useful for
/// charts that show the subject's full vertical lineage on one page.
nonisolated enum PedigreeStyle: String, CaseIterable, Identifiable, Sendable {
    case rectangular
    case fan
    case hourglass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rectangular: return "Rectangular"
        case .fan: return "Fan"
        case .hourglass: return "Hourglass"
        }
    }
}

/// Output format the user selects in the picker. Drives file extension and
/// rendering pipeline (SwiftUI → PDF via ImageRenderer, or template strings).
nonisolated enum ReportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case markdown

    var id: String { rawValue }
    var displayName: String { self == .pdf ? "PDF" : "Markdown" }
    var fileExtension: String { self == .pdf ? "pdf" : "md" }
}

/// Standard page sizes supported by the PDF rendering pipeline. A4 and US
/// Letter cover the common case; A3 is provided for large pedigree charts.
nonisolated enum PaperSize: String, CaseIterable, Identifiable, Sendable {
    case a4
    case letter
    case a3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "US Letter"
        case .a3: return "A3"
        }
    }

    /// Dimensions in points (72 dpi). Portrait orientation; reports may
    /// rotate for charts that need landscape.
    var sizeInPoints: CGSize {
        switch self {
        case .a4: return CGSize(width: 595, height: 842)
        case .letter: return CGSize(width: 612, height: 792)
        case .a3: return CGSize(width: 842, height: 1191)
        }
    }
}

/// Bundle of options the user picks when generating a report. The
/// ReportGenerator routes by `type` and pulls the appropriate fields out.
/// Per-type options (generations, profileID, etc.) all live here so
/// callers don't need separate option types.
nonisolated struct ReportOptions: Sendable {
    var type: ReportType
    var format: ReportFormat
    var paperSize: PaperSize = .a4

    /// Subject profile for pedigree, narrative, family-group-sheet (parents
    /// section), and research-report scope.
    var profileID: String?

    /// Pedigree-specific.
    var pedigreeGenerations: PedigreeGenerations = .four

    /// Pedigree-specific layout style (rectangular vs fan).
    var pedigreeStyle: PedigreeStyle = .rectangular

    /// Whether to render completeness indicators on chart cells.
    var showCompleteness: Bool = true

    /// Family-group-sheet scope: when nil, regenerate for the family
    /// containing `profileID`.
    var familyID: UUID?

    /// Family-group-sheet batch mode (DESIGN.md §7.9.3): when true,
    /// `ReportGenerator` produces a single multi-page PDF containing every
    /// distinct family in the snapshot, ignoring `profileID`. Default false
    /// so existing callers keep the per-family path.
    var batchAllFamilies: Bool = false

    /// Research-report scope: which focus set to summarise. nil → use
    /// the active focus set if any, else the whole tree.
    var focusSetID: UUID?
}
