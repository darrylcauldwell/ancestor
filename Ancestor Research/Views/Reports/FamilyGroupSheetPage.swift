import SwiftUI

/// SwiftUI page rendered to PDF for one family unit (DESIGN.md §7.9.3).
///
/// Sections (top to bottom): title, parents, children, sources, notes.
/// Empty sections (no children, no sources, no notes) collapse out so a
/// thin family doesn't print mostly-empty headers.
struct FamilyGroupSheetPage: View {
    let unit: FamilyUnit
    let notes: [WorkbenchNote]

    private var citations: [Citation] {
        FamilyGroupSheetReport.collectCitations(for: unit)
    }

    private var familyNotes: [WorkbenchNote] {
        FamilyGroupSheetReport.collectNotes(for: unit, from: notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            titleSection
            Divider()
            parentsSection
            if !unit.children.isEmpty {
                Divider()
                childrenSection
            }
            if !citations.isEmpty {
                Divider()
                sourcesSection
            }
            if !familyNotes.isEmpty {
                Divider()
                notesSection
            }
            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(.black)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Family Group Sheet")
                .font(.system(size: 22, weight: .bold))
            Text(unit.headerName)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Parents

    private var parentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Parents")
                .font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 24) {
                ParentColumn(
                    role: "Father",
                    profile: unit.father,
                    marriage: unit.marriage
                )
                ParentColumn(
                    role: "Mother",
                    profile: unit.mother,
                    marriage: unit.marriage
                )
            }
        }
    }

    // MARK: - Children

    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Children")
                .font(.system(size: 14, weight: .semibold))
            VStack(spacing: 0) {
                ChildrenHeaderRow()
                ForEach(unit.children) { child in
                    ChildRow(child: child)
                }
            }
        }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, alignment: .trailing)
                        Text(citation.formatted)
                            .font(.system(size: 10))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(familyNotes) { note in
                    NoteRow(note: note)
                }
            }
        }
    }
}

// MARK: - Parent column

private struct ParentColumn: View {
    let role: String
    let profile: Profile?
    let marriage: Relationship?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            if let profile {
                Text(profile.displayName.isEmpty ? "—" : profile.displayName)
                    .font(.system(size: 12, weight: .bold))
                eventLine(label: "Born",
                          date: profile.birthDate?.original,
                          location: profile.birthLocation,
                          citation: firstCitation(profile, field: .birthDate)
                            ?? firstCitation(profile, field: .birthLocation))
                if let marriage {
                    eventLine(label: "Married",
                              date: marriage.marriageDate?.original,
                              location: marriage.marriageLocation,
                              citation: nil)
                }
                eventLine(label: "Died",
                          date: profile.deathDate?.original,
                          location: profile.deathLocation,
                          citation: firstCitation(profile, field: .deathDate)
                            ?? firstCitation(profile, field: .deathLocation))
            } else {
                Text("Unknown")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func eventLine(
        label: String,
        date: String?,
        location: String?,
        citation: Citation?
    ) -> some View {
        let hasDate = !(date ?? "").isEmpty
        let hasLocation = !(location ?? "").isEmpty
        if hasDate || hasLocation {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 50, alignment: .leading)
                    Text([date, location].compactMap { (s: String?) -> String? in
                        guard let s, !s.isEmpty else { return nil }
                        return s
                    }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let citation, !citation.isEmpty {
                    Text(citation.formatted)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 56)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func firstCitation(_ profile: Profile, field: ProfileField) -> Citation? {
        profile.sources[field]?
            .compactMap(\.citation)
            .first { !$0.isEmpty }
    }
}

// MARK: - Children table

private struct ChildrenHeaderRow: View {
    var body: some View {
        HStack(spacing: 6) {
            cell("Name", weight: .semibold, width: 130, align: .leading)
            cell("Sex", weight: .semibold, width: 28, align: .center)
            cell("Born", weight: .semibold, width: 70, align: .leading)
            cell("Birthplace", weight: .semibold, width: 130, align: .leading)
            cell("Died", weight: .semibold, width: 70, align: .leading)
            cell("Spouse", weight: .semibold, width: nil, align: .leading)
        }
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(.gray.opacity(0.5)).frame(height: 0.5) }
    }

    private func cell(_ text: String, weight: Font.Weight, width: CGFloat?, align: Alignment) -> some View {
        Group {
            if let width {
                Text(text)
                    .font(.system(size: 9, weight: weight))
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: align)
            } else {
                Text(text)
                    .font(.system(size: 9, weight: weight))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: align)
            }
        }
    }
}

private struct ChildRow: View {
    let child: Profile
    @Environment(\.self) private var env

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            cell(child.displayName.isEmpty ? "—" : child.displayName, weight: .medium, width: 130, align: .leading)
            cell(genderLetter(child.gender), weight: .regular, width: 28, align: .center)
            cell(child.birthDate?.original ?? "—", weight: .regular, width: 70, align: .leading)
            cell(child.birthLocation ?? "—", weight: .regular, width: 130, align: .leading)
            cell(child.deathDate?.original ?? "—", weight: .regular, width: 70, align: .leading)
            cell(spouseSummary, weight: .regular, width: nil, align: .leading)
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(.gray.opacity(0.2)).frame(height: 0.5) }
    }

    private var spouseSummary: String {
        // We don't have the snapshot here, so we render "—" as a default.
        // (Spouse names come from the snapshot upstream when needed; the
        // family group sheet shows children's spouses if they're already
        // populated in displayName by an enriched profile, which we don't
        // assume here.) Keep simple — children's spouses are out-of-scope
        // for an in-row summary at this layout density.
        "—"
    }

    private func genderLetter(_ g: Gender?) -> String {
        switch g {
        case .male: return "M"
        case .female: return "F"
        default: return "—"
        }
    }

    private func cell(_ text: String, weight: Font.Weight, width: CGFloat?, align: Alignment) -> some View {
        Group {
            if let width {
                Text(text)
                    .font(.system(size: 10, weight: weight))
                    .frame(width: width, alignment: align)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(text)
                    .font(.system(size: 10, weight: weight))
                    .frame(maxWidth: .infinity, alignment: align)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Note row

private struct NoteRow: View {
    let note: WorkbenchNote

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(NoteRow.dateFormatter.string(from: note.createdAt))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(note.tag.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.gray, lineWidth: 0.5))
            }
            Text(truncated(note.content))
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func truncated(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 200 else { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: 200)
        return trimmed[..<cutoff].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
