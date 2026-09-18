import Foundation

/// Dossier #T9-Change1 — the deterministic investigation dossier.
///
/// Pure, nonisolated, unit-testable (same posture as `ConflictDetector`):
/// `(rows) → Dossier`. Zero writes — the inputs are plain values, the
/// assembler holds no database handle, so "no DB writes during assembly" is
/// true by construction. Zero model calls: this is the skeleton that is
/// always available, model or no model. Every sentence is a
/// `GroundedSentence` (constructor-enforced ≥1 provenance ref); confidence
/// language comes only from `ConfidenceVocabulary`; verbatim-string doctrine
/// applies to dispute reasoning / rule IDs (never re-worded).
nonisolated struct DossierAssembler {

    struct Inputs {
        let profile: Profile
        let disputes: [DisputeRow]
        let evidence: [EvidenceRecord]
        let hypotheses: [ResearchHypothesis]
        let negativeSearches: [NegativeSearchRow]
        /// Most recent completed research run, when any exists.
        let lastRun: LastRun?
        /// Live GPS score — present only when assembled in a session that
        /// holds a run result (review surfaces). The profile-page door
        /// renders the stored `lastRun` summary instead.
        let liveGPS: GPSScore?
        /// Live candidate clusters (same availability caveat).
        let liveClusters: [LifeCluster]
        let sourceInfoMap: [String: SourceInfo]
        let now: Date

        struct LastRun {
            let id: String
            let date: Date
            let gps: Int?
            let mode: String
        }
    }

    static func assemble(_ inputs: Inputs) -> Dossier {
        let sections = [
            d0Header(inputs),
            d1WhatWeKnow(inputs),
            d2WhatConflicts(inputs),
            d3WhatsMissing(inputs),
            d4Investigating(inputs),
            d5Candidates(inputs),
        ]
        let counts: [String: Int] = [
            "D1": acceptedFactRows(inputs).count,
            "D2": inputs.disputes.count,
            "D3": inputs.negativeSearches.count,
            "D4": inputs.hypotheses.count,
            "D5": inputs.liveClusters.count,
        ]
        let footer = DossierFooter(
            generatedAt: inputs.now,
            skeletonHash: Dossier.skeletonHash(of: sections),
            rowCounts: counts,
            narrationMode: "deterministic",
            termination: "no challenge pass run yet")
        return Dossier(
            subjectID: inputs.profile.id,
            subjectName: inputs.profile.displayName,
            sections: sections,
            footer: footer)
    }

    // MARK: - D0 header

    private static func d0Header(_ inputs: Inputs) -> DossierSection {
        var sentences: [GroundedSentence] = []
        if let gps = inputs.liveGPS {
            for (index, criterion) in gps.criteria.enumerated() {
                // Criterion reason strings VERBATIM (spec D0) — they were
                // rewritten for honesty in CL3 and enumerate open disputes.
                if let s = GroundedSentence(
                    text: "\(criterion.criterion.rawValue): \(criterion.met ? "met" : "not met") — \(criterion.reason)",
                    refs: [.gpsCriterion(index + 1)]) {
                    sentences.append(s)
                }
            }
        } else if let run = inputs.lastRun {
            let gpsText = run.gps.map { "GPS \($0)/5" } ?? "GPS not scored"
            if let s = GroundedSentence(
                text: "\(gpsText) at the last research run (\(Self.dayFormatter.string(from: run.date)), \(run.mode)). Criterion detail is computed live during a run.",
                refs: [.researchRun(run.id)]) {
                sentences.append(s)
            }
        }
        let rankedClusters = inputs.liveClusters.compactMap { c in c.matchQuality.map { (c, $0) } }
        let best = rankedClusters.first { $0.1 == .confirmed }
            ?? rankedClusters.first { $0.1 == .possible }
        if let (cluster, quality) = best {
            if let s = GroundedSentence(
                text: "Primary candidate cluster: \(ConfidenceVocabulary.phrase(for: quality)) (\(cluster.records.count) record\(cluster.records.count == 1 ? "" : "s")).",
                refs: [.cluster(cluster.id)]) {
                sentences.append(s)
            }
        }
        return DossierSection(
            id: "D0", title: "Standing", sentences: sentences,
            emptyState: sentences.isEmpty
                ? "No research run recorded — the dossier reflects stored rows only." : nil)
    }

    // MARK: - D1 what we know

    private static func acceptedFactRows(_ inputs: Inputs) -> [EvidenceRecord] {
        inputs.evidence.filter { $0.verdict == .fact && $0.userStatus != .discarded }
    }

    private static func d1WhatWeKnow(_ inputs: Inputs) -> DossierSection {
        let facts = acceptedFactRows(inputs)
        let groups = ConvergenceEngine.scoreValueGroups(
            records: facts.map(\.record), sourceInfoMap: inputs.sourceInfoMap)
        var sentences: [GroundedSentence] = []
        for group in groups.sorted(by: { $0.key < $1.key }) {
            let ids = Set(group.records.map(\.id))
            let refs = facts.filter { ids.contains($0.record.id) }
                .map { ProvenanceRef.evidenceRecord($0.sourceRecordID) }
            guard !refs.isEmpty else { continue }
            let witnesses = group.sourcing.independentWitnessCount
            let witnessText = witnesses == 1 ? "1 independent witness" : "\(witnesses) independent witnesses"
            if let s = GroundedSentence(
                text: "\(valueLabel(group.key)) — \(witnessText); convergence: \(ConfidenceVocabulary.phrase(for: group.level)).",
                refs: refs) {
                sentences.append(s)
            }
        }
        return DossierSection(
            id: "D1", title: "What we know", sentences: sentences,
            emptyState: sentences.isEmpty
                ? "No accepted facts — nothing has been applied or confirmed from research yet." : nil)
    }

    /// "birth:1883" → "Birth 1883"; "marriage:?" → "Marriage (undated)".
    static func valueLabel(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = (parts.first ?? key).capitalized
        guard parts.count == 2, parts[1] != "?" else { return "\(kind) (undated)" }
        return "\(kind) \(parts[1])"
    }

    // MARK: - D2 what conflicts

    private static func d2WhatConflicts(_ inputs: Inputs) -> DossierSection {
        var sentences: [GroundedSentence] = []
        let open = inputs.disputes.filter { isOpen($0) }
        let resolved = inputs.disputes.filter { !isOpen($0) }
        for dispute in open {
            var text = "Open conflict on \(dispute.field) (\(reasonLabel(dispute.reason)))"
            if let summary = dispute.witnessSummary, !summary.isEmpty {
                // Verbatim-string doctrine: the stored weighing IS the text.
                text += ": \(summary)"
            }
            if let s = GroundedSentence(text: text + ".", refs: [.dispute(String(dispute.id))]) {
                sentences.append(s)
            }
        }
        for dispute in resolved {
            let how: String
            switch dispute.resolution {
            case .rule(let id, _): how = "Resolved by \(id)"
            case .accepted: how = "Resolved by accepting a source value"
            case .manual(let note): how = "Resolved manually: \(note)"
            case .deferred, nil: continue
            }
            var text = "\(dispute.field): \(how)"
            if let trace = dispute.ladderTrace, let firstLine = trace.split(separator: "\n").first {
                text += " — \(firstLine)"
            }
            if let s = GroundedSentence(text: text + ".", refs: [.dispute(String(dispute.id))]) {
                sentences.append(s)
            }
        }
        return DossierSection(
            id: "D2", title: "What conflicts", sentences: sentences,
            emptyState: sentences.isEmpty ? "No evidence conflicts recorded." : nil)
    }

    /// `.deferred` is "parked, decide later" — still open (CONFLICT_LAYER).
    private static func isOpen(_ dispute: DisputeRow) -> Bool {
        switch dispute.resolution {
        case nil, .deferred: true
        default: false
        }
    }

    private static func reasonLabel(_ reason: DisputeReason) -> String {
        switch reason {
        case .noOverlap: "values do not overlap"
        case .approximateOverlap: "values overlap only approximately"
        case .valueMismatch: "value mismatch"
        }
    }

    // MARK: - D3 what's missing

    private static func d3WhatsMissing(_ inputs: Inputs) -> DossierSection {
        var sentences: [GroundedSentence] = []
        // (a) searched and absent — ONLY clean negatives may claim absence.
        for row in inputs.negativeSearches where row.isCleanNegative {
            if let s = GroundedSentence(
                text: "\(row.sourceID) \(row.recordType) searched \(Self.dayFormatter.string(from: row.searchedAt)): no match.",
                refs: [.negativeSearch(String(row.id))]) {
                sentences.append(s)
            }
        }
        // (b) partial answers — explicitly labelled, never a gap claim.
        for row in inputs.negativeSearches where !row.isCleanNegative {
            let kind = row.resultKind ?? "partial"
            if let s = GroundedSentence(
                text: "\(row.sourceID) \(row.recordType) searched \(Self.dayFormatter.string(from: row.searchedAt)): partial answer (\(kind)) — not evidence of absence.",
                refs: [.negativeSearch(String(row.id))]) {
                sentences.append(s)
            }
        }
        // (c) structural gaps — in-scope census years with neither a record
        // nor a clean negative.
        let uncovered = uncoveredCensusYears(inputs)
        if !uncovered.isEmpty {
            let years = uncovered.map(String.init).joined(separator: ", ")
            if let s = GroundedSentence(
                text: "Census years in lifetime never covered: \(years) — no record and no clean negative.",
                refs: [.profileField(profileID: inputs.profile.id, field: "birthDate")]) {
                sentences.append(s)
            }
        }
        return DossierSection(
            id: "D3", title: "What's missing", sentences: sentences,
            emptyState: sentences.isEmpty
                ? "No negative searches recorded — absence here means not yet searched, not searched-and-absent." : nil)
    }

    /// UK census years inside the subject's lifetime with no census evidence
    /// row and no clean census negative.
    static func uncoveredCensusYears(_ inputs: Inputs) -> [Int] {
        guard let birth = inputs.profile.birthDate?.bestYear else { return [] }
        let death = inputs.profile.deathDate?.bestYear ?? min(birth + 90, 1921)
        let inScope = stride(from: 1841, through: 1921, by: 10).filter { $0 >= birth && $0 <= death }
        guard !inScope.isEmpty else { return [] }
        var covered: Set<Int> = []
        for row in inputs.evidence where row.userStatus != .discarded {
            if case .census(let c) = row.record { covered.insert(c.censusYear) }
        }
        for row in inputs.negativeSearches
        where row.isCleanNegative && row.recordType.lowercased().contains("census") {
            for year in inScope where (row.searchParams ?? "").contains(String(year)) {
                covered.insert(year)
            }
        }
        return inScope.filter { !covered.contains($0) }
    }

    // MARK: - D4 what's being investigated

    private static func d4Investigating(_ inputs: Inputs) -> DossierSection {
        var sentences: [GroundedSentence] = []
        let ordered = inputs.hypotheses.sorted {
            ($0.candidateGroupID ?? "", $0.id) < ($1.candidateGroupID ?? "", $1.id)
        }
        for hypothesis in ordered {
            var text = "\(kindLabel(hypothesis.kind)): \(ConfidenceVocabulary.phrase(for: hypothesis.verdict))"
            if hypothesis.attempts > 0 {
                text += " after \(hypothesis.attempts) attempt\(hypothesis.attempts == 1 ? "" : "s")"
            }
            if let group = hypothesis.candidateGroupID {
                text += " [choose-one group \(group)]"
            }
            text += " (\(hypothesis.origin.rawValue))"
            if !hypothesis.reasoning.isEmpty {
                // Verbatim-string doctrine.
                text += " — \(hypothesis.reasoning)"
            }
            if let s = GroundedSentence(text: text, refs: [.hypothesis(hypothesis.id)]) {
                sentences.append(s)
            }
        }
        return DossierSection(
            id: "D4", title: "What's being investigated", sentences: sentences,
            emptyState: sentences.isEmpty ? "No hypotheses under investigation." : nil)
    }

    // MARK: - D5 candidate comparison

    private static func d5Candidates(_ inputs: Inputs) -> DossierSection {
        let rivals = inputs.liveClusters
            .compactMap { cluster in cluster.matchQuality.map { (cluster, $0) } }
            .filter { $0.1 != .wrong }
        var sentences: [GroundedSentence] = []
        if rivals.count >= 2 {
            for (index, rival) in rivals.enumerated() {
                let (cluster, quality) = rival
                var text = "Candidate \(index + 1) (\(ConfidenceVocabulary.phrase(for: quality))): "
                if let birth = cluster.impliedBirthYear { text += "b.~\(birth), " }
                text += "\(cluster.records.count) record\(cluster.records.count == 1 ? "" : "s")"
                if let s = GroundedSentence(text: text + ".", refs: [.cluster(cluster.id)]) {
                    sentences.append(s)
                }
            }
            let birthYears = Set(rivals.compactMap { $0.0.impliedBirthYear })
            if birthYears.count >= 2 {
                let years = birthYears.sorted().map(String.init).joined(separator: " vs ")
                if let s = GroundedSentence(
                    text: "The candidates diverge on implied birth year: \(years).",
                    refs: rivals.map { .cluster($0.0.id) }) {
                    sentences.append(s)
                }
            }
        }
        return DossierSection(
            id: "D5", title: "Candidate comparison", sentences: sentences,
            emptyState: sentences.isEmpty
                ? "No rival identification in play — a single candidate (or no live run in memory)." : nil)
    }

    /// "birthYearCandidate(…)" → "Birth year candidate" — a generic label
    /// from the case name, robust to future kinds (no exhaustive switch to
    /// go stale).
    static func kindLabel(_ kind: HypothesisKind) -> String {
        let caseName = Mirror(reflecting: kind).children.first?.label ?? String(describing: kind)
        var words = ""
        for ch in caseName {
            if ch.isUppercase && !words.isEmpty { words.append(" ") }
            words.append(ch.lowercased())
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}
