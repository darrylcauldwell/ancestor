import Foundation
import SwiftUI

/// Pedigree chart renderer (DESIGN.md §7.9.2).
///
/// Layout: subject on the left, ancestors fanning right. Each generation
/// column doubles in row count (1 → 2 → 4 → 8 → 16). 4-gen ships 15 cells
/// (subject + 2 + 4 + 8) and 5-gen ships 31 (… + 16).
///
/// The renderer is split into:
///   - `buildAncestorMatrix(...)` — pure, testable graph traversal that
///     returns a `[[String?]]` indexed by `[generation][row]`.
///   - `PedigreeChartPage` — the SwiftUI layout that draws cells and
///     connector lines, wrapped into a single PDF page by `PDFRenderer`.
///
/// Paper sizing is handled by `PDFRenderer`. 5-gen on A4 is tight; A3 or
/// landscape A4 reads cleanly. The renderer doesn't error on a small page
/// — it lets cell content clip rather than failing the whole report.
@MainActor
enum PedigreeChartReport {

    /// Render a single-page PDF. Dispatches by `style` — rectangular layout
    /// (default) or fan-chart layout. Returns nil only if the underlying
    /// CGContext can't be created.
    static func renderPDF(
        profileID: String,
        generations: PedigreeGenerations,
        style: PedigreeStyle = .rectangular,
        showCompleteness: Bool,
        paperSize: PaperSize,
        snapshot: FamilyGraphSnapshot
    ) -> Data? {
        switch style {
        case .rectangular:
            return renderRectangularPDF(
                profileID: profileID,
                generations: generations,
                showCompleteness: showCompleteness,
                paperSize: paperSize,
                snapshot: snapshot
            )
        case .fan:
            return renderFanPDF(
                profileID: profileID,
                generations: generations,
                showCompleteness: showCompleteness,
                paperSize: paperSize,
                snapshot: snapshot
            )
        case .hourglass:
            return renderHourglassPDF(
                profileID: profileID,
                generations: generations,
                showCompleteness: showCompleteness,
                paperSize: paperSize,
                snapshot: snapshot
            )
        }
    }

    /// Render the traditional rectangular pedigree layout to PDF.
    static func renderRectangularPDF(
        profileID: String,
        generations: PedigreeGenerations,
        showCompleteness: Bool,
        paperSize: PaperSize,
        snapshot: FamilyGraphSnapshot
    ) -> Data? {
        PDFRenderer.renderToPDFData(paperSize: paperSize) {
            PedigreeChartPage(
                profileID: profileID,
                generations: generations,
                showCompleteness: showCompleteness,
                snapshot: snapshot
            )
        }
    }

    /// Render the fan-chart pedigree layout to PDF — subject at the centre,
    /// ancestor generations as concentric semicircular arcs above.
    static func renderFanPDF(
        profileID: String,
        generations: PedigreeGenerations,
        showCompleteness: Bool,
        paperSize: PaperSize,
        snapshot: FamilyGraphSnapshot
    ) -> Data? {
        PDFRenderer.renderToPDFData(paperSize: paperSize) {
            PedigreeFanChartPage(
                profileID: profileID,
                generations: generations,
                showCompleteness: showCompleteness,
                snapshot: snapshot
            )
        }
    }

    /// Render the hourglass pedigree layout to PDF — subject in the vertical
    /// middle of the page with ancestors flowing upward and descendants
    /// flowing downward (DESIGN.md §7.9.2). The `generations` parameter
    /// applies independently to each half (4-gen ⇒ 4 ancestor generations
    /// AND 4 descendant generations).
    static func renderHourglassPDF(
        profileID: String,
        generations: PedigreeGenerations,
        showCompleteness: Bool,
        paperSize: PaperSize,
        snapshot: FamilyGraphSnapshot
    ) -> Data? {
        PDFRenderer.renderToPDFData(paperSize: paperSize) {
            PedigreeHourglassChartPage(
                profileID: profileID,
                generations: generations,
                showCompleteness: showCompleteness,
                snapshot: snapshot
            )
        }
    }

    // MARK: - Ancestor walk (pure, testable)

    /// Walk the parent edges from `subjectID` outwards and produce a fixed
    /// matrix of optional ancestor IDs, suitable for a pedigree chart.
    ///
    /// Returns `[[String?]]` where `result[g][r]` is the profile ID for the
    /// ancestor in generation `g` (0 = subject) at row `r`. Row count
    /// doubles per generation: row 0 = paternal-side, with father = row 0
    /// and mother = row 1 of the next generation, recursively.
    ///
    /// Missing parents are returned as `nil` so the page can render dotted
    /// placeholders. Multiple parents of the same role beyond two are
    /// truncated; we take the first father edge and first mother edge we
    /// encounter (or the first two undifferentiated parents if no roles are
    /// recorded). This matches user expectation that pedigree charts show
    /// exactly one slot per parent role.
    ///
    /// - Parameters:
    ///   - subjectID: home person at column 0.
    ///   - generations: total columns (4 or 5 in M10).
    ///   - snapshot: family graph snapshot.
    static func buildAncestorMatrix(
        subjectID: String,
        generations: Int,
        snapshot: FamilyGraphSnapshot
    ) -> [[String?]] {
        precondition(generations >= 1, "generations must be >= 1")

        var matrix: [[String?]] = []
        // Column 0 is the subject (1 cell).
        matrix.append([subjectID])

        for col in 1..<generations {
            let prev = matrix[col - 1]
            var thisCol: [String?] = []
            thisCol.reserveCapacity(prev.count * 2)
            for childID in prev {
                let (father, mother) = parents(of: childID, in: snapshot)
                thisCol.append(father)
                thisCol.append(mother)
            }
            matrix.append(thisCol)
        }
        return matrix
    }

    /// Walk the child edges from `subjectID` outwards and produce a fixed
    /// matrix of optional descendant IDs, suitable for the lower half of an
    /// hourglass pedigree chart.
    ///
    /// Returns `[[String?]]` where `result[g][r]` is the profile ID for the
    /// descendant in generation `g` (0 = subject) at row `r`. Each generation
    /// uses up to `maxFanout` slots per parent — the first `maxFanout`
    /// children of each profile in the previous generation are kept, in the
    /// order their parent edges are stored. Remaining children are truncated
    /// so the chart has predictable column widths.
    ///
    /// Missing slots are returned as `nil`. Generation 0 always contains
    /// exactly one cell (the subject); subsequent generations are sized to
    /// the previous count × `maxFanout`.
    ///
    /// - Parameters:
    ///   - subjectID: home person at row 0.
    ///   - generations: total generation count (1 = subject only).
    ///   - maxFanout: how many children to draw per parent (default 2 to
    ///     keep visual width on par with the upper ancestor half).
    ///   - snapshot: family graph snapshot.
    static func buildDescendantMatrix(
        subjectID: String,
        generations: Int,
        maxFanout: Int = 2,
        snapshot: FamilyGraphSnapshot
    ) -> [[String?]] {
        precondition(generations >= 1, "generations must be >= 1")
        precondition(maxFanout >= 1, "maxFanout must be >= 1")

        var matrix: [[String?]] = []
        matrix.append([subjectID])

        for gen in 1..<generations {
            let prev = matrix[gen - 1]
            var thisGen: [String?] = []
            thisGen.reserveCapacity(prev.count * maxFanout)
            for parentID in prev {
                let kids = orderedChildren(of: parentID, in: snapshot)
                for slot in 0..<maxFanout {
                    if slot < kids.count {
                        thisGen.append(kids[slot])
                    } else {
                        thisGen.append(nil)
                    }
                }
            }
            matrix.append(thisGen)
        }
        return matrix
    }

    /// Resolve children of a profile in stored relationship order, deduped
    /// (a child can only appear once even if recorded via multiple edges).
    /// Returns an empty array when the parent ID is nil or unknown.
    private static func orderedChildren(
        of parentID: String?,
        in snapshot: FamilyGraphSnapshot
    ) -> [String] {
        guard let parentID, snapshot.profiles[parentID] != nil else {
            return []
        }
        var seen: Set<String> = []
        var ordered: [String] = []
        for rel in snapshot.relationships
        where rel.type == .parent && rel.from == parentID {
            if !seen.contains(rel.to), snapshot.profiles[rel.to] != nil {
                seen.insert(rel.to)
                ordered.append(rel.to)
            }
        }
        return ordered
    }

    /// Resolve the (father, mother) pair for a child profile from the
    /// snapshot. Roles drive ordering when present; otherwise the first two
    /// parent edges are used in their stored order. Extra parent edges are
    /// truncated — pedigree charts have exactly two slots per child.
    private static func parents(
        of childID: String?,
        in snapshot: FamilyGraphSnapshot
    ) -> (String?, String?) {
        guard let childID, snapshot.profiles[childID] != nil else {
            return (nil, nil)
        }
        let edges = snapshot.relationships.filter {
            $0.type == .parent && $0.to == childID
        }
        var father: String? = nil
        var mother: String? = nil
        var unroled: [String] = []

        for edge in edges {
            switch edge.role {
            case .father where father == nil:
                father = edge.from
            case .mother where mother == nil:
                mother = edge.from
            default:
                // Could be .unspecified, nil, or a duplicate role we ignore.
                if edge.role != .father && edge.role != .mother {
                    unroled.append(edge.from)
                }
            }
        }

        // Backfill empty slots from un-roled parent edges in stored order.
        for parentID in unroled {
            if father == nil {
                father = parentID
            } else if mother == nil {
                mother = parentID
            } else {
                break
            }
        }
        return (father, mother)
    }
}
