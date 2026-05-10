import SwiftUI
import UniformTypeIdentifiers

/// Sheet that lets the user pick a photo / PDF / typed-in transcription and
/// attach it to a profile, life event, or specific field source. Per
/// DESIGN.md §5.15.
///
/// Flow: pick "Choose file…" → fileImporter runs → AttachmentImporter copies
/// the file + extracts EXIF + builds a thumbnail → user can edit caption /
/// dateTaken / locationTaken → Save commits via AppState.updateAttachment.
struct AttachmentImportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: AttachmentTarget

    @State private var importer = AttachmentImporter()
    @State private var draft: Attachment?
    @State private var caption: String = ""
    @State private var dateTaken: Date = Date()
    @State private var dateTakenEnabled: Bool = false
    @State private var locationTaken: String = ""
    @State private var transcriptionText: String = ""
    @State private var mode: Mode = .chooser
    @State private var showingFilePicker: Bool = false
    @State private var isImporting: Bool = false

    enum Mode: Sendable {
        case chooser            // initial — user picks "From file…" or "Type transcription"
        case typing             // typing transcription text
        case editingMetadata    // file is imported, user is editing caption + EXIF fields
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                content
                    .padding()
            }

            Divider()
            HStack {
                if let error = importer.lastError {
                    Text(error)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                primaryButton
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 380)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image, .pdf, .text],
            allowsMultipleSelection: false
        ) { result in
            handleFilePickerResult(result)
        }
    }

    private var headerTitle: String {
        switch mode {
        case .chooser: return "Add attachment"
        case .typing: return "Type transcription"
        case .editingMetadata: return "Attachment details"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .chooser:
            chooserContent
        case .typing:
            typingContent
        case .editingMetadata:
            metadataContent
        }
    }

    @ViewBuilder
    private var chooserContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Attach a photo, scanned document, or typed transcription. EXIF date and location pre-fill from photos when available.")
                .font(AppTypography.cardBody)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showingFilePicker = true
                } label: {
                    Label("Choose a file…", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                Button {
                    mode = .typing
                } label: {
                    Label("Type a transcription", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var typingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste or type the transcription. It will be saved as a `.txt` file inside the project.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)

            TextEditor(text: $transcriptionText)
                .font(.body.monospaced())
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            captionField
        }
    }

    @ViewBuilder
    private var metadataContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft {
                HStack(spacing: 10) {
                    Image(systemName: draft.mediaType.systemImage)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.filename)
                            .font(AppTypography.cardBody.weight(.semibold))
                        Text(draft.mediaType.displayName)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
            }

            captionField

            Toggle("Date taken", isOn: $dateTakenEnabled)
                .font(AppTypography.cardBody)
            if dateTakenEnabled {
                DatePicker("",
                           selection: $dateTaken,
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Location taken")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                TextField("Optional — \"lat,lon\" or place name", text: $locationTaken)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var captionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Caption")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            TextField("Optional", text: $caption)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch mode {
        case .chooser:
            EmptyView()
        case .typing:
            Button("Save") {
                Task { await saveTranscription() }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
            .keyboardShortcut(.defaultAction)
        case .editingMetadata:
            Button("Save") {
                saveMetadata()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(draft == nil || isImporting)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func handleFilePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importPickedFile(url) }
        case .failure(let error):
            importer.lastError = error.localizedDescription
        }
    }

    private func importPickedFile(_ url: URL) async {
        isImporting = true
        defer { isImporting = false }
        guard let imported = await importer.importFile(
            from: url,
            target: target,
            in: appState
        ) else { return }
        draft = imported
        caption = imported.caption ?? ""
        if let date = imported.dateTaken {
            dateTaken = date
            dateTakenEnabled = true
        }
        locationTaken = imported.locationTaken ?? ""
        mode = .editingMetadata
    }

    private func saveMetadata() {
        guard var attachment = draft else { return }
        attachment.caption = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : caption
        attachment.dateTaken = dateTakenEnabled ? dateTaken : nil
        attachment.locationTaken = locationTaken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : locationTaken
        appState.updateAttachment(attachment)
        dismiss()
    }

    private func saveTranscription() async {
        let text = transcriptionText
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        _ = await importer.importTranscription(
            text: text,
            caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
            target: target,
            in: appState
        )
        dismiss()
    }
}
