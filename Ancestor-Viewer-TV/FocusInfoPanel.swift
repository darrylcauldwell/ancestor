import SwiftUI
import AncestorKit
import AncestorViewerKit

/// The primary reading experience (PHASE4_VIEWER_SPEC §5): a glass panel
/// beside the tree narrating whoever is focal — name, vitals, portrait,
/// and the publish-time bio prose. Redacted persons show the name card
/// only; that is the privacy design, not a gap.
struct FocusInfoPanel: View {
    let personID: String
    let tree: ViewerTree
    let refreshing: Bool

    private var profile: Profile? { tree.snapshot.profiles[personID] }
    private var annotations: ViewerAnnotations? { tree.annotations[personID] }
    private var portraitPath: String? {
        tree.media[personID]?.first { $0.kind == "portrait" }?.localAssetPath
    }

    var body: some View {
        if let profile {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    if let path = portraitPath, let image = UIImage(contentsOfFile: path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.displayName)
                            .font(AppTypography.panelName)
                        if let vitals = vitalsLine(for: profile) {
                            Text(vitals)
                                .font(AppTypography.panelVitals)
                                .foregroundStyle(.secondary)
                        }
                        if annotations?.isRedacted == true {
                            Label("Details private", systemImage: "lock")
                                .font(AppTypography.badge)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let bio = profile.bio {
                    Text(bio)
                        .font(AppTypography.panelBio)
                        .lineLimit(9)
                        .frame(maxWidth: 560, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Text("Press to read more  ·  Hold to find a person")
                        .font(AppTypography.controlLabel)
                        .foregroundStyle(.tertiary)
                    if refreshing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func vitalsLine(for profile: Profile) -> String? {
        var parts: [String] = []
        if let birth = profile.birthDate?.bestYear {
            var line = "b. \(birth)"
            if let place = profile.birthLocation {
                line += ", \(place.components(separatedBy: ",").first ?? place)"
            }
            parts.append(line)
        }
        if let death = profile.deathDate?.bestYear {
            parts.append("d. \(death)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
