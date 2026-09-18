import SwiftUI
import AncestorKit

/// Typeahead location picker. Replaces freeform TextField for birth/death
/// location entry — as the user types, a dropdown shows up to 10 matching
/// places from the bundled gazetteer (LocationGazetteer.shared).
///
/// Two callbacks: `onSelect` fires when the user picks a gazetteer entry (so
/// caller gets a structured ID it can persist alongside the display string).
/// `text` is the binding to the freeform display string — also writable when
/// the user types something not in the gazetteer, so freeform entry still works
/// as a fallback ("Madeira (born at sea)" must survive).
struct LocationPicker: View {
    let label: String
    @Binding var text: String
    @Binding var locationCode: String?
    /// The year of the event this place belongs to. Registration districts open
    /// and close, so without it the district line can name one that did not
    /// exist — "Crich · Amber Valley" for a Victorian birth, Amber Valley RD
    /// having begun in 1994.
    let eventYear: Int?
    /// Optional callback for callers that need to react to a confirmed selection
    /// (e.g. trigger an audit re-run when the structured code changes).
    var onSelect: ((GazetteerEntry?) -> Void)?

    /// **`eventYear` has no default on purpose.** Swift hands optional properties
    /// an implicit `nil` in the synthesised memberwise init, and when this
    /// parameter was added that silently left five of the ten embeds date-blind —
    /// still offering districts that would not exist for another century. An
    /// explicit init makes every call site state the year or state that it has
    /// none, so the omission cannot happen again by inattention.
    init(
        label: String,
        text: Binding<String>,
        locationCode: Binding<String?>,
        eventYear: Int?,
        onSelect: ((GazetteerEntry?) -> Void)? = nil
    ) {
        self.label = label
        self._text = text
        self._locationCode = locationCode
        self.eventYear = eventYear
        self.onSelect = onSelect
    }

    @FocusState private var isFocused: Bool
    /// Set once the user types in THIS field, so the unmatched notice below
    /// distinguishes "you just typed this and picked nothing" from "this row
    /// arrived uncoded from an import". Without it the notice would appear
    /// against most of the tree on first render, which is nagging rather than
    /// informative.
    @State private var userEdited: Bool = false

    /// Derived — show the dropdown whenever the field is focused, the user has
    /// typed something, and the gazetteer has at least one match. Pure computed
    /// state so we don't depend on onChange handlers firing in a specific order.
    private var isShowingMatches: Bool {
        isFocused && !text.trimmingCharacters(in: .whitespaces).isEmpty && !currentMatches.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onChange(of: text) { _, newValue in
                    // Only clear the structured code if the new text no longer
                    // matches the displayName of the currently-coded entry.
                    // Without this guard, the dropdown's `text = displayName;
                    // locationCode = id` pair was racing — SwiftUI fires
                    // onChange after both writes, and an unconditional clear
                    // would clobber the locationCode the user just selected.
                    if let code = locationCode,
                       let entry = LocationGazetteer.shared.entry(forID: code),
                       entry.displayName == newValue {
                        return
                    }
                    userEdited = true
                    if locationCode != nil { locationCode = nil }
                }
                .onAppear {
                    // Legacy rows persisted before structured codes existed
                    // (or before this picker was wired in) carry freeform text
                    // but a nil code. If the text exactly matches a gazetteer
                    // entry's displayName, surface it as already-matched so the
                    // green chip appears without needing the user to retype.
                    if locationCode == nil,
                       let entry = LocationGazetteer.shared.places.first(
                           where: { $0.displayName == text }
                       ) {
                        locationCode = entry.id
                    }
                }

            if isFocused && !text.trimmingCharacters(in: .whitespaces).isEmpty {
                if currentMatches.isEmpty {
                    Text("No gazetteer match — will be saved as freeform text.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                } else {
                    matchesDropdown
                }
            }

            // THE QUIET FAILURE. Typing "Derby" and clicking away leaves real
            // text and no code — and said nothing at all, because the
            // no-gazetteer-match notice above is suppressed whenever matches
            // exist, and the green chip below only renders once a code is set.
            // That is the commonest way a place ends up uncoded: the app knew
            // the place, the user just never picked it from the list.
            //
            // Deliberately NOT an error, and deliberately not shown for text
            // that arrived uncoded from an import — only for a field the user
            // edited in this session and left unmatched. Unresolved places must
            // keep working (Location model "Never block"); the point is
            // that the user should know it happened.
            if userEdited, !isFocused, locationCode == nil,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(currentMatches.isEmpty
                         ? "Saved as text — no gazetteer match."
                         : "Saved as text — you didn't pick from the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .help("Places kept as plain text still work, but they can't be matched to a registration district. Settle them in the Places tab.")
            }

            // When code is set, show a small confirmation chip so the user
            // can see they've chosen a structured entry, and easily clear it
            // if they want to type freeform instead.
            if let code = locationCode, let entry = LocationGazetteer.shared.entry(forID: code) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(districtLabel(for: entry).map { "Matched: \(entry.displayName) · \($0) district" }
                            ?? "Matched: \(entry.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(districtHelp(for: entry))
                    Button {
                        locationCode = nil
                        onSelect?(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear structured match — keep text as freeform")
                }
                .padding(.top, 4)
            }
        }
    }

    private var currentMatches: [GazetteerEntry] {
        LocationGazetteer.shared.match(text)
    }

    /// The registration district(s) a gazetteer place sits in ("Crich" →
    /// "Belper"), or nil for a county entry / a place with no catalogue district.
    ///
    /// Was `districtName(forPlace:chapman:)`, a first-match over the county's
    /// districts in file order with no year. 97 of the 219 gazetteer places match
    /// more than one district inside their own county, so roughly two rows in
    /// five silently displayed a rival — and, having no year, some of those were
    /// districts that did not exist yet: "Crich · Amber Valley" (from 1994),
    /// "Matlock · Bakewell" (from 1839). Naming one of several as though it were
    /// the answer is the same fault the Places tab was built to fix, one surface
    /// down.
    ///
    /// Now era-aware and honest about ties. It does not offer a *choice* — there
    /// is nowhere to store a district here (the picker's job is to pick a place;
    /// the district is derived), and offering a choice with no home for the
    /// answer would be worse than naming the ambiguity. Deciding between rivals
    /// belongs in the Places tab, which has the room to show eliminations and
    /// reasons.
    private func districts(for entry: GazetteerEntry) -> [PlaceAuthority] {
        guard entry.kind != "county" else { return [] }
        let chapman = entry.id.split(separator: ":").first.map(String.init)
        return RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: entry.name, chapman: chapman, year: eventYear)?.districts ?? []
    }

    /// "Belper", or "Belper or 2 others" when the place spans rival districts.
    private func districtLabel(for entry: GazetteerEntry) -> String? {
        let found = districts(for: entry)
        guard let first = found.first else { return nil }
        return found.count == 1 ? first.name : "\(first.name) or \(found.count - 1) other\(found.count == 2 ? "" : "s")"
    }

    private func districtHelp(for entry: GazetteerEntry) -> String {
        let found = districts(for: entry)
        guard found.count > 1 else { return "" }
        return "This place spans \(found.count) registration districts"
            + (eventYear.map { " in \($0)" } ?? "")
            + ": \(found.map(\.name).joined(separator: ", ")). Settle it in the Places tab."
    }

    private var matchesDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(currentMatches) { entry in
                Button {
                    text = entry.displayName
                    locationCode = entry.id
                    isFocused = false
                    onSelect?(entry)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: entry.kind == "county" ? "map" : "mappin.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .fontWeight(.medium)
                            // Hierarchy line place → RD → county → country,
                            // resolved through the same canonical resolver the
                            // scorer and apply use — and, since the year is now
                            // passed in, filtered to districts that existed at
                            // the event. Where rivals remain the row says so
                            // rather than naming the first.
                            HStack(spacing: 4) {
                                if let rd = districtLabel(for: entry) {
                                    Text(rd)
                                        .font(.caption)
                                        .foregroundStyle(districts(for: entry).count > 1
                                                         ? AnyShapeStyle(.orange)
                                                         : AnyShapeStyle(.secondary))
                                    Text("·")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                if entry.kind != "county" {
                                    Text(entry.county)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("(\(entry.country))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if entry.id != currentMatches.last?.id {
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .padding(.top, 4)
        .frame(maxWidth: 360, alignment: .leading)
    }
}
