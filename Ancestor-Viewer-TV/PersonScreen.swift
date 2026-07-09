import SwiftUI
import AncestorKit
import AncestorViewerKit

/// Full person view: complete bio, life-event timeline, media gallery.
/// Redacted persons never reach here with content — their profile carries
/// nothing beyond the name, so the screen degrades to the name card.
struct PersonScreen: View {
    let personID: String
    let tree: ViewerTree
    @Environment(\.dismiss) private var dismiss

    private var profile: Profile? { tree.snapshot.profiles[personID] }
    private var events: [LifeEvent] { tree.events[personID] ?? [] }
    private var media: [MediaRow] { tree.media[personID] ?? [] }

    var body: some View {
        if let profile {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    header(profile)

                    if let bio = profile.bio {
                        Text(bio)
                            .font(AppTypography.panelBio)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }

                    if !events.isEmpty {
                        timeline
                    }

                    if !media.isEmpty {
                        gallery
                    }
                }
                .padding(64)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onExitCommand { dismiss() }
        }
    }

    private func header(_ profile: Profile) -> some View {
        HStack(alignment: .center, spacing: 32) {
            if let path = media.first(where: { $0.kind == "portrait" })?.localAssetPath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(profile.displayName)
                    .font(AppTypography.screenTitle)
                VStack(alignment: .leading, spacing: 4) {
                    if let birth = profile.birthDate {
                        vitalRow(label: "Born", date: birth, place: profile.birthLocation)
                    }
                    if let death = profile.deathDate {
                        vitalRow(label: "Died", date: death, place: profile.deathLocation)
                    }
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
        HStack(spacing: 8) {
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Life events")
                .font(AppTypography.cardTitle)
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(event.sortYear.map(String.init) ?? "—")
                        .font(AppTypography.timelineYear)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Photos & documents")
                .font(AppTypography.cardTitle)
            ScrollView(.horizontal) {
                HStack(spacing: 24) {
                    ForEach(media) { item in
                        if let path = item.localAssetPath,
                           let image = UIImage(contentsOfFile: path) {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 380, height: 280)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
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
