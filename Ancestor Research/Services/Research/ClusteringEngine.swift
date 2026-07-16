import Foundation

/// Deterministic life clustering engine.
/// Groups scored records into candidate lives using a 5-step algorithm:
/// seed → assign → split → merge-flag → score confidence.
///
/// Design principle: "When in doubt, split."
/// Over-splitting produces more candidate cards for the user.
/// Over-merging produces wrong facts that are hard to undo.
nonisolated struct ClusteringEngine {

    /// Cluster all non-impossible records into candidate lives.
    /// Input: scored records from the pipeline (facts + leads).
    /// Output: life clusters with confidence scores.
    static func cluster(
        records: [ScoredRecord],
        sourceInfoMap: [String: SourceInfo],
        homeChapmanCode: String
    ) -> [LifeCluster] {
        // Filter out impossible records — they don't belong to any life
        let viable = records.filter { $0.verdict != .impossible }
        guard !viable.isEmpty else { return [] }

        // Step 1: SEED clusters from birth/baptism records
        var clusters = seedClusters(from: viable)

        // Step 2: ASSIGN remaining records to clusters
        let unassignedAfterSeed = viable.filter { record in
            !clusters.contains { cluster in cluster.records.contains { $0.id == record.id } }
        }
        assignRecords(unassignedAfterSeed, to: &clusters, homeChapmanCode: homeChapmanCode)

        // Step 3: SPLIT clusters with internal contradictions
        splitContradictions(&clusters, homeChapmanCode: homeChapmanCode)

        // Step 4: FLAG merge candidates (never auto-merge)
        flagMergeCandidates(&clusters)

        // RESEARCH_CONFIDENCE_SPEC Change 5 removed the old `scoreConfidence`
        // step. Callers now derive `EvidenceConfidence` on demand via
        // `LifeCluster.evidenceConfidence(sourceInfoMap:)`.
        _ = sourceInfoMap

        return clusters
    }

    // MARK: - Step 1: Seed

    /// Each distinct birth (different year OR different district) seeds a new cluster.
    /// If no birth records, seed from the earliest record of any type.
    private static func seedClusters(from records: [ScoredRecord]) -> [LifeCluster] {
        var clusters: [LifeCluster] = []

        // Find birth/baptism records
        let birthRecords = records.filter { record in
            switch record.record {
            case .birth: return true
            case .parish(let r): return r.eventType?.lowercased() == "baptism"
            default: return false
            }
        }

        if birthRecords.isEmpty {
            // No births — seed from earliest record
            // Lifespan covers (earliest_year - 80) to (latest_year + 5) per spec
            let years = records.compactMap { yearOf($0) }
            let sorted = records.sorted { yearOf($0) ?? Int.max < yearOf($1) ?? Int.max }
            if let earliest = sorted.first {
                let earliestYear = years.min() ?? 1850
                let latestYear = years.max() ?? earliestYear
                clusters.append(LifeCluster(
                    id: "cluster-\(clusters.count)",
                    records: [earliest],
                    lifespanStart: earliestYear - 80,
                    lifespanEnd: latestYear + 5
                ))
            }
            return clusters
        }

        // Group births by (year, district) — each distinct combo is a separate seed
        var seenSeeds: Set<String> = []
        for record in birthRecords {
            let year = yearOf(record) ?? 0
            let district = extractRecordDistrict(record.record)?.uppercased() ?? ""
            let key = "\(year)_\(district)"
            if seenSeeds.contains(key) { continue }
            seenSeeds.insert(key)

            clusters.append(LifeCluster(
                id: "cluster-\(clusters.count)",
                records: [record],
                lifespanStart: year,
                lifespanEnd: year + 110
            ))
        }

        return clusters
    }

    // MARK: - Step 2: Assign

    /// Score each unassigned record against all clusters.
    /// Assign to highest-scoring cluster if score >= 0.4, else create new cluster.
    private static func assignRecords(_ unassigned: [ScoredRecord], to clusters: inout [LifeCluster], homeChapmanCode: String) {
        // Process in chronological order
        let sorted = unassigned.sorted { yearOf($0) ?? Int.max < yearOf($1) ?? Int.max }

        for record in sorted {
            var bestScore = 0.0
            var bestIndex = -1

            for (i, cluster) in clusters.enumerated() {
                let score = assignmentScore(record: record, cluster: cluster, homeChapmanCode: homeChapmanCode)
                if score > bestScore {
                    bestScore = score
                    bestIndex = i
                }
            }

            if bestScore >= 0.4 && bestIndex >= 0 {
                clusters[bestIndex].records.append(record)
                // Update lifespan bounds if needed
                if let year = yearOf(record) {
                    clusters[bestIndex].lifespanStart = min(clusters[bestIndex].lifespanStart, year)
                    clusters[bestIndex].lifespanEnd = max(clusters[bestIndex].lifespanEnd, year)
                }
            } else {
                // No good match — new cluster
                let year = yearOf(record) ?? 1850
                clusters.append(LifeCluster(
                    id: "cluster-\(clusters.count)",
                    records: [record],
                    lifespanStart: year - 80,
                    lifespanEnd: year + 5
                ))
            }
        }
    }

    /// The earliest death/burial year in the cluster, if any — a hard upper
    /// bound on the life. Nothing can happen after it (+ a small registration /
    /// burial-lag margin). ROADMAP clustering item (c) / LEAD_DISCOVERY §7.
    static let postDeathMarginYears = 2
    private static func clusterDeathYear(_ cluster: LifeCluster) -> Int? {
        cluster.records.compactMap { rec -> Int? in
            switch rec.record {
            case .death(let r): return r.deathYear
            case .burial(let r): return r.deathYear
            default: return nil
            }
        }.min()
    }

    /// Weighted assignment score per the spec formula.
    /// score = date_compatibility × 0.4 + location_consistency × 0.3 + household_confirmation × 0.3
    static func assignmentScore(record: ScoredRecord, cluster: LifeCluster, homeChapmanCode: String) -> Double {
        // A death ends a life: refuse any record dated after the cluster's death
        // (+ lag margin) — you can't marry or be enumerated after you die. It
        // seeds its own cluster instead of merging (over-split, not over-merge).
        if let deathYear = clusterDeathYear(cluster),
           let year = yearOf(record), year > deathYear + postDeathMarginYears {
            return 0.0
        }
        let dateScore = dateCompatibility(record: record, cluster: cluster)
        let locationScore = locationConsistency(record: record, cluster: cluster, homeChapmanCode: homeChapmanCode)
        let householdScore = householdConfirmation(record: record, cluster: cluster)
        return dateScore * 0.4 + locationScore * 0.3 + householdScore * 0.3
    }

    /// 1.0 if record year is within cluster lifespan.
    /// 0.5 if within ±5 of boundary.
    /// 0.0 otherwise.
    private static func dateCompatibility(record: ScoredRecord, cluster: LifeCluster) -> Double {
        guard let year = yearOf(record) else { return 0.5 } // No date = neutral
        if year >= cluster.lifespanStart && year <= cluster.lifespanEnd {
            return 1.0
        }
        let distFromBoundary = min(abs(year - cluster.lifespanStart), abs(year - cluster.lifespanEnd))
        if distFromBoundary <= 5 {
            return 0.5
        }
        return 0.0
    }

    /// 1.0 exact district match, 0.7 same county, 0.3 same region, 0.0 non-local.
    private static func locationConsistency(record: ScoredRecord, cluster: LifeCluster, homeChapmanCode: String) -> Double {
        guard let recordDistrict = extractRecordDistrict(record.record) else {
            return 0.5 // No location = neutral (spec: doesn't penalise or boost)
        }

        let recordClean = recordDistrict.uppercased()
            .replacingOccurrences(of: " DISTRICT", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Exact district match with any record in the cluster
        if cluster.districts.contains(recordClean) {
            return 1.0
        }

        // Same home county — both are in the subject's research region
        let recordIsLocal = ScoringRules.isLocalDistrict(recordClean, forHomeChapman: homeChapmanCode)
        let clusterHasLocal = cluster.districts.contains { ScoringRules.isLocalDistrict($0, forHomeChapman: homeChapmanCode) }
        if recordIsLocal && clusterHasLocal {
            return 0.7
        }

        // Same region — record is local but different county
        if recordIsLocal || clusterHasLocal {
            return 0.3
        }

        // Non-local
        if ScoringRules.isNonLocal(recordClean, forHomeChapman: homeChapmanCode) != nil {
            return 0.0
        }

        return 0.3 // Unknown district — treat as same region
    }

    /// 1.0 if census household matches a known spouse/child in the cluster.
    /// 0.5 if same surname in a family relationship.
    /// 0.0 if no match or no data.
    private static func householdConfirmation(record: ScoredRecord, cluster: LifeCluster) -> Double {
        // Get household from the incoming record (if census)
        guard case .census(let census) = record.record, let household = census.household else {
            return 0.0
        }

        let clusterMembers = cluster.householdMembers
        guard !clusterMembers.isEmpty else { return 0.0 }

        // Check for specific person match (spouse/child name match)
        for member in household {
            let memberName = member.name.uppercased()
            let relationship = member.relationship.lowercased()
            let isFamilyRelation = relationship.contains("wife") ||
                                   relationship.contains("husband") ||
                                   relationship.contains("son") ||
                                   relationship.contains("daughter") ||
                                   relationship.contains("child") ||
                                   relationship.contains("mother") ||
                                   relationship.contains("father")

            if isFamilyRelation {
                // Check if this member appears in cluster's known household
                for knownMember in clusterMembers {
                    if ScoringRules.nameSimilarity(memberName, knownMember.name.uppercased()) >= 0.7 {
                        return 1.0
                    }
                }
            }
        }

        // Check for surname match in family relationship
        let recordSurname = (record.record.surname ?? "").uppercased()
        if !recordSurname.isEmpty {
            for member in household {
                let relationship = member.relationship.lowercased()
                let isFamilyRelation = relationship.contains("wife") ||
                                       relationship.contains("husband") ||
                                       relationship.contains("son") ||
                                       relationship.contains("daughter")
                if isFamilyRelation {
                    let parts = member.name.uppercased().split(separator: " ")
                    if let memberSurname = parts.last, String(memberSurname) == recordSurname {
                        return 0.5
                    }
                }
            }
        }

        return 0.0
    }

    // MARK: - Step 3: Split

    /// Split clusters with internal contradictions.
    /// - Two birth/baptism records → split
    /// - Two death/burial records → split
    /// - Census age-implied birth years differing by >5 → split
    private static func splitContradictions(_ clusters: inout [LifeCluster], homeChapmanCode: String) {
        var didSplit = true

        // Iterate until no more splits needed
        while didSplit {
            didSplit = false
            var i = 0
            while i < clusters.count {
                if let splitResult = findContradiction(in: clusters[i]) {
                    // Keep older records in original cluster, seed new from newer
                    let (keepRecords, newRecords, splitReason) = splitResult
                    clusters[i].records = keepRecords

                    let newYear = newRecords.compactMap { yearOf($0) }.min() ?? 1850
                    var newCluster = LifeCluster(
                        id: "cluster-\(clusters.count)",
                        records: newRecords,
                        lifespanStart: newYear,
                        lifespanEnd: newYear + 110
                    )
                    newCluster.splitReason = splitReason
                    // Note: the split cluster is the post-contradiction half.
                    // Pre-Change-5 we stamped confidence=.ambiguous on it; the
                    // new model derives that signal at display time from the
                    // presence of contradictions in the cluster (handled in
                    // BulkReviewView.frictionTier and the badge's tooltip).

                    // Update original cluster's lifespan
                    if let minYear = clusters[i].records.compactMap({ yearOf($0) }).min() {
                        clusters[i].lifespanStart = minYear
                        clusters[i].lifespanEnd = minYear + 110
                    }

                    clusters.append(newCluster)
                    didSplit = true

                    // Re-assign orphaned records from original cluster
                    let remaining = clusters[i].records.filter { record in
                        !keepRecords.contains { $0.id == record.id }
                    }
                    if !remaining.isEmpty {
                        clusters[i].records = keepRecords
                        assignRecords(remaining, to: &clusters, homeChapmanCode: homeChapmanCode)
                    }
                }
                i += 1
            }
        }
    }

    /// Check for contradictions within a cluster. Returns split groups if found.
    private static func findContradiction(in cluster: LifeCluster) -> (keep: [ScoredRecord], split: [ScoredRecord], reason: String?)? {
        // Check for multiple birth/baptism records
        let births = cluster.records.filter { record in
            switch record.record {
            case .birth: return true
            case .parish(let r): return r.eventType?.lowercased() == "baptism"
            default: return false
            }
        }
        if births.count >= 2 {
            let sorted = births.sorted { yearOf($0) ?? 0 < yearOf($1) ?? 0 }
            let newer = sorted[1]
            // Keep older in this cluster, split newer out
            let keepRecords = cluster.records.filter { $0.id != newer.id }
            return (keepRecords, [newer], nil)
        }

        // Check for multiple death/burial records
        let deaths = cluster.records.filter { record in
            switch record.record {
            case .death: return true
            case .burial: return true
            default: return false
            }
        }
        if deaths.count >= 2 {
            let sorted = deaths.sorted { yearOf($0) ?? 0 < yearOf($1) ?? 0 }
            let newer = sorted[1]
            let keepRecords = cluster.records.filter { $0.id != newer.id }
            return (keepRecords, [newer], nil)
        }

        // A death ends a life. Catch records that merged via a wide birth-seeded
        // lifespan before the death capped it (ROADMAP clustering item c):
        if let deathYear = deaths.compactMap({ yearOf($0) }).min() {
            // (i) any record dated after the death (+ lag) is a different person
            //     — the Ernest case: infant death 1886 + marriage 1915.
            let postDeath = cluster.records.filter { rec in
                guard let y = yearOf(rec) else { return false }
                return y > deathYear + postDeathMarginYears
            }
            if !postDeath.isEmpty {
                let keepRecords = cluster.records.filter { record in
                    !postDeath.contains { $0.id == record.id }
                }
                return (keepRecords, postDeath,
                        "Event after death (died \(deathYear)) — a person can't appear after they die")
            }

            // (ii) a death WITH an age implies a birth (birth ≈ deathYear − age);
            //      a birth record disagreeing by >5 years is a different person —
            //      died 1886 "age 0" ⇒ born ~1886, incompatible with an 1877 birth.
            let deathImpliedBirths: [Int] = deaths.compactMap { rec in
                guard case .death(let d) = rec.record, let age = d.age, let dy = d.deathYear
                else { return nil }
                return dy - age
            }
            if let impliedBirth = deathImpliedBirths.min() {
                let incompatibleBirths = births.filter { rec in
                    guard let by = yearOf(rec) else { return false }
                    return abs(by - impliedBirth) > 5
                }
                if !incompatibleBirths.isEmpty {
                    let keepRecords = cluster.records.filter { record in
                        !incompatibleBirths.contains { $0.id == record.id }
                    }
                    return (keepRecords, incompatibleBirths,
                            "Death age implies birth ~\(impliedBirth), incompatible with birth record")
                }
            }
        }

        // T-D ⟨G13⟩ (CONFLICT_LAYER_SPEC CL2) — same-enumeration-year
        // impossibility: two census records with the SAME censusYear in one
        // cluster cannot be one person (one enumeration per year). Split
        // the later-scored one out; over-splitting is the safe direction
        // (when-in-doubt-split). Catches DS-02 household fusion pre-apply.
        var censusByYear: [Int: [ScoredRecord]] = [:]
        for record in cluster.records {
            if case .census(let r) = record.record {
                censusByYear[r.censusYear, default: []].append(record)
            }
        }
        // Deterministic year selection (CAMPAIGN_REVIEW_SPEC Change 5):
        // Dictionary.first(where:) iterates in hash-seed order, so when TWO
        // census years each held duplicates, which year split first — and
        // therefore cluster ids and append order — varied per process. A DB
        // re-cluster must reproduce the run's clusters, so pick the lowest
        // duplicated year.
        if let year = censusByYear.filter({ $0.value.count >= 2 }).keys.min(),
           let duplicates = censusByYear[year] {
            let split = duplicates[1]
            let keepRecords = cluster.records.filter { $0.id != split.id }
            return (keepRecords, [split], "Same-year census (\(year)) — one person is enumerated once per year")
        }

        // Check for contradicting census ages (implied birth years >5 apart)
        let censusImpliedBirths: [(ScoredRecord, Int)] = cluster.records.compactMap { record in
            if case .census(let r) = record.record, let birthYear = r.birthYear {
                return (record, birthYear)
            }
            if case .census(let r) = record.record, let age = r.age {
                return (record, r.censusYear - age)
            }
            return nil
        }
        if censusImpliedBirths.count >= 2 {
            let sorted = censusImpliedBirths.sorted { $0.1 < $1.1 }
            let earliest = sorted.first!.1
            let latest = sorted.last!.1
            if abs(latest - earliest) > 5 {
                // Split — keep records closer to the earliest birth year
                let midpoint = (earliest + latest) / 2
                let newerRecords = sorted.filter { $0.1 > midpoint }.map { $0.0 }
                let keepRecords = cluster.records.filter { record in
                    !newerRecords.contains { $0.id == record.id }
                }
                return (keepRecords, newerRecords, nil)
            }
        }

        // Multiple marriages with different spouses → different lives.
        // Modulo the rare widowed-and-remarried case (which falls back to
        // user review), three marriages to three different spouses inside
        // one cluster is almost always over-merging because there's no
        // fact-anchored birth to pin the cluster temporally. Without this
        // split rule the David Cauldwell test case grouped his 1969×HOLMES
        // marriage with two unrelated 1975×JOYNES and 1994×HENNESSY records
        // because all three landed in the same surname-only cluster.
        let marriageSpouses: [(ScoredRecord, String)] = cluster.records.compactMap { record in
            guard case .marriage(let m) = record.record else { return nil }
            let spouse = (m.spouseName ?? "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            return spouse.isEmpty ? nil : (record, spouse)
        }
        let distinctSpouses = Set(marriageSpouses.map(\.1))
        if distinctSpouses.count >= 2 {
            // Sort marriages by year. Keep the oldest spouse-group in this
            // cluster, split the next-distinct-spouse record (and any
            // sharing that spouse) out. Subsequent split-loop iterations
            // peel off further distinct spouses.
            let sortedByYear = marriageSpouses.sorted { (a, b) in
                (yearOf(a.0) ?? 0) < (yearOf(b.0) ?? 0)
            }
            let keepSpouse = sortedByYear.first!.1
            let splitOut = sortedByYear.filter { $0.1 != keepSpouse }.map(\.0)
            // Take the first non-keep spouse-group out (peeling, not all at once),
            // so the split loop can iterate further if there are three+ spouses.
            let firstSplitSpouse = sortedByYear.first(where: { $0.1 != keepSpouse })!.1
            let splitRecords = splitOut.filter { record in
                guard case .marriage(let m) = record.record else { return false }
                let s = (m.spouseName ?? "")
                    .trimmingCharacters(in: .whitespaces)
                    .uppercased()
                return s == firstSplitSpouse
            }
            let keepRecords = cluster.records.filter { record in
                !splitRecords.contains { $0.id == record.id }
            }
            return (keepRecords, splitRecords, nil)
        }

        return nil
    }

    // MARK: - Step 4: Merge Candidates

    /// Flag clusters that might be the same person.
    /// Never auto-merge — just flag for user review.
    private static func flagMergeCandidates(_ clusters: inout [LifeCluster]) {
        for i in 0..<clusters.count {
            for j in (i + 1)..<clusters.count {
                if couldBeSamePerson(clusters[i], clusters[j]) {
                    clusters[i].mergeCandidate = clusters[j].id
                    clusters[j].mergeCandidate = clusters[i].id
                }
            }
        }
    }

    /// Two clusters might be the same person if one has a birth and the other has
    /// a death with compatible dates and overlapping location.
    private static func couldBeSamePerson(_ a: LifeCluster, _ b: LifeCluster) -> Bool {
        let aBirth = a.impliedBirthYear
        let bBirth = b.impliedBirthYear
        let aDeath = a.impliedDeathYear
        let bDeath = b.impliedDeathYear

        // One has birth, other has death
        let birthDeathPair: Bool
        if aBirth != nil && bDeath != nil && bBirth == nil {
            birthDeathPair = true
        } else if bBirth != nil && aDeath != nil && aBirth == nil {
            birthDeathPair = true
        } else {
            birthDeathPair = false
        }
        guard birthDeathPair else { return false }

        // Compatible dates — lifespans overlap
        let overlap = a.lifespanStart <= b.lifespanEnd && b.lifespanStart <= a.lifespanEnd
        guard overlap else { return false }

        // Overlapping location
        let sharedDistricts = a.districts.intersection(b.districts)
        return !sharedDistricts.isEmpty
    }

    // MARK: - Helpers

    /// Extract year from a scored record.
    private static func yearOf(_ record: ScoredRecord) -> Int? {
        switch record.record {
        case .birth(let r): return r.birthYear
        case .death(let r): return r.deathYear
        case .marriage(let r): return r.marriageYear
        case .census(let r): return r.censusYear
        case .burial(let r): return r.deathYear ?? r.birthYear
        case .military(let r): return r.deathYear
        case .probate(let r): return r.deathYear
        case .parish(let r): return r.eventYear
        case .pedigree(let r): return r.birthYear
        }
    }

    /// Extract district from a source record.
    private static func extractRecordDistrict(_ record: SourceRecord) -> String? {
        switch record {
        case .birth(let r): return r.district
        case .death(let r): return r.district
        case .marriage(let r): return r.district
        case .census(let r): return r.district
        default: return nil
        }
    }
}
