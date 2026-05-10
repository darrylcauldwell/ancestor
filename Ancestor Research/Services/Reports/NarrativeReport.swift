import Foundation
import SwiftUI

/// Narrative report renderer (DESIGN.md §7.9.4). Composes a biographical
/// summary with citation footnotes for one profile in either PDF or
/// Markdown form. The actual prose is built by `NarrativeComposer`; this
/// type owns the rendering pipelines.
@MainActor
enum NarrativeReport {

    /// Heuristic upper bound on paragraphs per page. Biographies tend to
    /// have 5–15 paragraphs; this fits roughly an A4 page at 11pt with
    /// citation footnotes underneath. Long lives split across pages.
    private static let paragraphsPerPage = 6

    static func renderPDF(
        profileID: String,
        paperSize: PaperSize,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote],
        hypotheses: [Hypothesis],
        questions: [OpenQuestion]
    ) -> Data? {
        guard let profile = snapshot.profiles[profileID] else { return nil }
        let document = NarrativeComposer.compose(
            profile: profile,
            snapshot: snapshot,
            notes: notes,
            hypotheses: hypotheses,
            questions: questions
        )

        // Single-page fast path — most biographies fit in one page.
        if document.paragraphs.count <= paragraphsPerPage {
            return PDFRenderer.renderToPDFData(paperSize: paperSize) {
                NarrativeReportPage(document: document)
            }
        }

        // Multi-page split. Each page repeats the header (genealogy
        // convention); footnotes appear only on the final page.
        let chunks = stride(from: 0, to: document.paragraphs.count, by: paragraphsPerPage).map {
            Array(document.paragraphs[$0..<min($0 + paragraphsPerPage, document.paragraphs.count)])
        }
        let pages: [NarrativeReportPage] = chunks.enumerated().map { idx, paragraphs in
            let isLast = idx == chunks.count - 1
            let footnotes = isLast ? document.footnotes : []
            let pageDocument = NarrativeDocument(
                title: document.title,
                paragraphs: paragraphs,
                footnotes: footnotes
            )
            return NarrativeReportPage(document: pageDocument)
        }
        return PDFRenderer.renderMultiPagePDF(paperSize: paperSize, pages: pages)
    }

    /// Pure-string variant — nonisolated so tests + non-MainActor callers
    /// can produce Markdown without hopping actors.
    nonisolated static func renderMarkdown(
        profileID: String,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote],
        hypotheses: [Hypothesis],
        questions: [OpenQuestion]
    ) -> String {
        guard let profile = snapshot.profiles[profileID] else {
            let fallback = snapshot.profiles[profileID]?.displayName ?? profileID
            return "# Narrative — \(fallback)\n\n_No profile data available._\n"
        }
        let document = NarrativeComposer.compose(
            profile: profile,
            snapshot: snapshot,
            notes: notes,
            hypotheses: hypotheses,
            questions: questions
        )

        var lines: [String] = []
        lines.append("# Narrative — \(document.title)")
        lines.append("")
        for paragraph in document.paragraphs {
            lines.append(NarrativeFootnoteFormatter.toMarkdown(paragraph))
            lines.append("")
        }
        if !document.footnotes.isEmpty {
            for (idx, footnote) in document.footnotes.enumerated() {
                lines.append("[^\(idx + 1)]: \(footnote)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
