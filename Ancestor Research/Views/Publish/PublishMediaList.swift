import SwiftUI

// PUBLISHER_SPEC §4.2/§7 — per-attachment media opt-in (the `publish_media`
// table). Media is opt-in because every published asset bills the owner's
// iCloud quota; nothing is shared unless deliberately switched on here.
// An opt-in for a person who isn't published in full is kept but inert —
// the projection drops it (§5), and the row says so.
struct PublishMediaList: View {
    let model: PublishReviewModel

    var body: some View {
        if model.mediaRows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No photos or documents are attached to people in this tree.")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.mediaRows) { row in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { row.optedIn },
                            set: { model.setMediaOptIn($0, for: row.id) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.caption?.isEmpty == false ? row.caption! : row.filename)
                                .font(AppTypography.cardBody)
                            Text("\(row.kindLabel) — \(row.ownerName)")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if row.optedIn && !row.ownerPublishable {
                            Label("Person not published in full — won’t be shared", systemImage: "exclamationmark.triangle")
                                .font(AppTypography.badge)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }
}
