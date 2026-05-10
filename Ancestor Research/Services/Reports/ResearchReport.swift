import Foundation
import SwiftUI

/// Research report renderer (DESIGN.md §7.9.5).
///
/// The "workbench-as-document" — what was investigated, what was found,
/// what's still open. Sharing this with another researcher is the primary
/// way the app prevents duplicated effort.
///
/// Composition (selecting which profiles/questions/hypotheses are in scope,
/// deduplicating sources, grouping by status, …) lives in the
/// ``ResearchReportComposer`` so the structure can be unit-tested without
/// instantiating SwiftUI views.
@MainActor
enum ResearchReport {

    static func renderPDF(
        focusSetID: UUID?,
        paperSize: PaperSize,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote],
        questions: [OpenQuestion],
        hypotheses: [Hypothesis],
        focusSets: [FocusSet],
        sessions: [ResearchSession]
    ) -> Data? {
        let document = ResearchReportComposer.compose(
            focusSetID: focusSetID,
            snapshot: snapshot,
            notes: notes,
            questions: questions,
            hypotheses: hypotheses,
            focusSets: focusSets,
            sessions: sessions
        )
        return PDFRenderer.renderToPDFData(paperSize: paperSize) {
            ResearchReportPage(document: document)
        }
    }

    /// Pure-string variant — nonisolated so tests + non-MainActor callers
    /// can produce Markdown without hopping actors.
    nonisolated static func renderMarkdown(
        focusSetID: UUID?,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote],
        questions: [OpenQuestion],
        hypotheses: [Hypothesis],
        focusSets: [FocusSet],
        sessions: [ResearchSession]
    ) -> String {
        let doc = ResearchReportComposer.compose(
            focusSetID: focusSetID,
            snapshot: snapshot,
            notes: notes,
            questions: questions,
            hypotheses: hypotheses,
            focusSets: focusSets,
            sessions: sessions
        )
        return renderMarkdown(document: doc)
    }

    /// Render a composed document as a Markdown string. Section order
    /// matches DESIGN.md §7.9.5 and the SwiftUI page. Nonisolated so the
    /// composed-doc form can be called from tests without MainActor hops.
    nonisolated static func renderMarkdown(document doc: ResearchReportDocument) -> String {
        var out = ""
        out += "# Research Report\n\n"

        // Scope -------------------------------------------------------------
        out += "## Scope\n\n"
        out += "\(doc.scopeSummary)\n\n"

        // Questions investigated -------------------------------------------
        out += "## Questions investigated\n\n"
        if doc.questionsByStatus.values.allSatisfy({ $0.isEmpty }) {
            out += "_No questions in scope._\n\n"
        } else {
            for status in QuestionStatus.allCases {
                guard let qs = doc.questionsByStatus[status], !qs.isEmpty else { continue }
                out += "### \(status.displayName)\n\n"
                for q in qs {
                    out += "- **\(q.text)** _(priority: \(q.priority.displayName))_\n"
                    if !q.profileIDs.isEmpty {
                        let names = q.profileIDs
                            .map { doc.profileNames[$0] ?? $0 }
                            .joined(separator: ", ")
                        out += "  - Profiles: \(names)\n"
                    }
                    if let tried = q.triedSources, !tried.isEmpty {
                        out += "  - Tried: \(tried)\n"
                    }
                    if status == .resolved, let resolution = q.resolution, !resolution.isEmpty {
                        out += "  - Resolution: \(resolution)\n"
                    }
                }
                out += "\n"
            }
        }

        // Hypotheses --------------------------------------------------------
        out += "## Hypotheses\n\n"
        if doc.hypothesesByStatus.values.allSatisfy({ $0.isEmpty }) {
            out += "_No hypotheses in scope._\n\n"
        } else {
            for status in HypothesisStatus.allCases {
                guard let hs = doc.hypothesesByStatus[status], !hs.isEmpty else { continue }
                out += "### \(status.displayName)\n\n"
                for h in hs {
                    out += "- **\(h.claimSummary)** _(confidence: \(h.confidence.displayName))_\n"
                    if !h.reasoning.isEmpty {
                        out += "  - Reasoning: \(h.reasoning)\n"
                    }
                    out += "  - Supporting: \(h.supportingEvidence.count) · Contradicting: \(h.contradictingEvidence.count)\n"
                    if status == .dismissed, let reason = h.dismissalReason, !reason.isEmpty {
                        out += "  - Dismissed because: \(reason)\n"
                    }
                }
                out += "\n"
            }
        }

        // Findings ----------------------------------------------------------
        out += "## Findings\n\n"
        if doc.findings.isEmpty {
            out += "_No non-manual sources recorded in scope._\n\n"
        } else {
            for profile in doc.findings {
                let name = profile.displayName.isEmpty ? profile.id : profile.displayName
                let nonManualOrigins: [String] = Array(
                    Set(
                        profile.sources.values.flatMap { sources in
                            sources.compactMap { $0.origin.isManual ? nil : $0.origin.identifier }
                        }
                    )
                ).sorted()
                if nonManualOrigins.isEmpty {
                    out += "- \(name)\n"
                } else {
                    out += "- \(name) — sources: \(nonManualOrigins.joined(separator: ", "))\n"
                }
            }
            out += "\n"
        }

        // Still open --------------------------------------------------------
        out += "## Still open\n\n"
        if doc.stillOpen.isEmpty {
            out += "_Nothing outstanding._\n\n"
        } else {
            for line in doc.stillOpen {
                out += "- \(line)\n"
            }
            out += "\n"
        }

        // Sources consulted ------------------------------------------------
        out += "## Sources consulted\n\n"
        if doc.sourcesConsulted.isEmpty {
            out += "_No sources recorded._\n\n"
        } else {
            for line in doc.sourcesConsulted {
                out += "- \(line)\n"
            }
            out += "\n"
        }

        return out
    }
}
