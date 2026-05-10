import Foundation

/// Pure substring matching used by the workbench-wide search. Lives outside
/// AppState so it can be unit-tested without spinning up a MainActor host.
nonisolated enum WorkbenchSearch {

    /// Apply substring matching across all four cached entity types and
    /// return the hits in display order. Caller should still hit the FTS
    /// index for notes when relevance ranking matters; this function is
    /// the fallback used by tests and by note-less filters.
    static func matches(
        query: String,
        notes: [WorkbenchNote],
        questions: [OpenQuestion],
        hypotheses: [Hypothesis],
        focusSets: [FocusSet]
    ) -> [WorkbenchSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        var results: [WorkbenchSearchResult] = []
        for n in notes where matchesNote(n, needle: needle) {
            results.append(.note(n))
        }
        for q in questions where matchesQuestion(q, needle: needle) {
            results.append(.question(q))
        }
        for h in hypotheses where matchesHypothesis(h, needle: needle) {
            results.append(.hypothesis(h))
        }
        for f in focusSets where matchesFocusSet(f, needle: needle) {
            results.append(.focusSet(f))
        }
        return results
    }

    static func matchesNote(_ n: WorkbenchNote, needle: String) -> Bool {
        n.content.lowercased().contains(needle)
    }

    static func matchesQuestion(_ q: OpenQuestion, needle: String) -> Bool {
        if q.text.lowercased().contains(needle) { return true }
        if (q.triedSources ?? "").lowercased().contains(needle) { return true }
        if (q.resolution ?? "").lowercased().contains(needle) { return true }
        return false
    }

    static func matchesHypothesis(_ h: Hypothesis, needle: String) -> Bool {
        if h.reasoning.lowercased().contains(needle) { return true }
        if h.claimSummary.lowercased().contains(needle) { return true }
        if h.supportingEvidence.contains(where: { $0.lowercased().contains(needle) }) { return true }
        if h.contradictingEvidence.contains(where: { $0.lowercased().contains(needle) }) { return true }
        if (h.dismissalReason ?? "").lowercased().contains(needle) { return true }
        return false
    }

    static func matchesFocusSet(_ f: FocusSet, needle: String) -> Bool {
        (f.title ?? "").lowercased().contains(needle)
    }
}
