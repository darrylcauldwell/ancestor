import SwiftUI
import AppKit

/// Sheet for viewing a single photo attachment full-size, with caption + EXIF
/// metadata + edit/remove actions. Per DESIGN.md §5.15.
struct AttachmentPhotoViewer: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let attachment: Attachment

    @State private var showingEditor: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            AttachmentViewerHeader(attachment: attachment) { dismiss() }
            Divider()

            ScrollView([.horizontal, .vertical]) {
                if let image = loadImage() {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Image file is missing.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
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

    private func loadImage() -> NSImage? {
        guard let projectID = appState.currentProject?.id else { return nil }
        let url = ProjectStore.absoluteURL(for: attachment, in: projectID)
        return NSImage(contentsOf: url)
    }
}
