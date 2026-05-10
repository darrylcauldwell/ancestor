import SwiftUI

/// Settings → Backups section (M14 / DESIGN.md §7.15.3).
///
/// Lists every backup for the currently-open project. Each row carries a
/// timestamp, a file size, and a Restore button that runs the standard
/// confirmation alert before overwriting the live SQLite file.
struct BackupsListView: View {
    @Environment(AppState.self) private var appState
    @State private var pendingRestore: BackupInfo?
    @State private var refreshToken = 0

    private var backups: [BackupInfo] {
        guard let id = appState.currentProject?.id else { return [] }
        // refreshToken in scope so the view re-evaluates after a restore.
        _ = refreshToken
        return BackupService.backups(for: id)
    }

    var body: some View {
        Group {
            if appState.currentProject == nil {
                Text("Open a project to see its backups.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            } else if backups.isEmpty {
                Text("No backups yet.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backups) { backup in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(AppTypography.cardTitle)
                            Text(formatSize(backup.sizeBytes))
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            pendingRestore = backup
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
            }
        }
        .alert(
            "Restore this backup?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { backup in
            Button("Restore", role: .destructive) {
                appState.restoreBackup(backup)
                pendingRestore = nil
                refreshToken &+= 1
            }
            Button("Cancel", role: .cancel) {
                pendingRestore = nil
            }
        } message: { backup in
            Text("Your current changes will be replaced with the snapshot from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)).")
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
