import SwiftUI

/// Expandable "Add citation details" UI embedded under a field's source row.
/// Per DESIGN.md §5.12, most manual-entry users skip this entirely — the source
/// picker (§7.5.9) alone is enough. But when the user has a birth certificate
/// or census image in hand, they can record the formal citation immediately.
///
/// Two states:
///   - **Collapsed** (default): a single chevron + "Add citation" disclosure row
///   - **Expanded**: structured fields for repository, collection, title, page,
///     URL, date accessed, notes, plus an evidence-quality rating
///
/// The view binds to `Citation?` and `EvidenceQuality?` so the parent owns the
/// state. When every field is empty AND quality is nil, the binding is set
/// back to `nil` rather than to an empty struct — keeps DB rows clean and
/// matches the "no citation persisted" semantics of `Citation.isEmpty`.
struct CitationEntryView: View {
    @Binding var citation: Citation?
    @Binding var quality: EvidenceQuality?

    /// Auto-suggest values previously used in this project. Caller passes them
    /// in (FocusComposerView pattern) so the view stays a pure presenter and
    /// doesn't need direct access to AppState/snapshot.
    var repositorySuggestions: [String] = []
    var collectionSuggestions: [String] = []

    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            expandedContent
                .padding(.top, 8)
        } label: {
            label
        }
        .onAppear {
            // Auto-expand if the bound citation already has content (e.g. when
            // editing a profile that already carries a citation).
            if let citation, !citation.isEmpty {
                isExpanded = true
            }
        }
    }

    // MARK: - Label

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: hasContent ? "doc.text.fill" : "doc.text")
                .foregroundStyle(.secondary)
                .font(AppTypography.cardMeta)
                .accessibilityHidden(true)
            Text(hasContent ? "Citation details" : "Add citation")
                .font(AppTypography.cardMeta.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var hasContent: Bool {
        if let citation, !citation.isEmpty { return true }
        return quality != nil
    }

    // MARK: - Expanded form

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(
                label: "Repository",
                placeholder: "e.g. The National Archives",
                value: bindingFor(\.repository),
                suggestions: repositorySuggestions
            )
            field(
                label: "Collection",
                placeholder: "e.g. 1851 Census of England",
                value: bindingFor(\.collection),
                suggestions: collectionSuggestions
            )
            field(
                label: "Title",
                placeholder: "Document or record title",
                value: bindingFor(\.title)
            )
            field(
                label: "Page",
                placeholder: "e.g. Volume 7b, page 213",
                value: bindingFor(\.page)
            )
            field(
                label: "URL",
                placeholder: "https://…",
                value: bindingFor(\.url)
            )

            HStack {
                Text("Date accessed")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                DatePicker(
                    "",
                    selection: dateAccessedBinding,
                    displayedComponents: .date
                )
                .labelsHidden()
                if citation?.dateAccessed != nil {
                    Button("Clear") { writeCitation { $0.dateAccessed = nil } }
                        .buttonStyle(.plain)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                TextEditor(text: bindingFor(\.notes))
                    .font(AppTypography.cardBody)
                    .frame(minHeight: 44, maxHeight: 88)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            qualityPicker
        }
    }

    // MARK: - Quality

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Evidence quality")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Picker("", selection: qualityBinding) {
                Text("Not rated").tag(EvidenceQuality?.none)
                ForEach(EvidenceQuality.allCases, id: \.self) { q in
                    Text(q.displayName).tag(EvidenceQuality?.some(q))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let quality {
                Text(quality.explanation)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Field row

    @ViewBuilder
    private func field(
        label: String,
        placeholder: String,
        value: Binding<String>,
        suggestions: [String] = []
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
            }
            if !suggestions.isEmpty && value.wrappedValue.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: 110)
                    ForEach(suggestions.prefix(5), id: \.self) { suggestion in
                        Button(suggestion) { value.wrappedValue = suggestion }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    /// Binding to a single string field on the optional `Citation`. Reading
    /// substitutes "" for nil; writing creates the Citation on first keystroke
    /// and tears it back down (sets binding to nil) when every field empties.
    private func bindingFor(_ keyPath: WritableKeyPath<Citation, String?>) -> Binding<String> {
        Binding(
            get: { citation?[keyPath: keyPath] ?? "" },
            set: { newValue in
                writeCitation { c in
                    c[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    private var dateAccessedBinding: Binding<Date> {
        Binding(
            get: { citation?.dateAccessed ?? Date() },
            set: { newValue in writeCitation { $0.dateAccessed = newValue } }
        )
    }

    private var qualityBinding: Binding<EvidenceQuality?> {
        Binding(
            get: { quality },
            set: { quality = $0 }
        )
    }

    /// Apply a mutation to the citation, materialising one if needed and
    /// collapsing back to `nil` once every field has emptied. Keeps DB rows
    /// clean — an empty Citation never persists.
    private func writeCitation(_ mutate: (inout Citation) -> Void) {
        var c = citation ?? Citation()
        mutate(&c)
        citation = c.isEmpty ? nil : c
    }
}
