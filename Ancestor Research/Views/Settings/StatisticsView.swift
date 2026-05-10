import SwiftUI

/// Settings → Statistics. M20 (DESIGN.md §13 platform extensions).
///
/// Read-only dashboard derived from the current snapshot, the project's home
/// person, and the persisted session log. All metric work is delegated to the
/// pure helper `StatisticsCalculator` — this view is presentation only.
struct StatisticsView: View {
    @Environment(AppState.self) private var appState

    @State private var statistics: StatisticsCalculator.ProjectStatistics?
    @State private var hasHomePerson: Bool = false

    var body: some View {
        Group {
            if let stats = statistics {
                if stats.profileCount == 0 {
                    ContentUnavailableView(
                        "No profiles yet",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Import a GEDCOM or add profiles to see statistics for this project.")
                    )
                } else {
                    statisticsForm(stats: stats)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Statistics")
        .onAppear { reload() }
    }

    // MARK: - Form

    @ViewBuilder
    private func statisticsForm(stats: StatisticsCalculator.ProjectStatistics) -> some View {
        Form {
            treeSection(stats: stats)
            lifespanSection(stats: stats)
            surnamesSection(stats: stats)
            geographySection(stats: stats)
            sourceCoverageSection(stats: stats)
            timeInvestedSection(stats: stats)
        }
        .formStyle(.grouped)
    }

    private func treeSection(stats: StatisticsCalculator.ProjectStatistics) -> some View {
        Section("Tree") {
            LabeledContent("Profiles", value: "\(stats.profileCount)")
            LabeledContent("Potentially living", value: "\(stats.livingPotentially)")

            if hasHomePerson {
                LabeledContent("Ancestor generations", value: "\(stats.maxAncestorGenerations)")
                LabeledContent("Descendant generations", value: "\(stats.maxDescendantGenerations)")
                LabeledContent("Total ancestors", value: "\(stats.totalAncestorsFromHome)")
                LabeledContent("Total descendants", value: "\(stats.totalDescendantsFromHome)")
            } else {
                LabeledContent("Generations") {
                    Text("Set a home person to compute generation depth.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func lifespanSection(stats: StatisticsCalculator.ProjectStatistics) -> some View {
        Section("Lifespan") {
            LabeledContent("Average lifespan") {
                if let avg = stats.averageLifespanYears {
                    Text(String(format: "%.1f years", avg))
                        .font(AppTypography.cardBody)
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Median death year") {
                if let median = stats.medianDeathYear {
                    Text("\(median)")
                        .font(AppTypography.cardBody)
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func surnamesSection(stats: StatisticsCalculator.ProjectStatistics) -> some View {
        Section("Top Surnames") {
            if stats.topSurnames.isEmpty {
                Text("No surnames recorded.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(stats.topSurnames, id: \.surname) { entry in
                    HStack {
                        Text(entry.surname)
                            .font(AppTypography.cardBody)
                        Spacer()
                        Text("\(entry.count)")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func geographySection(stats: StatisticsCalculator.ProjectStatistics) -> some View {
        Section("Geography") {
            DisclosureGroup("Top birth locations (\(stats.topBirthLocations.count))") {
                if stats.topBirthLocations.isEmpty {
                    Text("No birth locations recorded.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stats.topBirthLocations, id: \.location) { entry in
                        HStack {
                            Text(entry.location)
                                .font(AppTypography.cardBody)
                                .lineLimit(2)
                            Spacer()
                            Text("\(entry.count)")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            DisclosureGroup("Top death locations (\(stats.topDeathLocations.count))") {
                if stats.topDeathLocations.isEmpty {
                    Text("No death locations recorded.")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stats.topDeathLocations, id: \.location) { entry in
                        HStack {
                            Text(entry.location)
                                .font(AppTypography.cardBody)
                                .lineLimit(2)
                            Spacer()
                            Text("\(entry.count)")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func sourceCoverageSection(stats: StatisticsCalculator.ProjectStatistics) -> some View {
        Section("Source Coverage") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(stats.sourceCoveragePercent)%")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(coverageColour(percent: stats.sourceCoveragePercent))
                Text("\(stats.sourcedFieldCount) of \(stats.valuedFieldCount) fields cited.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func timeInvestedSection(stats: StatisticsCalculator.ProjectStatistics) -> some View {
        Section("Time Invested") {
            LabeledContent("Total hours") {
                if stats.totalHoursInvested > 0 {
                    Text(String(format: "%.1f hours", stats.totalHoursInvested))
                        .font(AppTypography.cardBody)
                        .monospacedDigit()
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Loading

    private func reload() {
        let homeID = appState.currentProject?.homePersonID
        hasHomePerson = (homeID != nil)
        let sessions = (try? appState.currentDatabase?.loadSessions(limit: 10_000)) ?? []
        statistics = StatisticsCalculator.compute(
            snapshot: appState.snapshot,
            homePersonID: homeID,
            sessions: sessions
        )
    }

    private func coverageColour(percent: Int) -> Color {
        switch percent {
        case 75...: return .green
        case 40..<75: return .orange
        default: return .secondary
        }
    }
}
