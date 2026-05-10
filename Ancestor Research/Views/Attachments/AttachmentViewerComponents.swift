import SwiftUI

/// Shared header used by photo/PDF/transcription viewers. Shows the original
/// filename + media type icon and a Done button that dismisses the sheet.
struct AttachmentViewerHeader: View {
    let attachment: Attachment
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.mediaType.systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(.title3).fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.mediaType.displayName)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onDismiss)
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}

/// Shared footer showing caption + dateTaken + locationTaken plus Edit /
/// Remove actions. Visible at the bottom of every attachment viewer sheet.
struct AttachmentMetadataFooter: View {
    let attachment: Attachment
    let onEdit: () -> Void
    let onRemove: () -> Void

    @State private var confirmingRemove: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = attachment.caption, !caption.isEmpty {
                Text(caption)
                    .font(AppTypography.cardBody)
            }
            HStack(spacing: 16) {
                if let dateTaken = attachment.dateTaken {
                    Label(dateTaken.formatted(date: .abbreviated, time: .shortened),
                          systemImage: "calendar")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                if let location = attachment.locationTaken, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit metadata", action: onEdit)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Button(role: .destructive) {
                    confirmingRemove = true
                } label: {
                    Text("Remove")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding()
        .confirmationDialog(
            "Remove this attachment?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will be deleted from the project's media folder.")
        }
    }
}

/// Sheet for editing an existing attachment's caption / dateTaken /
/// locationTaken. Saves through `AppState.updateAttachment`.
struct AttachmentMetadataEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let attachment: Attachment

    @State private var caption: String = ""
    @State private var dateTakenEnabled: Bool = false
    @State private var dateTaken: Date = Date()
    @State private var locationTaken: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit attachment")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Caption")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    TextField("Optional", text: $caption)
                        .textFieldStyle(.roundedBorder)
                }
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
                    TextField("Optional", text: $locationTaken)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding()
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 280)
        .onAppear {
            caption = attachment.caption ?? ""
            if let date = attachment.dateTaken {
                dateTaken = date
                dateTakenEnabled = true
            }
            locationTaken = attachment.locationTaken ?? ""
        }
    }

    private func save() {
        var updated = attachment
        updated.caption = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : caption
        updated.dateTaken = dateTakenEnabled ? dateTaken : nil
        updated.locationTaken = locationTaken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : locationTaken
        appState.updateAttachment(updated)
        dismiss()
    }
}
