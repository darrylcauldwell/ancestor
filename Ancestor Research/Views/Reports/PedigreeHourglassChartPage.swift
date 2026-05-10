import SwiftUI

/// SwiftUI page view for an hourglass pedigree chart (DESIGN.md §7.9.2).
///
/// Layout: the subject sits in the vertical middle of the page, centred
/// horizontally. Ancestors expand upward (parents → grandparents → …) like
/// the rectangular layout but flowing up; descendants expand downward
/// (children → grandchildren → …) in a mirrored tree. Connector lines are
/// drawn behind the cells via a `Path` overlay so they line up with cell
/// centres exactly.
///
/// `generations` applies to each half independently. A 4-gen hourglass is
/// 4 ancestor generations (subject + 3 ancestor rows) PLUS 4 descendant
/// generations (subject + 3 descendant rows) — note the subject is shared
/// so the visual consists of the subject row, three rows above, and three
/// rows below. Empty ancestor slots render as dotted "?" placeholders.
/// When the subject has no children at all, the lower half collapses and
/// only the ancestor half is drawn.
@MainActor
struct PedigreeHourglassChartPage: View {
    let profileID: String
    let generations: PedigreeGenerations
    let showCompleteness: Bool
    let snapshot: FamilyGraphSnapshot

    /// Outer page padding (points). Generous so cells aren't crammed against
    /// the paper edge when printed.
    private let pagePadding: CGFloat = 28

    /// Cell dimensions. Slightly smaller for 5-gen so it can fit the same
    /// page without overflow. Same scale as the rectangular layout.
    private var cellWidth: CGFloat {
        generations == .four ? 110 : 88
    }
    private var cellHeight: CGFloat {
        generations == .four ? 44 : 36
    }

    private var nameFont: Font {
        generations == .four ? .system(size: 9, weight: .semibold) : .system(size: 7.5, weight: .semibold)
    }
    private var datesFont: Font {
        generations == .four ? .system(size: 7) : .system(size: 6)
    }
    private var badgeFont: Font {
        generations == .four ? .system(size: 7, weight: .semibold) : .system(size: 6, weight: .semibold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            GeometryReader { geo in
                chartCanvas(in: geo.size)
            }
        }
        .padding(pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    // MARK: - Header

    private var subjectName: String {
        snapshot.profiles[profileID]?.displayName ?? profileID
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pedigree hourglass chart")
                .font(.system(size: 16, weight: .bold))
            Text("\(subjectName) — \(generations.displayName) each way")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart canvas

    /// Total generations per half (e.g. 4 means subject + 3 ancestor rows).
    private var halfGenerations: Int { generations.rawValue }

    /// Number of ancestor rows beyond the subject (subject row not counted).
    private var ancestorRowCount: Int { max(halfGenerations - 1, 0) }

    /// Number of descendant rows beyond the subject (subject row not counted).
    private var descendantRowCount: Int { max(halfGenerations - 1, 0) }

    @ViewBuilder
    private func chartCanvas(in size: CGSize) -> some View {
        let ancestors = PedigreeChartReport.buildAncestorMatrix(
            subjectID: profileID,
            generations: halfGenerations,
            snapshot: snapshot
        )
        let descendants = PedigreeChartReport.buildDescendantMatrix(
            subjectID: profileID,
            generations: halfGenerations,
            maxFanout: 2,
            snapshot: snapshot
        )

        // Suppress lower half when the subject has no descendants at all.
        let hasDescendants = descendants
            .dropFirst()
            .flatMap { $0 }
            .contains(where: { $0 != nil })

        let layout = computeLayout(in: size, drawDescendants: hasDescendants)
        let ancestorPositions = ancestorCellCentres(layout: layout)
        let descendantPositions = hasDescendants
            ? descendantCellCentres(layout: layout, descendants: descendants)
            : []

        ZStack(alignment: .topLeading) {
            // Connectors first (drawn underneath cells)
            connectorLayer(
                ancestorPositions: ancestorPositions,
                descendantPositions: descendantPositions,
                descendants: descendants,
                layout: layout
            )

            // Ancestor cells (gen 1..ancestorRowCount). Generation 0 is the
            // shared subject and rendered separately below.
            ForEach(1..<max(ancestorPositions.count, 1), id: \.self) { gen in
                ForEach(0..<ancestorPositions[gen].count, id: \.self) { slot in
                    let centre = ancestorPositions[gen][slot]
                    let id = ancestors[gen][slot]
                    cell(for: id)
                        .frame(width: cellWidth, height: cellHeight)
                        .position(x: centre.x, y: centre.y)
                }
            }

            // Descendant cells, if drawn.
            if hasDescendants {
                ForEach(1..<max(descendantPositions.count, 1), id: \.self) { gen in
                    ForEach(0..<descendantPositions[gen].count, id: \.self) { slot in
                        if let centre = descendantPositions[gen][slot],
                           let id = descendants[gen][slot] {
                            cell(for: id)
                                .frame(width: cellWidth, height: cellHeight)
                                .position(x: centre.x, y: centre.y)
                        }
                    }
                }
            }

            // Subject cell — shared between halves, drawn last so it sits
            // above any connectors that meet at its edges.
            cell(for: profileID, emphasis: true)
                .frame(width: cellWidth, height: cellHeight)
                .position(x: layout.subjectCentre.x, y: layout.subjectCentre.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Layout math

    /// Geometry computed once for the whole canvas — the subject's centre
    /// point and per-row vertical strides for both halves.
    private struct Layout {
        let canvasSize: CGSize
        let subjectCentre: CGPoint
        /// Y centre of ancestor row N (1...ancestorRowCount). Index 0 is the
        /// subject row (== subjectCentre.y).
        let ancestorRowY: [CGFloat]
        /// Y centre of descendant row N (1...descendantRowCount). Index 0 is
        /// the subject row. Empty when the lower half is suppressed.
        let descendantRowY: [CGFloat]
    }

    /// Compute vertical positions for the subject row and each ancestor /
    /// descendant generation row. Outer rows get the same row height — the
    /// design intentionally uses uniform stride so connectors align cleanly.
    private func computeLayout(in size: CGSize, drawDescendants: Bool) -> Layout {
        let height = max(size.height, cellHeight * CGFloat(halfGenerations * 2 + 1))
        let centreY: CGFloat = {
            // Centre on the canvas vertically. When descendants are absent
            // the chart looks better with the subject pushed toward the
            // bottom (so ancestors fill the page upward).
            if drawDescendants {
                return height / 2
            } else {
                return height - cellHeight / 2 - 4
            }
        }()
        let centreX = size.width / 2

        let subjectCentre = CGPoint(x: centreX, y: centreY)

        // Upper half — distribute ancestor rows evenly between the top of
        // the canvas and the subject's top edge. Outer (oldest) ancestors
        // sit highest; row 1 (parents) is closest to the subject.
        var ancestorYs: [CGFloat] = [centreY]
        if ancestorRowCount > 0 {
            let upperTop = cellHeight / 2 + 4
            let upperBottom = centreY - cellHeight / 2 - 4
            let stride = (upperBottom - upperTop) / CGFloat(ancestorRowCount)
            for gen in 1...ancestorRowCount {
                // Row 1 (parents) is just above the subject; the loop walks
                // upward so gen N sits N strides above the subject row.
                let y = upperBottom - stride * CGFloat(gen - 1)
                // y is the centre of the row that's gen-1 strides above the
                // subject's top — i.e. parents directly above the subject.
                ancestorYs.append(y)
            }
        }

        // Lower half — symmetric to the upper half.
        var descendantYs: [CGFloat] = [centreY]
        if drawDescendants && descendantRowCount > 0 {
            let lowerTop = centreY + cellHeight / 2 + 4
            let lowerBottom = height - cellHeight / 2 - 4
            let stride = (lowerBottom - lowerTop) / CGFloat(descendantRowCount)
            for gen in 1...descendantRowCount {
                let y = lowerTop + stride * CGFloat(gen - 1)
                descendantYs.append(y)
            }
        }

        return Layout(
            canvasSize: CGSize(width: size.width, height: height),
            subjectCentre: subjectCentre,
            ancestorRowY: ancestorYs,
            descendantRowY: descendantYs
        )
    }

    /// Compute centre points for every ancestor cell. Result is indexed
    /// `[generation][slot]`. Generation 0 contains a single point at the
    /// subject centre. Each subsequent generation has 2^gen slots distributed
    /// horizontally across the page.
    private func ancestorCellCentres(layout: Layout) -> [[CGPoint]] {
        var out: [[CGPoint]] = [[layout.subjectCentre]]
        let canvasWidth = layout.canvasSize.width
        for gen in 1...max(ancestorRowCount, 0) {
            let count = 1 << gen
            let slotWidth = canvasWidth / CGFloat(count)
            var row: [CGPoint] = []
            row.reserveCapacity(count)
            let y = layout.ancestorRowY[gen]
            for slot in 0..<count {
                let x = slotWidth * (CGFloat(slot) + 0.5)
                row.append(CGPoint(x: x, y: y))
            }
            out.append(row)
        }
        return out
    }

    /// Compute centre points for every descendant cell. Slots without a
    /// resolved profile are returned as `nil` so the connector layer can
    /// skip them. Each generation has `prevCount * maxFanout` slots laid
    /// out so siblings cluster under their parent.
    private func descendantCellCentres(
        layout: Layout,
        descendants: [[String?]]
    ) -> [[CGPoint?]] {
        var out: [[CGPoint?]] = [[layout.subjectCentre]]
        let canvasWidth = layout.canvasSize.width

        for gen in 1...max(descendantRowCount, 0) {
            let count = descendants[gen].count
            let slotWidth = canvasWidth / CGFloat(max(count, 1))
            var row: [CGPoint?] = []
            row.reserveCapacity(count)
            let y = layout.descendantRowY[gen]
            for slot in 0..<count {
                if descendants[gen][slot] != nil {
                    let x = slotWidth * (CGFloat(slot) + 0.5)
                    row.append(CGPoint(x: x, y: y))
                } else {
                    row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }

    // MARK: - Connectors

    /// Draw thin parent-to-child connector lines. Ancestor connectors run
    /// from the top edge of the child up to the bottom edge of the parent
    /// with a horizontal jog at the midpoint (T-junction). Descendant
    /// connectors mirror that, running from the bottom of each parent down
    /// to the top of each child.
    private func connectorLayer(
        ancestorPositions: [[CGPoint]],
        descendantPositions: [[CGPoint?]],
        descendants: [[String?]],
        layout: Layout
    ) -> some View {
        Path { path in
            // Ancestor connectors. For each generation N (0..<count-1), draw
            // a T from the child cell up to its two parents in generation N+1.
            for gen in 0..<max(ancestorPositions.count - 1, 0) {
                let childCount = ancestorPositions[gen].count
                for childIdx in 0..<childCount {
                    let childCentre = ancestorPositions[gen][childIdx]
                    let childTop = CGPoint(
                        x: childCentre.x,
                        y: childCentre.y - cellHeight / 2
                    )
                    let fatherSlot = childIdx * 2
                    let motherSlot = childIdx * 2 + 1
                    for parentSlot in [fatherSlot, motherSlot]
                    where parentSlot < ancestorPositions[gen + 1].count {
                        let parentCentre = ancestorPositions[gen + 1][parentSlot]
                        let parentBottom = CGPoint(
                            x: parentCentre.x,
                            y: parentCentre.y + cellHeight / 2
                        )
                        let midY = (childTop.y + parentBottom.y) / 2
                        path.move(to: childTop)
                        path.addLine(to: CGPoint(x: childTop.x, y: midY))
                        path.addLine(to: CGPoint(x: parentBottom.x, y: midY))
                        path.addLine(to: parentBottom)
                    }
                }
            }

            // Descendant connectors. Mirror image: from each parent's bottom
            // edge down to each child's top edge. Skip nil children entirely.
            for gen in 0..<max(descendantPositions.count - 1, 0) {
                let parentCount = descendantPositions[gen].count
                for parentIdx in 0..<parentCount {
                    guard let parentCentre = descendantPositions[gen][parentIdx] else {
                        continue
                    }
                    let parentBottom = CGPoint(
                        x: parentCentre.x,
                        y: parentCentre.y + cellHeight / 2
                    )
                    let childStart = parentIdx * 2
                    let childEnd = childStart + 2
                    for childIdx in childStart..<min(childEnd, descendantPositions[gen + 1].count) {
                        guard let childCentre = descendantPositions[gen + 1][childIdx] else {
                            continue
                        }
                        let childTop = CGPoint(
                            x: childCentre.x,
                            y: childCentre.y - cellHeight / 2
                        )
                        let midY = (parentBottom.y + childTop.y) / 2
                        path.move(to: parentBottom)
                        path.addLine(to: CGPoint(x: parentBottom.x, y: midY))
                        path.addLine(to: CGPoint(x: childTop.x, y: midY))
                        path.addLine(to: childTop)
                    }
                }
            }
        }
        .stroke(
            Color.gray.opacity(0.6),
            style: StrokeStyle(lineWidth: 0.6, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Cells

    @ViewBuilder
    private func cell(for id: String?, emphasis: Bool = false) -> some View {
        if let id, let profile = snapshot.profiles[id] {
            filledCell(profile: profile, emphasis: emphasis)
        } else {
            emptyCell
        }
    }

    private func filledCell(profile: Profile, emphasis: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 4) {
                Text(displayName(for: profile))
                    .font(nameFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if showCompleteness {
                    completenessBadge(for: profile.id)
                }
            }
            Text(datesLine(for: profile))
                .font(datesFont)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(emphasis ? Color.yellow.opacity(0.10) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    emphasis ? Color.black.opacity(0.9) : Color.black.opacity(0.7),
                    lineWidth: emphasis ? 0.9 : 0.6
                )
        )
    }

    private var emptyCell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    Color.gray.opacity(0.5),
                    style: StrokeStyle(lineWidth: 0.6, dash: [3, 2])
                )
            Text("?")
                .font(nameFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cell content helpers

    private func displayName(for profile: Profile) -> String {
        let name = profile.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "(unknown)" : name
    }

    private func datesLine(for profile: Profile) -> String {
        let birth = profile.birthDate?.bestYear.map(String.init)
        let death = profile.deathDate?.bestYear.map(String.init)

        switch (birth, death) {
        case (let b?, let d?): return "b. \(b) — d. \(d)"
        case (let b?, nil):    return "b. \(b)"
        case (nil, let d?):    return "d. \(d)"
        case (nil, nil):       return "—"
        }
    }

    @ViewBuilder
    private func completenessBadge(for id: String) -> some View {
        let comp = snapshot.completeness(for: id)
        let label = "\(comp.score)/\(comp.maximum)"
        let tint: Color = {
            let ratio = Double(comp.score) / Double(max(comp.maximum, 1))
            if ratio >= 0.85 { return .green }
            if ratio >= 0.5  { return .orange }
            return .red
        }()
        Text(label)
            .font(badgeFont)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(
                Capsule().fill(tint.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(tint.opacity(0.6), lineWidth: 0.4)
            )
    }
}
