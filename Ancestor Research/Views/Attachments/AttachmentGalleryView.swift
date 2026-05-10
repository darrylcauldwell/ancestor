import SwiftUI
import AppKit

/// Grid of attachment thumbnails for a single profile. Per DESIGN.md §5.15.
/// Tapping a tile opens a type-appropriate viewer (photo / PDF / transcription).
struct AttachmentGalleryView: View {
    @Environment(AppState.self) private var appState
    let profileID: String

    @State private var selected: Attachment?

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 96, maximum: 128), spacing: 8)
    ]

    var body: some View {
        let attachments = appState.attachmentsForProfile(profileID)
        Group {
            if attachments.isEmpty {
                Text("No attachments yet.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(attachments, id: \.id) { attachment in
                        AttachmentThumbnailTile(attachment: attachment) {
                            selected = attachment
                        }
                    }
                }
            }
        }
        .sheet(item: $selected) { attachment in
            attachmentViewer(for: attachment)
                .frame(minWidth: 600, minHeight: 500)
        }
    }

    @ViewBuilder
    private func attachmentViewer(for attachment: Attachment) -> some View {
        switch attachment.mediaType {
        case .photo:
            AttachmentPhotoViewer(attachment: attachment)
        case .document:
            AttachmentPDFViewer(attachment: attachment)
        case .transcription:
            AttachmentTranscriptionViewer(attachment: attachment)
        }
    }
}

/// Single tile in the gallery grid. Renders the thumbnail JPEG when present,
/// or falls back to a generic SF Symbol when the thumbnail step was skipped
/// (e.g. transcription) or failed.
private struct AttachmentThumbnailTile: View {
    @Environment(AppState.self) private var appState
    let attachment: Attachment
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                    if let image = thumbnailImage() {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: attachment.mediaType.systemImage)
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                if let caption = attachment.caption, !caption.isEmpty {
                    Text(caption)
                        .font(AppTypography.badge)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(attachment.filename)
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 96)
        }
        .buttonStyle(.plain)
    }

    private func thumbnailImage() -> NSImage? {
        guard let projectID = appState.currentProject?.id else { return nil }
        let url = ProjectStore.thumbnailsDirectory(for: projectID)
            .appendingPathComponent("\(attachment.id.uuidString).jpg")
        return NSImage(contentsOf: url)
    }
}
