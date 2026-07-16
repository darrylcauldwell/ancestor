import Foundation

/// Phase 0/1 of the lead-discovery pivot (`AncestorApp/LEAD_DISCOVERY_SPEC.md`).
///
/// Deterministic blocking over the orphan lead pool → candidate emergent
/// clusters ("possible people"). No AI, no hypotheses yet — this is the
/// diagnostic / read-only core: it turns a noisy pool of thousands of
/// unconnected leads into a small set of coherent candidate identities. It is
/// reproducible and auditable by construction. AI (per-lead embeddings,
/// borderline adjudication, cluster narration) is a *later* phase layered on
/// top — never a substitute for this deterministic core (§5, §6 of the spec).
///
/// Precision over recall: a coherent cluster is one where the leads genuinely
/// agree on identity (same surname, compatible given name, compatible birth
/// window, no life-event impossibility). A stray lead that matches nobody stays
/// a singleton and simply isn't surfaced.
nonisolated struct LeadDiscoveryEngine {

    /// A group of leads hypothesised to describe one identity.
    struct EmergentCluster: Identifiable, Sendable {
        let id: String
        var surname: String
        var leads: [Lead]
        /// Consensus birth year when the leads carry one; nil otherwise.
        var birthYear: Int?
        var coherence: Coherence
    }

    /// Precision-first signal for how much a cluster looks like a real person.
    struct Coherence: Equatable, Sendable {
        var size: Int
        var distinctSources: Int
        var distinctEventKinds: Int
        /// Provenance spread — how many origin subjects generated these leads.
        /// Tree-proximity input for later phases (a cluster from one branch is
        /// a likely relative).
        var originProfileCount: Int
        /// Surfaceable in Phase 1 when it's more than a lone stray lead.
        var isSurfaceable: Bool { size >= 2 }
    }

    /// Phase 0 diagnostic summary — "what coheres in the pool?" — the go/no-go.
    struct DiscoveryReport: Sendable {
        let totalLeads: Int
        let placedLeads: Int          // had a usable surname anchor
        let clusterCount: Int
        let surfaceableClusters: Int  // size >= 2 (the ones worth a person's attention)
        let largestClusterSize: Int
        let leadsInSurfaceableClusters: Int
    }

    // MARK: - Entry

    /// Cluster the orphan lead pool into candidate identities, most-coherent first.
    static func discover(leads: [Lead]) -> [EmergentCluster] {
        // Orphans only: skip promoted / dismissed / in-flight leads.
        let pool = leads.filter { $0.status == .new || $0.status == .investigated }

        // Block by (normalised surname, birth-decade). The surname is the
        // anchor; a lead with no derivable surname can't be placed and is
        // dropped (it can't be entity-resolved on nothing).
        var blocks: [BlockKey: [Lead]] = [:]
        for lead in pool {
            let surname = normaliseSurname(lead.surname ?? Self.surname(fromName: lead.name))
            guard !surname.isEmpty else { continue }
            let decade = lead.birthYear.map { ($0 / 10) * 10 }
            blocks[BlockKey(surname: surname, decade: decade), default: []].append(lead)
        }

        var clusters: [EmergentCluster] = []
        for (key, blockLeads) in blocks.sorted(by: { $0.key < $1.key }) {
            clusters.append(contentsOf: clusterBlock(blockLeads, surname: key.surname))
        }
        // Most-coherent first; stable tiebreak by id for reproducibility.
        return clusters.sorted {
            $0.coherence.size != $1.coherence.size
                ? $0.coherence.size > $1.coherence.size
                : $0.id < $1.id
        }
    }

    /// Phase 0 report over a lead pool.
    static func report(leads: [Lead]) -> DiscoveryReport {
        let clusters = discover(leads: leads)
        let placed = clusters.reduce(0) { $0 + $1.leads.count }
        let surfaceable = clusters.filter { $0.coherence.isSurfaceable }
        return DiscoveryReport(
            totalLeads: leads.count,
            placedLeads: placed,
            clusterCount: clusters.count,
            surfaceableClusters: surfaceable.count,
            largestClusterSize: clusters.map { $0.leads.count }.max() ?? 0,
            leadsInSurfaceableClusters: surfaceable.reduce(0) { $0 + $1.leads.count }
        )
    }

    // MARK: - Within-block clustering

    /// Agglomerative merge inside one (surname, decade) block: start each lead
    /// as its own group and merge two groups only when EVERY cross-pair is
    /// compatible (conservative — precision over recall). Deterministic order.
    private static func clusterBlock(_ leads: [Lead], surname: String) -> [EmergentCluster] {
        let sorted = leads.sorted { $0.id < $1.id }
        var groups: [[Lead]] = sorted.map { [$0] }
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<groups.count {
                for j in (i + 1)..<groups.count where groupsCompatible(groups[i], groups[j]) {
                    groups[i].append(contentsOf: groups[j])
                    groups.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return groups.enumerated().map { idx, g in
            makeCluster(id: "\(surname)-\(idx)", surname: surname, leads: g)
        }
    }

    private static func groupsCompatible(_ a: [Lead], _ b: [Lead]) -> Bool {
        for x in a { for y in b where !leadsCompatible(x, y) { return false } }
        return true
    }

    /// Two leads could be the same person when their given names aren't
    /// contradictory, their birth years are close, and no life-event
    /// impossibility (born after death) is implied.
    static func leadsCompatible(_ a: Lead, _ b: Lead) -> Bool {
        // Given name: a real disagreement (both present, zero similarity) rules
        // it out; a missing given name is permissive.
        if let ga = nonEmpty(a.givenName), let gb = nonEmpty(b.givenName),
           ScoringRules.nameSimilarity(ga.uppercased(), gb.uppercased()) == 0 {
            return false
        }
        // Birth year within ±5 when both present.
        if let ba = a.birthYear, let bb = b.birthYear, abs(ba - bb) > 5 {
            return false
        }
        // A death ends a life: a birth after the other's death is impossible.
        if let d = a.deathYear, let born = b.birthYear, born > d + 1 { return false }
        if let d = b.deathYear, let born = a.birthYear, born > d + 1 { return false }
        return true
    }

    private static func makeCluster(id: String, surname: String, leads: [Lead]) -> EmergentCluster {
        let births = leads.compactMap { $0.birthYear }.sorted()
        let consensusBirth = births.isEmpty ? nil : births[births.count / 2] // median
        let coherence = Coherence(
            size: leads.count,
            distinctSources: Set(leads.map { $0.source }).count,
            distinctEventKinds: Set(leads.map { eventKind(of: $0) }).count,
            originProfileCount: Set(leads.map { $0.profileID }).count
        )
        return EmergentCluster(id: id, surname: surname, leads: leads,
                               birthYear: consensusBirth, coherence: coherence)
    }

    // MARK: - Helpers

    private struct BlockKey: Hashable, Comparable {
        let surname: String
        let decade: Int?
        static func < (l: BlockKey, r: BlockKey) -> Bool {
            l.surname != r.surname ? l.surname < r.surname
                : (l.decade ?? Int.min) < (r.decade ?? Int.min)
        }
    }

    static func normaliseSurname(_ s: String?) -> String {
        (s ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.,'"))
            .uppercased()
    }

    /// Derive a surname from a full name when the structured field is missing.
    static func surname(fromName name: String) -> String {
        name.split(separator: " ").last.map(String.init) ?? ""
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: CharacterSet(charactersIn: " ?")),
              !s.isEmpty else { return nil }
        return s
    }

    /// A coarse event-kind bucket derived from the lead's evidence/relationship,
    /// for the diversity signal (birth vs death vs marriage vs census).
    private static func eventKind(of lead: Lead) -> String {
        let hay = (lead.evidence + " " + (lead.relationship ?? "")).lowercased()
        if hay.contains("marriage") || hay.contains("spouse") { return "marriage" }
        if hay.contains("death") || hay.contains("probate") || hay.contains("burial") { return "death" }
        if hay.contains("census") { return "census" }
        if hay.contains("birth") || hay.contains("christen") || hay.contains("baptis") { return "birth" }
        return "other"
    }
}
