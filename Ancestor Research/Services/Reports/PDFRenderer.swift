import SwiftUI

/// Renders a SwiftUI `View` to a single-page PDF via `ImageRenderer`
/// (macOS 13+). The view is constrained to the report's `PaperSize` and
/// PDF data is returned as bytes for the caller to write to disk.
///
/// Reports that span multiple pages compose them as a vertical layout of
/// fixed-height pages and call this helper once. True multi-page native
/// PDF generation (one CGPDF context per page) can be added later.
@MainActor
enum PDFRenderer {

    /// Render `content` into a PDF data blob sized to `paperSize` (portrait).
    /// Returns nil only if the underlying CGContext can't be created.
    static func renderToPDFData<Content: View>(
        paperSize: PaperSize,
        @ViewBuilder content: () -> Content
    ) -> Data? {
        let cfData = CFDataCreateMutable(nil, 0)!
        let renderer = ImageRenderer(content:
            content()
                .frame(
                    width: paperSize.sizeInPoints.width,
                    height: paperSize.sizeInPoints.height
                )
        )
        // 300dpi — print-ready per DESIGN.md §7.9.2.
        renderer.scale = 300.0 / 72.0

        renderer.render { size, renderContext in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: cfData),
                  let pdfContext = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                return
            }
            pdfContext.beginPDFPage(nil)
            renderContext(pdfContext)
            pdfContext.endPDFPage()
            pdfContext.closePDF()
        }

        let data = cfData as Data
        return data.isEmpty ? nil : data
    }

    /// Render multiple SwiftUI pages into a single PDF, one
    /// `beginPDFPage`/`endPDFPage` cycle per page. Used by batch family-group
    /// sheets, multi-page narratives, and any future long report.
    /// Returns nil only if the underlying CGContext can't be created or
    /// the page list is empty.
    static func renderMultiPagePDF<Page: View>(
        paperSize: PaperSize,
        pages: [Page]
    ) -> Data? {
        guard !pages.isEmpty else { return nil }
        let cfData = CFDataCreateMutable(nil, 0)!
        var box = CGRect(origin: .zero, size: paperSize.sizeInPoints)
        guard let consumer = CGDataConsumer(data: cfData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return nil
        }
        defer { pdfContext.closePDF() }

        for page in pages {
            let renderer = ImageRenderer(content:
                page
                    .frame(width: paperSize.sizeInPoints.width,
                           height: paperSize.sizeInPoints.height)
            )
            renderer.scale = 300.0 / 72.0
            renderer.render { _, renderContext in
                pdfContext.beginPDFPage(nil)
                renderContext(pdfContext)
                pdfContext.endPDFPage()
            }
        }

        let data = cfData as Data
        return data.isEmpty ? nil : data
    }
}
