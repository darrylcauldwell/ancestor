import SwiftUI

/// Renders a string that may or may not be a URL. When the value is a
/// well-formed http/https URL with a host component, it becomes a
/// `Link` (underlined blue, opens in the default browser). Otherwise
/// it renders as plain selectable text.
///
/// Used on cluster cards, source explorer rows, citations — any
/// surface where a raw field's contents could be a URL or plain text
/// and the rendering shouldn't have to decide ahead of time.
@MainActor
struct HyperlinkedText: View {
    let value: String
    let font: Font
    let plainColor: Color

    init(_ value: String, font: Font = .body, plainColor: Color = .primary) {
        self.value = value
        self.font = font
        self.plainColor = plainColor
    }

    var body: some View {
        if let url = Self.httpURL(from: value) {
            Link(destination: url) {
                Text(value)
                    .font(font)
                    .foregroundStyle(.blue)
                    .underline()
            }
            .textSelection(.enabled)
        } else {
            Text(value)
                .font(font)
                .foregroundStyle(plainColor)
                .textSelection(.enabled)
        }
    }

    /// Strict http/https detector. Requires a host so bare path-like
    /// values that happen to contain "://" don't false-positive.
    static func httpURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        guard let url = URL(string: trimmed), url.host?.isEmpty == false else { return nil }
        return url
    }
}
