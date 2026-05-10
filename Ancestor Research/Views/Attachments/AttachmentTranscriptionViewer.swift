import SwiftUI

/// Sheet for viewing a typed-in transcription. Reads the underlying `.txt`
/// file from disk lazily so the rest of the app never has to keep transcription
/// text in memory unless a user opens it.
struct AttachmentTranscriptionViewer: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let attachment: Attachment

    @State private var transcript: String = ""
    @State private var loadFailed: Bool = false
    @State private var showingEditor: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            AttachmentViewerHeader(attachment: attachment) { dismiss() }
            Divider()

            ScrollView {
                if loadFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "text.alignleft")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Transcription file is missing.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    Text(transcript)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
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
        .task { loadTranscript() }
        .sheet(isPresented: $showingEditor) {
            AttachmentMetadataEditor(attachment: attachment)
        }
    }

    private func loadTranscript() {
        guard let projectID = appState.currentProject?.id else {
            loadFailed = true
            return
        }
        let url = ProjectStore.absoluteURL(for: attachment, in: projectID)
        do {
            transcript = try String(contentsOf: url, encoding: .utf8)
        } catch {
            loadFailed = true
        }
    }
}
