import SwiftUI

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
    /// Optional callback for callers that need to react to a confirmed selection
    /// (e.g. trigger an audit re-run when the structured code changes).
    var onSelect: ((GazetteerEntry?) -> Void)?

    @FocusState private var isFocused: Bool

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

            // When code is set, show a small confirmation chip so the user
            // can see they've chosen a structured entry, and easily clear it
            // if they want to type freeform instead.
            if let code = locationCode, let entry = LocationGazetteer.shared.entry(forID: code) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Matched: \(entry.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            HStack(spacing: 4) {
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
