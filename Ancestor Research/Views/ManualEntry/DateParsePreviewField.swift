import SwiftUI

/// Date input field with live parse preview underneath.
/// Shows what the parser interpreted (e.g. "Approximately 1890 (range: 1885–1895)")
/// or a hint when input is unparseable. Empty input is silent.
struct DateParsePreviewField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = "e.g. 1887, March 1887, about 1890, before 1900"

    /// Latest parse result derived from `text`.
    private var preview: DateParseResult {
        GenealogicalDate.parsePreview(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(label, text: $text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)

            if !text.isEmpty {
                Text(preview.displayText)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(preview.isValid ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .accessibilityIdentifier("\(label)-preview")
            }
        }
    }
}
