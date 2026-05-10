import SwiftUI
import PDFKit

/// Sheet for viewing a PDF attachment, with caption + edit/remove actions.
/// Wraps `PDFView` via `NSViewRepresentable` since PDFKit is AppKit-only.
struct AttachmentPDFViewer: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let attachment: Attachment

    @State private var showingEditor: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            AttachmentViewerHeader(attachment: attachment) { dismiss() }
            Divider()

            if let url = absoluteURL() {
                PDFKitRepresentedView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("PDF file is missing.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }

            Divider()
            AttachmentMetadataFooter(
                attachment: attachment,
                onEdit: { showingEditor = true },
                onRemove: {
                    appState.deleteAttachment(id: attachment.id)
                    dismiss()
                }
            )
        }
        .sheet(isPresented: $showingEditor) {
            AttachmentMetadataEditor(attachment: attachment)
        }
    }

    private func absoluteURL() -> URL? {
        guard let projectID = appState.currentProject?.id else { return nil }
        let url = ProjectStore.absoluteURL(for: attachment, in: projectID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Bridges `PDFView` (AppKit) into SwiftUI. Uses `.scaleFactorForSizeToFit`
/// so the document fills the sheet on first present.
private struct PDFKitRepresentedView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
