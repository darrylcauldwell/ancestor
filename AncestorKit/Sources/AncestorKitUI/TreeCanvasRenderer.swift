import SwiftUI
import AncestorKit

/// Fonts and platform colours the tree renderer needs, injected by the
/// host app (macOS passes AppTypography tokens + controlAccentColor;
/// viewer targets supply their own). Canvas text uses fixed sizes —
/// Canvas doesn't support dynamic type; text scales with canvas zoom.
public struct TreeCanvasTheme: Sendable {
    public let name: Font
    public let nameSmall: Font
    public let dates: Font
    public let location: Font
    public let badge: Font
    public let infoIcon: Font
    public let arrow: Font
    public let controlAccent: Color

    public init(
        name: Font, nameSmall: Font, dates: Font, location: Font,
        badge: Font, infoIcon: Font, arrow: Font, controlAccent: Color
    ) {
        self.name = name
        self.nameSmall = nameSmall
        self.dates = dates
        self.location = location
        self.badge = badge
        self.infoIcon = infoIcon
        self.arrow = arrow
        self.controlAccent = controlAccent
    }
}

/// Portable Canvas draw core for the family tree — extracted from the
/// macOS `TreeGraphView` (Phase 2 slice 2.2, ARCHITECTURE_REVIEW_2026-07.md)
/// so iPad and tvOS shells render the identical tree. Pure functions of
/// (layout geometry, state flags, theme): no view-model or app-state
/// reads — the host's Canvas closure computes flags and passes them in.
public enum TreeCanvasRenderer {

    /// Draw a single parent with all children as one connected path.
    /// Parent → vertical drop → horizontal bar → vertical drops to each child.
    /// No overlapping segments.
    public static func drawParentChildGroup(context: inout GraphicsContext, from: CGPoint, children: [CGPoint]) {
        guard !children.isEmpty else { return }

        let fromBottom = CGPoint(x: from.x, y: from.y + TreeLayout.nodeHeight / 2)
        let childTops = children.map { CGPoint(x: $0.x, y: $0.y - TreeLayout.nodeHeight / 2) }
        let midY = (fromBottom.y + childTops[0].y) / 2

        var path = Path()

        // Parent down to midY
        path.move(to: fromBottom)
        path.addLine(to: CGPoint(x: fromBottom.x, y: midY))

        // Horizontal bar spanning all children
        let leftX = min(fromBottom.x, childTops.map(\.x).min()!)
        let rightX = max(fromBottom.x, childTops.map(\.x).max()!)
        path.move(to: CGPoint(x: leftX, y: midY))
        path.addLine(to: CGPoint(x: rightX, y: midY))

        // Vertical drops to each child
        for top in childTops {
            path.move(to: CGPoint(x: top.x, y: midY))
            path.addLine(to: top)
        }

        context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1.5)
    }

    public static func drawEdge(context: inout GraphicsContext, from: CGPoint, to: CGPoint, type: RelationshipType) {
        var path = Path()
        if type == .spouse {
            let fromRight = CGPoint(x: from.x + TreeLayout.nodeWidth / 2, y: from.y)
            let toLeft = CGPoint(x: to.x - TreeLayout.nodeWidth / 2, y: to.y)
            path.move(to: fromRight)
            path.addLine(to: toLeft)
            context.stroke(path, with: .color(.pink.opacity(0.6)), lineWidth: 2)
        } else {
            let fromBottom = CGPoint(x: from.x, y: from.y + TreeLayout.nodeHeight / 2)
            let toTop = CGPoint(x: to.x, y: to.y - TreeLayout.nodeHeight / 2)
            let midY = (fromBottom.y + toTop.y) / 2

            path.move(to: fromBottom)
            path.addLine(to: CGPoint(x: fromBottom.x, y: midY))
            path.addLine(to: CGPoint(x: toTop.x, y: midY))
            path.addLine(to: toTop)
            context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1.5)
        }
    }

    /// Hypothetical relationships render as dashed, muted lines that connect
    /// the centres of the two profiles. We don't pick a routing direction
    /// (parent/spouse) because hypotheses span both — a dashed straight line
    /// reads as "tentative" and stays visually distinct from confirmed edges.
    public static func drawHypotheticalEdge(context: inout GraphicsContext, from: CGPoint, to: CGPoint) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(
            path,
            with: .color(.purple.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
        )
    }

    public static func drawNode(
        context: inout GraphicsContext,
        node: TreeLayout.LayoutNode,
        rect: CGRect,
        scale: Double,
        snapshot: FamilyGraphSnapshot,
        theme: TreeCanvasTheme,
        isSelected: Bool,
        isRoot: Bool,
        isHovered: Bool,
        dimmed: Bool,
        inFocus: Bool = false,
        hasNote: Bool = false,
        hasOpenQuestion: Bool = false,
        hasTentativeFact: Bool = false,
        showsCompletenessBadge: Bool = true
    ) {
        let cornerRadius: Double = 12
        let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

        // Background — completeness gradient
        guard let profile = node.profile, let comp = node.completeness else { return }
        let ratio = comp.maximum > 0 ? Double(comp.score) / Double(comp.maximum) : 0
        let fillColor: Color = if isSelected {
            .accentColor.opacity(0.3)
        } else if isRoot {
            .blue.opacity(0.15)
        } else if dimmed {
            .gray.opacity(0.1)
        } else {
            Color(
                red: 1.0 - ratio * 0.7,
                green: 0.3 + ratio * 0.7,
                blue: 0.3
            ).opacity(0.15)
        }
        context.fill(path, with: .color(fillColor))

        // Border — with hover highlight (instant, no animation).
        // M24 — for default (non-selected/root/hovered) nodes, the border
        // line weight is derived from completeness ratio so colourblind and
        // high-contrast users can read "this profile needs work" without
        // depending on the red→green fill gradient. Incomplete profiles
        // render a thicker ring; complete profiles a thin one.
        let borderColor: Color
        let borderWidth: Double
        if isSelected {
            borderColor = .accentColor
            borderWidth = 2.5
        } else if isRoot {
            borderColor = .blue.opacity(0.5)
            borderWidth = 2
        } else if isHovered {
            borderColor = .secondary.opacity(0.5)
            borderWidth = 1.5
        } else {
            borderColor = .secondary.opacity(0.2)
            borderWidth = HighContrastShape.completenessRingWeight(ratio: ratio)
        }
        context.stroke(path, with: .color(borderColor), lineWidth: borderWidth)

        // M8 W3 — focus ring drawn just outside the border for profiles in
        // the active focus set. DESIGN.md §7.7.7 "subtle ring or background".
        if inFocus {
            let ringRect = rect.insetBy(dx: -3, dy: -3)
            let ringPath = Path(roundedRect: ringRect, cornerRadius: cornerRadius + 3)
            context.stroke(
                ringPath,
                with: .color(.accentColor.opacity(0.6)),
                style: StrokeStyle(lineWidth: 2)
            )
        }

        // Name
        let name = profile.displayName
        if scale > 0.4 {
            let nameText = Text(name)
                .font(theme.name)
                .foregroundStyle(dimmed ? .tertiary : .primary)
            context.draw(
                context.resolve(nameText),
                at: CGPoint(x: rect.midX, y: rect.midY - 12),
                anchor: .center
            )

            // Birth/death years with living-person handling
            var dateStr = ""
            if let by = profile.birthDate?.bestYear {
                dateStr += "b.\(by)"
            }
            if let dy = profile.deathDate?.bestYear {
                dateStr += dateStr.isEmpty ? "d.\(dy)" : " — d.\(dy)"
            } else if comp.potentiallyLiving && profile.birthDate != nil {
                dateStr += dateStr.isEmpty ? "living" : " — living"
            }
            if !dateStr.isEmpty {
                let dateText = Text(dateStr)
                    .font(theme.dates)
                    .foregroundStyle(.secondary)
                context.draw(
                    context.resolve(dateText),
                    at: CGPoint(x: rect.midX, y: rect.midY + 8),
                    anchor: .center
                )
            }

            // Birth location at higher zoom
            if scale > 0.7, let loc = profile.birthLocation {
                let shortLoc = loc.components(separatedBy: ",").first ?? loc
                let locText = Text(shortLoc)
                    .font(theme.location)
                    .foregroundStyle(.tertiary)
                context.draw(
                    context.resolve(locText),
                    at: CGPoint(x: rect.midX, y: rect.midY + 24),
                    anchor: .center
                )
            }
        } else {
            // Low zoom: name only
            let nameText = Text(name)
                .font(theme.nameSmall)
                .foregroundStyle(dimmed ? .quaternary : .secondary)
            context.draw(
                context.resolve(nameText),
                at: CGPoint(x: rect.midX, y: rect.midY),
                anchor: .center
            )
        }

        // Completeness badge — researcher UI; viewer shells pass false
        // (their completeness is recomputed over a REDACTED projection,
        // so the score would mislead — PHASE4_VIEWER_SPEC decision #4).
        if showsCompletenessBadge {
            let badge = Text("\(comp.score)/\(comp.maximum)")
                .font(theme.badge)
                .foregroundStyle(ratio >= 1.0 ? .green : .orange)
            context.draw(
                context.resolve(badge),
                at: CGPoint(x: rect.maxX - 18, y: rect.minY + 12),
                anchor: .center
            )
        }

        // M12 — tentative-fact marker. A small "~" glyph in the top-left
        // signals at least one core field (name / birth / death) has only
        // tentative sources. Sits opposite the completeness badge so the
        // two never collide. DESIGN.md §5.14.
        if hasTentativeFact {
            let marker = Text("~")
                .font(theme.infoIcon)
                .foregroundStyle(.orange)
            context.draw(
                context.resolve(marker),
                at: CGPoint(x: rect.minX + 12, y: rect.minY + 12),
                anchor: .center
            )
        }

        // M8 W1+W2 indicators — note dot and open-question marker, drawn in
        // the bottom-left so they don't collide with the completeness badge
        // (top-right) or the ⓘ icon (bottom-right).
        // DESIGN.md §7.7.7 "Profile with attached note" / "Profile with open question".
        if hasNote {
            let icon = Text(Image(systemName: "note.text"))
                .font(theme.badge)
                .foregroundStyle(.secondary)
            context.draw(
                context.resolve(icon),
                at: CGPoint(x: rect.minX + 10, y: rect.maxY - 10),
                anchor: .center
            )
        }
        if hasOpenQuestion {
            let icon = Text("?")
                .font(theme.badge)
                .foregroundStyle(.orange)
            context.draw(
                context.resolve(icon),
                at: CGPoint(x: rect.minX + (hasNote ? 24 : 10), y: rect.maxY - 10),
                anchor: .center
            )
        }

        // ⓘ icon — shown on selected node at ALL zoom levels
        if isSelected {
            let iconSize = TreeLayout.infoIconSize
            let iconX = rect.maxX - iconSize / 2 - 4
            let iconY = rect.maxY - iconSize / 2 - 4
            let icon = Text("ⓘ")
                .font(theme.infoIcon)
                .foregroundStyle(theme.controlAccent)
            context.draw(
                context.resolve(icon),
                at: CGPoint(x: iconX, y: iconY),
                anchor: .center
            )
        }

        // Arrow indicators — recenter triggers
        if node.hasMoreAncestors {
            let parentCount = snapshot.parentsOf(node.id).count
            let label = Text("▲ \(parentCount) parent\(parentCount == 1 ? "" : "s")")
                .font(theme.arrow)
                .foregroundStyle(theme.controlAccent)
            context.draw(
                context.resolve(label),
                at: CGPoint(x: rect.midX, y: rect.minY - 12),
                anchor: .center
            )
        }
        if node.hasMoreDescendants {
            let childCount = snapshot.childrenOf(node.id).count
            let label = Text("▼ \(childCount) child\(childCount == 1 ? "" : "ren")")
                .font(theme.arrow)
                .foregroundStyle(theme.controlAccent)
            context.draw(
                context.resolve(label),
                at: CGPoint(x: rect.midX, y: rect.maxY + 12),
                anchor: .center
            )
        }
    }

    public static func drawGhostNode(context: inout GraphicsContext, node: TreeLayout.LayoutNode, rect: CGRect, theme: TreeCanvasTheme) {
        let cornerRadius: Double = 10
        let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

        // Dashed border, no fill
        context.stroke(path, with: .color(.secondary.opacity(0.2)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // "?" label
        let label = Text("?")
            .font(theme.name)
            .foregroundStyle(.secondary.opacity(0.4))
        context.draw(context.resolve(label),
                     at: CGPoint(x: rect.midX, y: rect.midY - 6),
                     anchor: .center)

        // Role subtitle from enum
        let subtitle: String
        if case .ghost(_, let role) = node.kind {
            switch role {
            case .father: subtitle = "Unknown father"
            case .mother: subtitle = "Unknown mother"
            case .unknown: subtitle = "Unknown"
            }
        } else {
            subtitle = "Unknown"
        }
        let subText = Text(subtitle)
            .font(theme.location)
            .foregroundStyle(.secondary.opacity(0.3))
        context.draw(context.resolve(subText),
                     at: CGPoint(x: rect.midX, y: rect.midY + 10),
                     anchor: .center)
    }
}
