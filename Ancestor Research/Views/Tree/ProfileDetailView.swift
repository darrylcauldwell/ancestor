import SwiftUI

/// Inspector panel showing full profile details with source badges.
struct ProfileDetailView: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    var onSetRoot: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                    if let wikiTreeID = profile.wikiTreeID {
                        Text(wikiTreeID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let comp = snapshot.completeness(for: profile.id)
                    HStack(spacing: 4) {
                        Text("\(comp.score)/\(comp.maximum)")
                            .font(.caption)
                            .foregroundStyle(comp.score == comp.maximum ? .green : .orange)
                        if comp.potentiallyLiving {
                            Text("(living)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Divider()

                // Fields with source badges
                fieldRow("Birth", value: profile.birthDate?.original, place: profile.birthLocation, field: .birthDate)
                fieldRow("Death", value: profile.deathDate?.original, place: profile.deathLocation, field: .deathDate)

                if let gender = profile.gender {
                    LabeledContent("Gender") {
                        Text(gender.rawValue.capitalized)
                    }
                }

                Divider()

                // Relationships
                relationshipSection("Parents", profiles: snapshot.parentsOf(profile.id))
                relationshipSection("Spouses", profiles: snapshot.spousesOf(profile.id))
                relationshipSection("Children", profiles: snapshot.childrenOf(profile.id))
                relationshipSection("Siblings", profiles: snapshot.siblingsOf(profile.id))

                // Disputes
                if !profile.disputes.isEmpty {
                    Divider()
                    Text("Disputes")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    ForEach(Array(profile.disputes.values), id: \.field) { dispute in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dispute.field.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(dispute.reason.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(dispute.competingSources, id: \.raw) { source in
                                Text("  \(source.origin.identifier): \(source.raw)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // Actions
                if let setRoot = onSetRoot {
                    Divider()
                    Button("Show as Root") {
                        setRoot()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func fieldRow(_ label: String, value: String?, place: String?, field: ProfileField) -> some View {
        if value != nil || place != nil {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    sourceBadges(for: field)
                }
                if let v = value {
                    Text(v)
                        .font(.body)
                }
                if let p = place {
                    Text(p)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceBadges(for field: ProfileField) -> some View {
        let sources = profile.sources[field] ?? []
        HStack(spacing: 2) {
            ForEach(sources, id: \.raw) { source in
                Text(source.origin.identifier.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func relationshipSection(_ title: String, profiles: [Profile]) -> some View {
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(profiles) { relative in
                    HStack {
                        Text(relative.displayName)
                            .font(.callout)
                        if let year = relative.birthDate?.bestYear {
                            Text("b. \(year)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}
