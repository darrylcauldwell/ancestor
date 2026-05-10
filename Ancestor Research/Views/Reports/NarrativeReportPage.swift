import SwiftUI

/// SwiftUI page view for a narrative report (DESIGN.md §7.9.4). Consumes
/// a `NarrativeDocument` produced by `NarrativeComposer.compose(...)` and
/// renders the prose paragraphs followed by a footnotes section.
///
/// The view is sized to fill a `PaperSize` by `PDFRenderer`. Overflow is
/// clipped — true pagination is deferred to a future polish pass per
/// the M10 brief.
@MainActor
struct NarrativeReportPage: View {
    let document: NarrativeDocument

    private let pagePadding: CGFloat = 36
    private let paragraphSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: paragraphSpacing) {
                ForEach(Array(document.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !document.footnotes.isEmpty {
                Divider()
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.bottom, 2)

                    ForEach(Array(document.footnotes.enumerated()), id: \.offset) { idx, footnote in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(idx + 1).")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .trailing)
                            Text(footnote)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Narrative")
                .font(.system(size: 16, weight: .bold))
            Text(document.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
