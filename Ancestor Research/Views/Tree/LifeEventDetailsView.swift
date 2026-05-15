import SwiftUI

/// Renders the typed payload on a `LifeEvent` — the structured fields the
/// sources emit (rank, cemetery, household members, etc.) that previously
/// got flattened into a freeform description.
///
/// Designed to slot below the description line in any life-events display
/// surface (`ProfileDetailView.lifeEventsSection`, `ProfileTimelineView`).
/// All rows render `key: value` pairs in caption-sized text so they read as
/// supporting metadata rather than primary content.
struct LifeEventDetailsView: View {
    let details: LifeEventDetails

    var body: some View {
        switch details {
        case .military(let m):  militaryBody(m)
        case .probate(let p):   probateBody(p)
        case .burial(let b):    burialBody(b)
        case .census(let c):    censusBody(c)
        }
    }

    // MARK: - Per-case bodies

    @ViewBuilder
    private func militaryBody(_ m: MilitaryDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Rank", m.rank)
            row("Regiment", m.regiment)
            row("Unit", m.unit)
            row("Service no.", m.serviceNumber)
            row("Country", m.countryOfService)
            row("Honours", m.honours)
            row("Cemetery", m.cemetery)
            row("Grave ref.", m.graveRef)
        }
    }

    @ViewBuilder
    private func probateBody(_ p: ProbateDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Grant type", p.grantType)
            row("Registry", p.registry)
            row("Probate no.", p.probateNumber)
            row("Address", p.address)
            if let age = p.ageAtDeath {
                row("Age at death", String(age))
            }
        }
    }

    @ViewBuilder
    private func burialBody(_ b: BurialDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Cemetery", b.cemetery)
            row("Plot", b.plot)
            row("Grave ref.", b.graveRef)
            row("Inscription", b.inscription)
            if b.isVeteran {
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Veteran")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func censusBody(_ c: CensusDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Occupation", c.occupation)
            row("Address", c.address)
            row("District", c.district)
            row("Parish", c.parish)
            if !c.household.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Household (\(c.household.count))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(c.household, id: \.name) { member in
                        HStack(spacing: 4) {
                            Text(member.name)
                                .font(.caption2)
                            if !member.relationship.isEmpty {
                                Text("(\(member.relationship))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let age = member.age {
                                Text("age \(age)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Row helper

    /// One `Label: value` row. Returns EmptyView when value is nil/empty so
    /// callers can list every field unconditionally; absent fields don't
    /// clutter the view.
    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            HStack(spacing: 4) {
                Text("\(label):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(v)
                    .font(.caption2)
            }
        }
    }
}
