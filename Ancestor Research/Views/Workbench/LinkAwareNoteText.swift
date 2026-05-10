import SwiftUI

/// Renders a note's Markdown-ish content, replacing `[[Profile Name]]`
/// markers (DESIGN.md §7.7.5) with tappable hyperlink-style buttons.
///
/// Plain text segments use `Text`; link segments use a small `Button`
/// styled blue + underlined. When a name resolves uniquely the tap fires
/// `onLinkTapped` directly. Ambiguous names (multiple matches) open an
/// alert listing the candidates so the user can pick one. Unknown names
/// stay visible (still bracketed, dimmed) to flag the dangling reference.
///
/// Presentation-only — never mutates AppState or the database.
struct LinkAwareNoteText: View {
    let content: String
    let snapshot: FamilyGraphSnapshot
    var onLinkTapped: (Profile) -> Void

    @State private var ambiguousName: AmbiguousLink?

    var body: some View {
        // Compose tokens into a single inline run using string concatenation
        // for plain `Text`, with link segments handled as Buttons. SwiftUI
        // doesn't render Buttons inline with Text, so we lay tokens out via
        // a wrapping HStack of small components.
        FlowLayout(spacing: 0) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .text(let s):
                    Text(s)
                case .link(let name, let profileID):
                    linkButton(displayName: name, profileID: profileID)
                }
            }
        }
        .alert(item: $ambiguousName) { ambig in
            Alert(
                title: Text("Multiple matches for \"\(ambig.name)\""),
                message: Text("Pick one to open."),
                primaryButton: .default(Text(ambig.candidates.first.map(label(for:)) ?? "First")) {
                    if let p = ambig.candidates.first { onLinkTapped(p) }
                },
                secondaryButton: .cancel()
            )
        }
        // For 3+ candidates we fall back to a confirmationDialog driven by
        // the same state — alert above only handles the binary case cleanly.
        .confirmationDialog(
            ambiguousName.map { "Multiple matches for \"\($0.name)\"" } ?? "",
            isPresented: Binding(
                get: { (ambiguousName?.candidates.count ?? 0) > 2 },
                set: { if !$0 { ambiguousName = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let ambig = ambiguousName {
                ForEach(ambig.candidates) { profile in
                    Button(label(for: profile)) {
                        onLinkTapped(profile)
                        ambiguousName = nil
                    }
                }
                Button("Cancel", role: .cancel) { ambiguousName = nil }
            }
        }
    }

    private var tokens: [ProfileLinkParser.Token] {
        ProfileLinkParser.parse(content, snapshot: snapshot)
    }

    @ViewBuilder
    private func linkButton(displayName: String, profileID: String?) -> some View {
        if let id = profileID, let profile = snapshot.profiles[id] {
            Button {
                onLinkTapped(profile)
            } label: {
                Text(displayName)
                    .underline()
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        } else {
            // Either zero matches (unresolvable) or ambiguous (>1).
            let candidates = ProfileLinkParser.candidates(for: displayName, snapshot: snapshot)
            if candidates.isEmpty {
                Text("[[\(displayName)]]")
                    .foregroundStyle(.tertiary)
                    .help("No profile named \"\(displayName)\" in this tree.")
                    .accessibilityHint("No profile named \(displayName) in this tree.")
            } else {
                Button {
                    if candidates.count == 1 {
                        onLinkTapped(candidates[0])
                    } else {
                        ambiguousName = AmbiguousLink(name: displayName, candidates: candidates)
                    }
                } label: {
                    Text(displayName)
                        .underline()
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("\(candidates.count) profiles named \"\(displayName)\" — tap to choose.")
                .accessibilityHint("\(candidates.count) profiles named \(displayName). Activate to choose one.")
            }
        }
    }

    private func label(for profile: Profile) -> String {
        var parts: [String] = [profile.displayName]
        if let yr = profile.birthDate?.bestYear {
            parts.append("b. \(yr)")
        } else if let wt = profile.wikiTreeID {
            parts.append(wt)
        } else {
            parts.append(String(profile.id.prefix(8)))
        }
        return parts.joined(separator: " — ")
    }

    private struct AmbiguousLink: Identifiable {
        let name: String
        let candidates: [Profile]
        var id: String { name }
    }
}

/// Minimal flow layout — wraps children onto multiple lines like text.
/// Used here because Buttons can't be inlined into a `Text` run.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let arrangement = arrange(subviews: subviews, width: width)
        return CGSize(width: arrangement.width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, width: bounds.width)
        for (index, frame) in arrangement.frames.enumerated() {
            let origin = CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY)
            subviews[index].place(at: origin, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> (frames: [CGRect], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                // Wrap
                maxRowWidth = max(maxRowWidth, x)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        maxRowWidth = max(maxRowWidth, x)
        return (frames, maxRowWidth, y + rowHeight)
    }
}
