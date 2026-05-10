import Foundation

/// Pre-composed Research Report content. Decoupled from rendering so the
/// structure can be unit-tested without spinning up SwiftUI/PDFKit. The
/// renderer (PDF page or Markdown writer) consumes this verbatim.
///
/// Section ordering follows DESIGN.md §7.9.5: Scope, Questions, Hypotheses,
/// Findings, Still open, Sources consulted.
nonisolated struct ResearchReportDocument: Sendable {
    let scopeSummary: String
    let questionsByStatus: [QuestionStatus: [OpenQuestion]]
    let hypothesesByStatus: [HypothesisStatus: [Hypothesis]]
    let findings: [Profile]
    /// Pre-formatted bullet lines ready to drop straight into Markdown / PDF.
    let stillOpen: [String]
    /// Pre-formatted, deduplicated source list.
    let sourcesConsulted: [String]

    /// Lookup for rendering profile-id references as readable names.
    let profileNames: [String: String]
}

/// Pure logic — no UI, no main-actor isolation. Builds a
/// ``ResearchReportDocument`` from raw workbench arrays.
nonisolated enum ResearchReportComposer {

    static func compose(
        focusSetID: UUID?,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote],
        questions: [OpenQuestion],
        hypotheses: [Hypothesis],
        focusSets: [FocusSet],
        sessions: [ResearchSession]
    ) -> ResearchReportDocument {
        // Resolve focus scope -----------------------------------------------
        let focus: FocusSet? = focusSetID.flatMap { id in
            focusSets.first(where: { $0.id == id })
        }
        let focusIDs: Set<String>? = focus.map { Set($0.profileIDs) }

        // Build profile-name lookup for the whole tree (cheap; ids are short).
        let profileNames: [String: String] = snapshot.profiles
            .reduce(into: [:]) { dict, entry in
                dict[entry.key] = entry.value.displayName.isEmpty ? entry.key : entry.value.displayName
            }

        // Profiles in scope --------------------------------------------------
        let scopedProfileIDs: [String]
        if let focusIDs {
            scopedProfileIDs = focusIDs.filter { snapshot.profiles[$0] != nil }.sorted()
        } else {
            scopedProfileIDs = snapshot.profiles.keys.sorted()
        }
        let scopedProfiles: [Profile] = scopedProfileIDs.compactMap { snapshot.profiles[$0] }

        let scopeSummary = buildScopeSummary(
            focus: focus,
            scopedProfiles: scopedProfiles,
            wholeTreeCount: snapshot.profiles.count
        )

        // Filter questions / hypotheses to focus scope ----------------------
        let scopedQuestions: [OpenQuestion]
        let scopedHypotheses: [Hypothesis]
        if let focusIDs {
            scopedQuestions = questions.filter { q in
                !Set(q.profileIDs).isDisjoint(with: focusIDs)
            }
            scopedHypotheses = hypotheses.filter { h in
                !Set(profileIDs(for: h)).isDisjoint(with: focusIDs)
            }
        } else {
            scopedQuestions = questions
            scopedHypotheses = hypotheses
        }

        // Group ---------------------------------------------------------------
        var questionsByStatus: [QuestionStatus: [OpenQuestion]] = [:]
        for status in QuestionStatus.allCases { questionsByStatus[status] = [] }
        for q in scopedQuestions { questionsByStatus[q.status, default: []].append(q) }

        var hypothesesByStatus: [HypothesisStatus: [Hypothesis]] = [:]
        for status in HypothesisStatus.allCases { hypothesesByStatus[status] = [] }
        for h in scopedHypotheses { hypothesesByStatus[h.status, default: []].append(h) }

        // Findings — profiles in scope with at least one non-manual source.
        let findings: [Profile] = scopedProfiles.filter { profile in
            profile.sources.values.contains { sources in
                sources.contains { !$0.origin.isManual }
            }
        }

        // Still open — open + in-progress questions, plus active hypotheses.
        var stillOpen: [String] = []
        for q in (questionsByStatus[.open] ?? []) {
            stillOpen.append("Question (\(q.priority.displayName)): \(q.text)")
        }
        for q in (questionsByStatus[.inProgress] ?? []) {
            stillOpen.append("Question — in progress: \(q.text)")
        }
        for h in (hypothesesByStatus[.active] ?? []) {
            stillOpen.append("Hypothesis (\(h.confidence.displayName)): \(h.claimSummary)")
        }

        // Sources consulted --------------------------------------------------
        var consulted: [String] = []
        var seen: Set<String> = []
        // From questions' triedSources free text (preserve as-is, dedup exact).
        for q in scopedQuestions {
            guard let raw = q.triedSources?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if seen.insert(raw).inserted {
                consulted.append(raw)
            }
        }
        // From profile FieldSource citations (repository / collection pairings).
        for profile in scopedProfiles {
            for sources in profile.sources.values {
                for src in sources {
                    guard let citation = src.citation else { continue }
                    let combined = formatCitationLine(citation)
                    if combined.isEmpty { continue }
                    if seen.insert(combined).inserted {
                        consulted.append(combined)
                    }
                }
            }
        }

        return ResearchReportDocument(
            scopeSummary: scopeSummary,
            questionsByStatus: questionsByStatus,
            hypothesesByStatus: hypothesesByStatus,
            findings: findings,
            stillOpen: stillOpen,
            sourcesConsulted: consulted,
            profileNames: profileNames
        )
    }

    // MARK: - Helpers

    private static func buildScopeSummary(
        focus: FocusSet?,
        scopedProfiles: [Profile],
        wholeTreeCount: Int
    ) -> String {
        if let focus {
            let count = scopedProfiles.count
            let dateRange = formatDateRange(scopedProfiles)
            let geo = formatGeographicRange(scopedProfiles)
            var parts: [String] = []
            parts.append(
                "Focus set \"\(focus.displayTitle)\" — \(count) profile\(count == 1 ? "" : "s")"
            )
            if let dateRange { parts.append(dateRange) }
            if let geo { parts.append(geo) }
            return parts.joined(separator: ". ") + "."
        }
        return "Whole tree, \(wholeTreeCount) profile\(wholeTreeCount == 1 ? "" : "s")."
    }

    /// Earliest birth year ↔ latest death year across the supplied profiles.
    private static func formatDateRange(_ profiles: [Profile]) -> String? {
        var years: [Int] = []
        for p in profiles {
            if let y = p.birthDate?.earliest { years.append(y) }
            if let y = p.birthDate?.latest { years.append(y) }
            if let y = p.deathDate?.earliest { years.append(y) }
            if let y = p.deathDate?.latest { years.append(y) }
        }
        guard let lo = years.min(), let hi = years.max() else { return nil }
        if lo == hi { return "Year \(lo)" }
        return "\(lo)\u{2013}\(hi)"
    }

    /// Comma-joined unique location strings, capped at six entries to keep
    /// the line readable. Locations beyond the cap are summarised as "+N more".
    private static func formatGeographicRange(_ profiles: [Profile]) -> String? {
        var seen: Set<String> = []
        var ordered: [String] = []
        for p in profiles {
            for raw in [p.birthLocation, p.deathLocation] {
                guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if seen.insert(raw).inserted { ordered.append(raw) }
            }
        }
        guard !ordered.isEmpty else { return nil }
        let cap = 6
        if ordered.count <= cap {
            return ordered.joined(separator: "; ")
        }
        let head = ordered.prefix(cap).joined(separator: "; ")
        let extra = ordered.count - cap
        return "\(head); +\(extra) more"
    }

    /// Render one citation line for the "sources consulted" deduplication
    /// list. We prefer collection + repository (the meaningful axes) and fall
    /// back to the citation's full formatted string when those fields are
    /// blank.
    private static func formatCitationLine(_ citation: Citation) -> String {
        let collection = citation.collection?.trimmingCharacters(in: .whitespaces) ?? ""
        let repository = citation.repository?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (collection.isEmpty, repository.isEmpty) {
        case (false, false): return "\(collection) (\(repository))"
        case (false, true): return collection
        case (true, false): return repository
        case (true, true):
            let full = citation.formatted.trimmingCharacters(in: .whitespacesAndNewlines)
            return full
        }
    }

    /// Profile IDs touched by a hypothesis claim — used for focus filtering.
    private static func profileIDs(for hypothesis: Hypothesis) -> [String] {
        switch hypothesis.claim {
        case .relationship(let from, let to, _, _):
            return [from, to]
        case .fieldValue(let id, _, _):
            return [id]
        case .identityMatch(let a, let b):
            return [a, b]
        case .existence(_, let related):
            return related
        }
    }
}
