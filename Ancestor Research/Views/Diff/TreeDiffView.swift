import SwiftUI

/// Visual diff after WikiTree refresh — shows what changed before committing.
struct TreeDiffView: View {
    @Environment(AppState.self) private var appState
    let diff: DiffEngine.DiffResult

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Review Changes")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Text("\(diff.changeCount) changes")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Changes list
            List {
                if !diff.added.isEmpty {
                    Section("Added (\(diff.added.count))") {
                        ForEach(diff.added) { profile in
                            Label(profile.displayName, systemImage: "plus.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }

                if !diff.removed.isEmpty {
                    Section("Removed (\(diff.removed.count))") {
                        ForEach(diff.removed) { profile in
                            Label(profile.displayName, systemImage: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                if !diff.modified.isEmpty {
                    Section("Modified (\(diff.modified.count))") {
                        ForEach(diff.modified) { profileDiff in
                            DisclosureGroup {
                                ForEach(profileDiff.fieldChanges) { fieldDiff in
                                    HStack {
                                        Text(fieldDiff.field.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 100, alignment: .leading)
                                        if let old = fieldDiff.oldValue {
                                            Text(old)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                                .strikethrough()
                                        }
                                        Image(systemName: "arrow.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if let new = fieldDiff.newValue {
                                            Text(new)
                                                .font(.caption)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                            } label: {
                                Label(profileDiff.profile.displayName, systemImage: "pencil.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if !diff.relationshipsAdded.isEmpty {
                    Section("New Relationships (\(diff.relationshipsAdded.count))") {
                        ForEach(diff.relationshipsAdded) { rel in
                            Text("\(rel.from) → \(rel.to) (\(rel.type.rawValue))")
                                .font(.caption)
                        }
                    }
                }
            }

            Divider()

            // Actions
            HStack(spacing: 16) {
                Button("Reject Changes") {
                    appState.rejectPendingDiff()
                }
                .keyboardShortcut(.cancelAction)

                Button("Accept All Changes") {
                    appState.acceptPendingDiff()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
