import SwiftUI

/// SwiftUI page view for a fan-chart pedigree (DESIGN.md §7.9.2).
///
/// Layout: subject sits at the centre near the bottom of the page; ancestor
/// generations radiate upward as concentric semicircular arcs. Generation 1
/// (parents) is split into 2 wedges, generation 2 into 4, generation 3 into
/// 8, generation 4 into 16. Total radius scales to fill the page width with
/// margin.
///
/// Each filled wedge shows the ancestor's name and birth/death years, with
/// the text rotated to follow the wedge's radial axis. Empty ancestor slots
/// render as muted grey wedges with a "?" so the chart reads symmetrically.
///
/// Font sizes shrink for outer rings — at 5 generations the outermost ring
/// becomes very tight on A4, but the renderer never errors; it lets the text
/// truncate rather than failing the whole report.
@MainActor
struct PedigreeFanChartPage: View {
    let profileID: String
    let generations: PedigreeGenerations
    let showCompleteness: Bool
    let snapshot: FamilyGraphSnapshot

    /// Outer page padding (points). Generous so wedges aren't crammed against
    /// the paper edge when printed.
    private let pagePadding: CGFloat = 28

    /// Centre disc radius (subject lives here).
    private let centerRadius: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            GeometryReader { geo in
                fanCanvas(in: geo.size)
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
            Text("Pedigree fan chart")
                .font(.system(size: 16, weight: .bold))
            Text("\(subjectName) — \(generations.displayName)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Fan canvas

    /// Total ancestor generations beyond the subject (1 = parents only).
    /// Generation 0 is the subject (centre disc), so n-1 rings sit outside.
    private var totalGenerations: Int { generations.rawValue }

    /// How many ancestor rings to draw (0 means "subject only").
    private var ringCount: Int { max(totalGenerations - 1, 0) }

    /// Compute the centre point and ring width for the available size.
    private func geometry(in size: CGSize) -> (centre: CGPoint, ringWidth: CGFloat) {
        // Place centre at horizontal middle, 80% down vertically so the fan
        // opens upward into the upper part of the page.
        let centre = CGPoint(x: size.width / 2, y: size.height * 0.80)

        // Maximum radius is bounded by both the horizontal half-width and
        // the vertical room above the centre (for the upper-half fan).
        let horizontalRoom = size.width / 2
        let verticalRoom = centre.y
        let maxRadius = max(min(horizontalRoom, verticalRoom) - 4, centerRadius + 20)

        let ringWidth: CGFloat
        if ringCount > 0 {
            ringWidth = max((maxRadius - centerRadius) / CGFloat(ringCount), 20)
        } else {
            ringWidth = 0
        }
        return (centre, ringWidth)
    }

    @ViewBuilder
    private func fanCanvas(in size: CGSize) -> some View {
        let geom = geometry(in: size)
        let ancestors = PedigreeChartReport.buildAncestorMatrix(
            subjectID: profileID,
            generations: totalGenerations,
            snapshot: snapshot
        )

        ZStack {
            // Ancestor wedges, ring by ring (outer-most first so dividers
            // overlap consistently).
            ForEach(1..<max(totalGenerations, 1), id: \.self) { gen in
                let count = 1 << gen        // 2, 4, 8, 16
                let inner = centerRadius + CGFloat(gen - 1) * geom.ringWidth
                let outer = centerRadius + CGFloat(gen) * geom.ringWidth
                ForEach(0..<count, id: \.self) { slot in
                    let id = ancestors[gen][slot]
                    wedge(
                        gen: gen,
                        slot: slot,
                        slotsInGen: count,
                        inner: inner,
                        outer: outer,
                        centre: geom.centre,
                        profileID: id
                    )
                }
            }

            // Centre disc — subject.
            centreDisc(centre: geom.centre)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Wedge

    /// Compute the start/end angle (radians, SwiftUI-style with 0 at +x axis,
    /// positive = clockwise) for a slot in a generation. The semicircle
    /// covers angles from 180° (left, due west of centre) to 360° (right).
    /// Slots are ordered left to right so slot 0 is the leftmost wedge.
    private func angles(slot: Int, slotsInGen: Int) -> (start: Angle, end: Angle) {
        let totalSweep = 180.0    // degrees
        let perSlot = totalSweep / Double(slotsInGen)
        // Start angle in degrees: 180° + slot × perSlot (so slot 0 is on
        // the left, sweeping clockwise to the right).
        let startDeg = 180.0 + Double(slot) * perSlot
        let endDeg = startDeg + perSlot
        return (.degrees(startDeg), .degrees(endDeg))
    }

    @ViewBuilder
    private func wedge(
        gen: Int,
        slot: Int,
        slotsInGen: Int,
        inner: CGFloat,
        outer: CGFloat,
        centre: CGPoint,
        profileID: String?
    ) -> some View {
        let angles = self.angles(slot: slot, slotsInGen: slotsInGen)
        let isFilled = profileID != nil && snapshot.profiles[profileID!] != nil

        ZStack {
            WedgePath(
                centre: centre,
                inner: inner,
                outer: outer,
                start: angles.start,
                end: angles.end
            )
            .fill(isFilled ? Color.white : Color.gray.opacity(0.08))

            WedgePath(
                centre: centre,
                inner: inner,
                outer: outer,
                start: angles.start,
                end: angles.end
            )
            .stroke(
                isFilled ? Color.black.opacity(0.7) : Color.gray.opacity(0.5),
                style: StrokeStyle(
                    lineWidth: 0.6,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: isFilled ? [] : [3, 2]
                )
            )

            wedgeLabel(
                gen: gen,
                slotsInGen: slotsInGen,
                inner: inner,
                outer: outer,
                centre: centre,
                start: angles.start,
                end: angles.end,
                profileID: profileID
            )
        }
    }

    // MARK: - Wedge label

    /// Draw the ancestor's name and dates rotated along the wedge's bisector,
    /// positioned at the radial midpoint. Font shrinks with generation so
    /// outer rings stay legible without overlapping their wedge bounds.
    @ViewBuilder
    private func wedgeLabel(
        gen: Int,
        slotsInGen: Int,
        inner: CGFloat,
        outer: CGFloat,
        centre: CGPoint,
        start: Angle,
        end: Angle,
        profileID: String?
    ) -> some View {
        let mid = midAngle(start: start, end: end)
        let radius = (inner + outer) / 2
        let x = centre.x + radius * CGFloat(cos(mid.radians))
        let y = centre.y + radius * CGFloat(sin(mid.radians))

        let (nameSize, dateSize) = labelFontSizes(forGen: gen)
        let labelLength = max(outer - inner - 6, 12)

        // The wedge bisector points from centre outward at angle `mid`.
        // SwiftUI's `Text` reads along +x by default; rotating by `mid + 90°`
        // lays the text along the radial spoke (perpendicular to the
        // tangent). For the upper-half fan (mid ∈ [180°, 360°]) all
        // bisectors point upward from the centre, so reading outward looks
        // correct without an additional flip.
        let radialRotation = Angle(radians: mid.radians + .pi / 2)

        VStack(spacing: 1) {
            Text(displayName(for: profileID))
                .font(.system(size: nameSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(profileID == nil ? Color.secondary : Color.primary)
            if let years = datesLine(for: profileID) {
                Text(years)
                    .font(.system(size: dateSize))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: labelLength, alignment: .center)
        .rotationEffect(radialRotation, anchor: .center)
        .position(x: x, y: y)
        .allowsHitTesting(false)
    }

    private func midAngle(start: Angle, end: Angle) -> Angle {
        Angle(radians: (start.radians + end.radians) / 2)
    }

    /// Per-generation font sizing — outer rings get smaller text so labels
    /// fit within their (narrower) angular slot.
    private func labelFontSizes(forGen gen: Int) -> (name: CGFloat, date: CGFloat) {
        switch gen {
        case 1: return (10, 8)
        case 2: return (8.5, 6.5)
        case 3: return (7, 5.5)
        case 4: return (6, 5)
        default: return (5.5, 4.5)
        }
    }

    // MARK: - Centre disc

    @ViewBuilder
    private func centreDisc(centre: CGPoint) -> some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.7), lineWidth: 0.8)
                )
                .frame(width: centerRadius * 2, height: centerRadius * 2)

            VStack(spacing: 1) {
                Text(displayName(for: profileID))
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                if let years = datesLine(for: profileID) {
                    Text(years)
                        .font(.system(size: 7))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                if showCompleteness, snapshot.profiles[profileID] != nil {
                    completenessBadge(for: profileID)
                }
            }
            .frame(width: centerRadius * 1.7)
        }
        .position(centre)
    }

    // MARK: - Cell content helpers

    private func displayName(for id: String?) -> String {
        guard let id, let profile = snapshot.profiles[id] else { return "?" }
        let name = profile.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "(unknown)" : name
    }

    private func datesLine(for id: String?) -> String? {
        guard let id, let profile = snapshot.profiles[id] else { return nil }
        let birth = profile.birthDate?.bestYear.map(String.init)
        let death = profile.deathDate?.bestYear.map(String.init)
        switch (birth, death) {
        case (let b?, let d?): return "\(b)–\(d)"
        case (let b?, nil):    return "b. \(b)"
        case (nil, let d?):    return "d. \(d)"
        case (nil, nil):       return nil
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
            .font(.system(size: 6, weight: .semibold))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.15)))
            .overlay(Capsule().stroke(tint.opacity(0.6), lineWidth: 0.4))
    }
}

// MARK: - Wedge shape

/// Annular sector (ring slice) bounded by two radii and two angles. Used for
/// each ancestor cell on the fan chart.
private struct WedgePath: Shape {
    let centre: CGPoint
    let inner: CGFloat
    let outer: CGFloat
    let start: Angle
    let end: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startPoint = point(on: outer, angle: start)
        path.move(to: startPoint)
        // Outer arc, going clockwise from start to end.
        path.addArc(
            center: centre,
            radius: outer,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        // Line to the inner arc end.
        let innerEnd = point(on: inner, angle: end)
        path.addLine(to: innerEnd)
        // Inner arc, going counter-clockwise back to the start angle.
        path.addArc(
            center: centre,
            radius: inner,
            startAngle: end,
            endAngle: start,
            clockwise: true
        )
        path.closeSubpath()
        return path
    }

    private func point(on radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(
            x: centre.x + radius * CGFloat(cos(angle.radians)),
            y: centre.y + radius * CGFloat(sin(angle.radians))
        )
    }
}
