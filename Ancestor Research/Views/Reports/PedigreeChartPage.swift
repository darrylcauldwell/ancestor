import SwiftUI

/// SwiftUI page view for a pedigree chart, sized to fill a `PaperSize`
/// (DESIGN.md §7.9.2). 4 or 5 generations, ancestors fanning right from
/// the subject. Empty slots render as dotted "?" placeholders. Connector
/// lines are drawn behind the cells via a `Path` overlay so they line up
/// with the centre of each cell exactly.
///
/// The view is deliberately reusable for previews and tests — it takes a
/// fully-resolved `FamilyGraphSnapshot` and a precomputed ancestor list.
@MainActor
struct PedigreeChartPage: View {
    let profileID: String
    let generations: PedigreeGenerations
    let showCompleteness: Bool
    let snapshot: FamilyGraphSnapshot

    /// Outer page padding (points). Generous so cells aren't crammed against
    /// the paper edge when printed.
    private let pagePadding: CGFloat = 28

    /// Horizontal connector run between columns.
    private let columnGap: CGFloat = 14

    /// Cell dimensions. Slightly smaller for 5-gen so it can fit the same
    /// page without overflow.
    private var cellWidth: CGFloat {
        generations == .four ? 140 : 110
    }
    private var cellHeight: CGFloat {
        generations == .four ? 56 : 44
    }

    private var nameFont: Font {
        generations == .four ? .system(size: 10, weight: .semibold) : .system(size: 8.5, weight: .semibold)
    }
    private var datesFont: Font {
        generations == .four ? .system(size: 8) : .system(size: 7)
    }
    private var locationFont: Font {
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
            Text("Pedigree chart")
                .font(.system(size: 16, weight: .bold))
            Text("\(subjectName) — \(generations.displayName)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart canvas

    /// Returns the column index for the page (0 = subject, rightmost = oldest gen).
    private var columns: Int { generations.rawValue }

    /// Total number of cells in the rightmost column.
    private var maxRows: Int { 1 << (columns - 1) }   // 8 for 4-gen, 16 for 5-gen

    /// Compute every cell's centre position in a fixed-size coordinate space.
    private func cellCentres(in size: CGSize) -> [[CGPoint]] {
        let usableHeight = max(size.height, cellHeight * CGFloat(maxRows))
        let usableWidth = max(size.width, (cellWidth + columnGap) * CGFloat(columns))

        // Per-column horizontal spacing — distribute columns evenly across width.
        let columnStride = (usableWidth - cellWidth) / CGFloat(max(columns - 1, 1))

        var positions: [[CGPoint]] = []
        for col in 0..<columns {
            let count = 1 << col              // 1, 2, 4, 8, 16
            let slotHeight = usableHeight / CGFloat(count)
            var colPositions: [CGPoint] = []
            for row in 0..<count {
                let x = cellWidth / 2 + columnStride * CGFloat(col)
                let y = slotHeight * (CGFloat(row) + 0.5)
                colPositions.append(CGPoint(x: x, y: y))
            }
            positions.append(colPositions)
        }
        return positions
    }

    @ViewBuilder
    private func chartCanvas(in size: CGSize) -> some View {
        let positions = cellCentres(in: size)
        let ancestors = PedigreeChartReport.buildAncestorMatrix(
            subjectID: profileID,
            generations: generations.rawValue,
            snapshot: snapshot
        )

        ZStack(alignment: .topLeading) {
            // Connectors first (drawn underneath cells)
            connectorLayer(positions: positions, ancestors: ancestors)

            // Cells on top
            ForEach(0..<columns, id: \.self) { col in
                ForEach(0..<positions[col].count, id: \.self) { row in
                    let centre = positions[col][row]
                    let id = ancestors[col][row]
                    cell(for: id)
                        .frame(width: cellWidth, height: cellHeight)
                        .position(x: centre.x, y: centre.y)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Connectors

    /// Draw thin parent-to-child connector lines between generation N and N+1.
    /// In a pedigree, the "parent" cells (rightward) connect back to their
    /// "child" cell (leftward). Each child has up to two parents.
    private func connectorLayer(
        positions: [[CGPoint]],
        ancestors: [[String?]]
    ) -> some View {
        Path { path in
            for col in 0..<(columns - 1) {
                let childCount = 1 << col
                for childRow in 0..<childCount {
                    let childCentre = positions[col][childRow]
                    let fatherRow = childRow * 2
                    let motherRow = childRow * 2 + 1
                    // Connector point on the right edge of the child cell.
                    let childRight = CGPoint(
                        x: childCentre.x + cellWidth / 2,
                        y: childCentre.y
                    )

                    for parentRow in [fatherRow, motherRow] {
                        let parentCentre = positions[col + 1][parentRow]
                        let parentLeft = CGPoint(
                            x: parentCentre.x - cellWidth / 2,
                            y: parentCentre.y
                        )
                        // Right-angled "elbow" — out, up/down, into the parent cell.
                        let midX = (childRight.x + parentLeft.x) / 2
                        path.move(to: childRight)
                        path.addLine(to: CGPoint(x: midX, y: childRight.y))
                        path.addLine(to: CGPoint(x: midX, y: parentLeft.y))
                        path.addLine(to: parentLeft)
                    }
                }
            }
        }
        .stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 0.6, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Cell

    @ViewBuilder
    private func cell(for id: String?) -> some View {
        if let id, let profile = snapshot.profiles[id] {
            filledCell(profile: profile)
        } else {
            emptyCell
        }
    }

    private func filledCell(profile: Profile) -> some View {
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
            if let location = locationLine(for: profile) {
                Text(location)
                    .font(locationFont)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.black.opacity(0.7), lineWidth: 0.6)
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

    private func locationLine(for profile: Profile) -> String? {
        // Prefer birth location; fall back to death location. In 5-gen the
        // line may not render for space — the SwiftUI layout simply lets it
        // wrap or clip and the data is still in the source profile.
        let loc = profile.birthLocation ?? profile.deathLocation
        guard let loc, !loc.isEmpty else { return nil }
        return loc
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
