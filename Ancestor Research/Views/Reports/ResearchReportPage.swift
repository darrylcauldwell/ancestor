import SwiftUI

/// Single SwiftUI page rendered to PDF for a research report
/// (DESIGN.md §7.9.5). Multi-page pagination is deferred — overflowing
/// content clips at the page boundary in M10 v1.
///
/// Layout uses the same fixed-point fonts as the other report pages so
/// PDFs print at consistent sizes regardless of system font scaling.
struct ResearchReportPage: View {
    let document: ResearchReportDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            titleSection
            Divider()
            scopeSection
            Divider()
            questionsSection
            Divider()
            hypothesesSection
            Divider()
            findingsSection
            Divider()
            stillOpenSection
            Divider()
            sourcesSection
            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(.black)
    }

    // MARK: - Title / scope

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Research Report")
                .font(.system(size: 22, weight: .bold))
            Text(document.scopeSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Scope")
            Text(document.scopeSummary)
                .font(.system(size: 11))
        }
    }

    // MARK: - Questions

    @ViewBuilder
    private var questionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Questions investigated")
            ForEach(QuestionStatus.allCases, id: \.self) { status in
                if let qs = document.questionsByStatus[status], !qs.isEmpty {
                    Text(status.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 2)
                    ForEach(qs, id: \.id) { question in
                        questionRow(question)
                    }
                }
            }
            if isQuestionsEmpty {
                Text("No questions in scope.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isQuestionsEmpty: Bool {
        document.questionsByStatus.values.allSatisfy { $0.isEmpty }
    }

    private func questionRow(_ q: OpenQuestion) -> some View {
        let names = q.profileIDs
            .compactMap { document.profileNames[$0] ?? $0 }
            .joined(separator: ", ")

        return VStack(alignment: .leading, spacing: 2) {
            Text("• \(q.text)")
                .font(.system(size: 11))
            HStack(spacing: 8) {
                Text("Priority: \(q.priority.displayName)")
                if !names.isEmpty {
                    Text("Profiles: \(names)")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            if let tried = q.triedSources, !tried.isEmpty {
                Text("Tried: \(tried)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let resolution = q.resolution, !resolution.isEmpty {
                Text("Resolution: \(resolution)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
    }

    // MARK: - Hypotheses

    @ViewBuilder
    private var hypothesesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Hypotheses")
            ForEach(HypothesisStatus.allCases, id: \.self) { status in
                if let hs = document.hypothesesByStatus[status], !hs.isEmpty {
                    Text(status.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 2)
                    ForEach(hs, id: \.id) { hypothesis in
                        hypothesisRow(hypothesis)
                    }
                }
            }
            if isHypothesesEmpty {
                Text("No hypotheses in scope.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isHypothesesEmpty: Bool {
        document.hypothesesByStatus.values.allSatisfy { $0.isEmpty }
    }

    private func hypothesisRow(_ h: Hypothesis) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("• \(h.claimSummary)")
                .font(.system(size: 11))
            Text("Confidence: \(h.confidence.displayName) · Supporting: \(h.supportingEvidence.count) · Contradicting: \(h.contradictingEvidence.count)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if !h.reasoning.isEmpty {
                Text("Reasoning: \(h.reasoning)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if h.status == .dismissed, let reason = h.dismissalReason, !reason.isEmpty {
                Text("Dismissed: \(reason)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
    }

    // MARK: - Findings

    @ViewBuilder
    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Findings")
            if document.findings.isEmpty {
                Text("No non-manual sources recorded in scope.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(document.findings, id: \.id) { profile in
                    findingRow(profile)
                }
            }
        }
    }

    private func findingRow(_ profile: Profile) -> some View {
        let nonManualOrigins: [String] = Array(
            Set(
                profile.sources.values.flatMap { sources in
                    sources.compactMap { $0.origin.isManual ? nil : $0.origin.identifier }
                }
            )
        ).sorted()

        return VStack(alignment: .leading, spacing: 2) {
            Text("• \(profile.displayName.isEmpty ? profile.id : profile.displayName)")
                .font(.system(size: 11))
            if !nonManualOrigins.isEmpty {
                Text("Sources: \(nonManualOrigins.joined(separator: ", "))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
    }

    // MARK: - Still open / sources

    @ViewBuilder
    private var stillOpenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Still open")
            if document.stillOpen.isEmpty {
                Text("Nothing outstanding.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(document.stillOpen.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)")
                        .font(.system(size: 11))
                        .padding(.leading, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Sources consulted")
            if document.sourcesConsulted.isEmpty {
                Text("No sources recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(document.sourcesConsulted.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)")
                        .font(.system(size: 11))
                        .padding(.leading, 8)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
    }
}
