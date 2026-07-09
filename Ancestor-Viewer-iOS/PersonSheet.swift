import SwiftUI
import AncestorKit
import AncestorViewerKit

/// Person detail sheet: bio, timeline, gallery, plus "Focus tree here"
/// which re-roots the canvas on this person. Redacted persons degrade to
/// the name card — the privacy design, not a gap.
struct PersonSheet: View {
    let personID: String
    let tree: ViewerTree
    let onFocus: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var profile: Profile? { tree.snapshot.profiles[personID] }
    private var events: [LifeEvent] { tree.events[personID] ?? [] }
    private var media: [MediaRow] { tree.media[personID] ?? [] }

    var body: some View {
        NavigationStack {
            if let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(profile)

                        if let bio = profile.bio {
                            Text(bio)
                                .font(AppTypography.panelBio)
                        }

                        if !events.isEmpty {
                            timeline
                        }

                        if !media.isEmpty {
                            gallery
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(profile.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onFocus(personID)
                            dismiss()
                        } label: {
                            Label("Focus tree here", systemImage: "scope")
                        }
                    }
                }
            }
        }
    }

    private func header(_ profile: Profile) -> some View {
        HStack(alignment: .center, spacing: 16) {
            if let path = media.first(where: { $0.kind == "portrait" })?.localAssetPath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                if let birth = profile.birthDate {
                    vitalRow(label: "Born", date: birth, place: profile.birthLocation)
                }
                if let death = profile.deathDate {
                    vitalRow(label: "Died", date: death, place: profile.deathLocation)
                }
                if tree.annotations[personID]?.isRedacted == true {
                    Label("Details private", systemImage: "lock")
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func vitalRow(label: String, date: GenealogicalDate, place: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(AppTypography.cardMeta.weight(.semibold))
                .foregroundStyle(.secondary)
            Text([date.original.isEmpty ? date.bestYear.map(String.init) : date.original, place]
                .compactMap { $0 }
                .joined(separator: " — "))
                .font(AppTypography.cardMeta)
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Life events")
                .font(AppTypography.cardTitle)
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(event.sortYear.map(String.init) ?? "—")
                        .font(AppTypography.timelineYear)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.type.displayName)
                            .font(AppTypography.cardBody.weight(.medium))
                        if let detail = [event.description, event.location]
                            .compactMap({ $0 }).first {
                            Text(detail)
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos & documents")
                .font(AppTypography.cardTitle)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(media) { item in
                        if let path = item.localAssetPath,
                           let image = UIImage(contentsOfFile: path) {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 200, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                if let caption = item.caption {
                                    Text(caption)
                                        .font(AppTypography.cardMeta)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
