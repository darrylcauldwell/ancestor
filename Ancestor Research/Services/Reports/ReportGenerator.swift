import Foundation
import SwiftUI

/// Top-level dispatcher for report generation. Per DESIGN.md §7.9, reports
/// are read-only projections of existing data — no new state, no side effects.
///
/// Each report type has its own renderer (`PedigreeChartReport`,
/// `FamilyGroupSheetReport`, `NarrativeReport`, `ResearchReport`). This
/// generator routes by type and returns the document bytes for the caller
/// to write to disk via the file exporter.
@MainActor
enum ReportGenerator {

    /// Output of a generation pass — bytes plus a default filename hint.
    struct Output: Sendable {
        let data: Data
        let suggestedFilename: String
        let format: ReportFormat
    }

    enum GenerationError: LocalizedError {
        case missingProfile
        case missingFamily
        case unsupportedFormat(ReportType, ReportFormat)
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingProfile:
                return "This report needs a profile — pick someone first."
            case .missingFamily:
                return "Couldn't resolve a family unit from the chosen profile."
            case .unsupportedFormat(let type, let format):
                return "\(type.displayName) doesn't support \(format.displayName) output."
            case .renderFailed(let detail):
                return "Failed to render report: \(detail)"
            }
        }
    }

    /// Generate the report described by `options`, drawing on the supplied
    /// snapshot + workbench arrays. Returns the document bytes; caller
    /// writes them to the user-chosen URL via NSSavePanel/fileExporter.
    static func generate(
        options: ReportOptions,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote] = [],
        questions: [OpenQuestion] = [],
        hypotheses: [Hypothesis] = [],
        focusSets: [FocusSet] = [],
        sessions: [ResearchSession] = []
    ) throws -> Output {
        guard options.type.supportedFormats.contains(options.format) else {
            throw GenerationError.unsupportedFormat(options.type, options.format)
        }

        switch options.type {
        case .pedigree:
            guard let profileID = options.profileID,
                  snapshot.profiles[profileID] != nil else {
                throw GenerationError.missingProfile
            }
            let pdfData: Data? = {
                switch options.pedigreeStyle {
                case .rectangular:
                    return PedigreeChartReport.renderRectangularPDF(
                        profileID: profileID,
                        generations: options.pedigreeGenerations,
                        showCompleteness: options.showCompleteness,
                        paperSize: options.paperSize,
                        snapshot: snapshot
                    )
                case .fan:
                    return PedigreeChartReport.renderFanPDF(
                        profileID: profileID,
                        generations: options.pedigreeGenerations,
                        showCompleteness: options.showCompleteness,
                        paperSize: options.paperSize,
                        snapshot: snapshot
                    )
                case .hourglass:
                    return PedigreeChartReport.renderHourglassPDF(
                        profileID: profileID,
                        generations: options.pedigreeGenerations,
                        showCompleteness: options.showCompleteness,
                        paperSize: options.paperSize,
                        snapshot: snapshot
                    )
                }
            }()
            guard let data = pdfData else {
                throw GenerationError.renderFailed("PDF context unavailable.")
            }
            let suffix: String = {
                switch options.pedigreeStyle {
                case .rectangular: return "pedigree"
                case .fan: return "pedigree-fan"
                case .hourglass: return "pedigree-hourglass"
                }
            }()
            return Output(
                data: data,
                suggestedFilename: filename(for: profileID, snapshot: snapshot, suffix: suffix, ext: options.format.fileExtension),
                format: options.format
            )

        case .familyGroupSheet:
            if options.batchAllFamilies {
                guard let data = FamilyGroupSheetReport.renderAllFamiliesPDF(
                    paperSize: options.paperSize,
                    snapshot: snapshot,
                    notes: notes
                ) else {
                    throw GenerationError.renderFailed("No families to export.")
                }
                return Output(
                    data: data,
                    suggestedFilename: "all-families.pdf",
                    format: options.format
                )
            }
            guard let profileID = options.profileID,
                  snapshot.profiles[profileID] != nil else {
                throw GenerationError.missingProfile
            }
            guard let data = FamilyGroupSheetReport.renderPDF(
                profileID: profileID,
                paperSize: options.paperSize,
                snapshot: snapshot,
                notes: notes
            ) else {
                throw GenerationError.renderFailed("PDF context unavailable.")
            }
            return Output(
                data: data,
                suggestedFilename: filename(for: profileID, snapshot: snapshot, suffix: "family-group", ext: options.format.fileExtension),
                format: options.format
            )

        case .narrative:
            guard let profileID = options.profileID,
                  snapshot.profiles[profileID] != nil else {
                throw GenerationError.missingProfile
            }
            switch options.format {
            case .pdf:
                guard let data = NarrativeReport.renderPDF(
                    profileID: profileID,
                    paperSize: options.paperSize,
                    snapshot: snapshot,
                    notes: notes,
                    hypotheses: hypotheses,
                    questions: questions
                ) else {
                    throw GenerationError.renderFailed("PDF context unavailable.")
                }
                return Output(
                    data: data,
                    suggestedFilename: filename(for: profileID, snapshot: snapshot, suffix: "narrative", ext: "pdf"),
                    format: .pdf
                )
            case .markdown:
                let md = NarrativeReport.renderMarkdown(
                    profileID: profileID,
                    snapshot: snapshot,
                    notes: notes,
                    hypotheses: hypotheses,
                    questions: questions
                )
                return Output(
                    data: Data(md.utf8),
                    suggestedFilename: filename(for: profileID, snapshot: snapshot, suffix: "narrative", ext: "md"),
                    format: .markdown
                )
            }

        case .research:
            switch options.format {
            case .pdf:
                guard let data = ResearchReport.renderPDF(
                    focusSetID: options.focusSetID,
                    paperSize: options.paperSize,
                    snapshot: snapshot,
                    notes: notes,
                    questions: questions,
                    hypotheses: hypotheses,
                    focusSets: focusSets,
                    sessions: sessions
                ) else {
                    throw GenerationError.renderFailed("PDF context unavailable.")
                }
                return Output(
                    data: data,
                    suggestedFilename: "research-report.\(options.format.fileExtension)",
                    format: .pdf
                )
            case .markdown:
                let md = ResearchReport.renderMarkdown(
                    focusSetID: options.focusSetID,
                    snapshot: snapshot,
                    notes: notes,
                    questions: questions,
                    hypotheses: hypotheses,
                    focusSets: focusSets,
                    sessions: sessions
                )
                return Output(
                    data: Data(md.utf8),
                    suggestedFilename: "research-report.md",
                    format: .markdown
                )
            }
        }
    }

    /// Build a filesystem-safe filename like "thomas-land-pedigree.pdf".
    private static func filename(
        for profileID: String,
        snapshot: FamilyGraphSnapshot,
        suffix: String,
        ext: String
    ) -> String {
        let raw = snapshot.profiles[profileID]?.displayName ?? profileID
        let slug = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let base = slug.isEmpty ? "report" : slug
        return "\(base)-\(suffix).\(ext)"
    }
}
