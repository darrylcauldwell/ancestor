import SwiftUI
import AncestorKit

/// CONFLICT_LAYER_SPEC ⟨G5⟩ — the choose-one candidate card. All rivals in
/// one `candidateGroupID` render as a SINGLE card with radio selection and
/// exactly ONE action control; accepting marks every rival `.contradicted`
/// in the same user action (the atomic core shipped with CL5/CL6 — this is
/// its surface).
struct CandidateGroupCard: View {
    @Environment(AppState.self) private var appState
    let group: [ResearchHypothesis]
    let profile: Profile
    /// Called after a successful accept so the owner reloads.
    let onResolved: () -> Void

    @State private var selectedID: String?
    @State private var actionError: String?

    private var isYearGroup: Bool {
        group.contains {
            if case .birthYearCandidate = $0.kind { return true }
            if case .deathYearCandidate = $0.kind { return true }
            return false
        }
    }

    private var title: String {
        guard let first = group.first else { return "Candidates" }
        switch first.kind {
        case .birthYearCandidate: return "Birth year — \(group.count) candidates"
        case .deathYearCandidate: return "Death year — \(group.count) candidates"
        case .parentIdentityCandidate(_, let role, _):
            return "Biological \(role) — \(group.count) candidates"
        default: return "Candidates"
        }
    }

    private func memberLabel(_ h: ResearchHypothesis) -> String {
        switch h.kind {
        case .birthYearCandidate(_, let year), .deathYearCandidate(_, let year):
            return String(year)
        case .parentIdentityCandidate(_, _, let name):
            return name
        default:
            return h.id
        }
    }

    /// Year candidates are only acceptable when deterministically
    /// supported (the ApplyEngine guard); parent identities are the
    /// human's to choose freely.
    private func isSelectable(_ h: ResearchHypothesis) -> Bool {
        isYearGroup ? h.verdict == .supported : h.verdict != .contradicted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(group, id: \.id) { member in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selectedID == member.id
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelectable(member) ? Color.accentColor : .secondary)
                        .onTapGesture {
                            if isSelectable(member) { selectedID = member.id }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(memberLabel(member))
                                .font(.body)
                                .fontWeight(.semibold)
                            verdictBadge(member.verdict)
                        }
                        Text(member.reasoning)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            // ⟨G5⟩ exactly one action control per group.
            HStack {
                Button(isYearGroup ? "Accept selected year" : "Keep selected parent") {
                    acceptSelected()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(selectedID == nil)

                if !isYearGroup {
                    Button("Keep both") { keepBoth() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            if let actionError {
                Text(actionError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    private func acceptSelected() {
        guard let db = appState.currentDatabase,
              let chosen = group.first(where: { $0.id == selectedID }) else { return }
        do {
            switch chosen.kind {
            case .birthYearCandidate:
                try ApplyEngine.applyBirthYearCandidate(
                    chosen, snapshot: appState.snapshot, db: db)
                if let groupID = chosen.candidateGroupID {
                    try db.contradictRivals(inCandidateGroup: groupID, acceptedID: chosen.id)
                }
            case .deathYearCandidate:
                try ApplyEngine.applyDeathYearCandidate(
                    chosen, snapshot: appState.snapshot, db: db)
            case .parentIdentityCandidate(_, let role, let name):
                guard let parentRole = ParentRole(rawValue: role),
                      let keep = appState.snapshot.parentsOf(profile.id)
                        .first(where: { $0.displayName == name }) else {
                    actionError = "Candidate '\(name)' has no matching tree edge to keep."
                    return
                }
                try ConflictResolutionActions.chooseParent(
                    subjectID: profile.id, role: parentRole,
                    keepParentID: keep.id,
                    snapshot: appState.snapshot, db: db)
            default:
                return
            }
            appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
            onResolved()
        } catch {
            actionError = "Accept failed: \(error.localizedDescription)"
        }
    }

    private func keepBoth() {
        guard let db = appState.currentDatabase,
              case .parentIdentityCandidate(_, let role, _)? = group.first?.kind,
              let parentRole = ParentRole(rawValue: role) else { return }
        do {
            try ConflictResolutionActions.keepBothParents(
                subjectID: profile.id, role: parentRole, db: db)
            onResolved()
        } catch {
            actionError = "Keep-both failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: ResearchHypothesis.Verdict) -> some View {
        Text(verdict.rawValue)
            .font(AppTypography.badge)
            .foregroundStyle(verdict == .supported ? .green
                             : verdict == .contradicted ? .red : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
    }
}
