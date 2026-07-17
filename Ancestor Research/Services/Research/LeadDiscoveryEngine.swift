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

        /// The single lead that best stands in for the cluster when the user
        /// asks to research it as one person — the one with a birth signal and
        /// the fullest name (e.g. "George Edwin Ward" over a bare "G Ward").
        /// Never nil: a cluster always has at least one lead.
        var representativeLead: Lead {
            leads
                .max { a, b in
                    let ka = (a.effectiveBirthYear != nil ? 1 : 0, a.name.count)
                    let kb = (b.effectiveBirthYear != nil ? 1 : 0, b.name.count)
                    return ka < kb
                } ?? leads[0]
        }
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
            // Block on the EFFECTIVE birth year (own, or implied from
            // age-at-death) so no-birth-year death leads carrying an age split
            // into their real decade instead of all landing in one (surname,
            // nil) block and chain-merging on name alone — the Phase 0
            // over-merge (LEAD_DISCOVERY_SPEC §9).
            let decade = lead.effectiveBirthYear.map { ($0 / 10) * 10 }
            blocks[BlockKey(surname: surname, decade: decade), default: []].append(lead)
        }

        var clusters: [EmergentCluster] = []
        for (key, blockLeads) in blocks.sorted(by: { $0.key < $1.key }) {
            clusters.append(contentsOf: clusterBlock(blockLeads, surname: key.surname, decade: key.decade))
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
    private static func clusterBlock(_ leads: [Lead], surname: String, decade: Int?) -> [EmergentCluster] {
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
            // The id must be unique across the WHOLE pool, not just this
            // block: the same surname appears in many decade blocks, and
            // "WARD-0" from each of them collided — SwiftUI renders duplicate
            // ForEach ids as blank ghost rows (owner report 2026-07-17,
            // Possible People gaps). The block's decade disambiguates.
            makeCluster(
                id: "\(surname)-\(decade.map(String.init) ?? "nodecade")-\(idx)",
                surname: surname, leads: g
            )
        }
    }

    private static func groupsCompatible(_ a: [Lead], _ b: [Lead]) -> Bool {
        for x in a { for y in b where !leadsCompatible(x, y) { return false } }
        return true
    }

    /// Two leads could be the same person when the SHARED identity core
    /// (`IdentityConstraints`, spec §7 — one rule set for both clustering
    /// roles since Phase 5) finds no contradiction between them.
    static func leadsCompatible(_ a: Lead, _ b: Lead) -> Bool {
        if IdentityConstraints.givenNamesContradict(a.givenName, b.givenName) {
            return false
        }
        let ea = a.effectiveBirthYear
        let eb = b.effectiveBirthYear
        // Birth years (own or age-implied) must agree within tolerance.
        if IdentityConstraints.birthYearsContradict(ea, eb) { return false }
        // A death ends a life: a birth after the other's death is impossible.
        if IdentityConstraints.bornAfterDeath(birth: eb, death: a.deathYear) { return false }
        if IdentityConstraints.bornAfterDeath(birth: ea, death: b.deathYear) { return false }
        // A person dies once — splits the yearless death-cluster tail (same-
        // name burials in different years that name+place alone chain-merged).
        if IdentityConstraints.distinctDeaths(a.deathYear, b.deathYear) { return false }
        // No birth signal on EITHER side is the dangerous case: name alone
        // chain-merged hundreds of namesakes in Phase 0 (George Ward = 273
        // different men across different cemeteries). Require an agreeing
        // place as the second discriminator — no place, or disagreeing
        // places, and they stay separate. Precision-first ("when in doubt,
        // split"). LEAD_DISCOVERY_SPEC §9.
        if ea == nil && eb == nil {
            guard let pa = normalisePlace(a.place), let pb = normalisePlace(b.place),
                  placesCompatible(pa, pb) else { return false }
        }
        return true
    }

    private static func makeCluster(id: String, surname: String, leads: [Lead]) -> EmergentCluster {
        let births = leads.compactMap { $0.effectiveBirthYear }.sorted()
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

    static func normalisePlace(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: CharacterSet(charactersIn: " ?.,'")).uppercased(),
              !s.isEmpty else { return nil }
        return s
    }

    /// Generic place words that carry no locality signal — two different
    /// people can both be buried in "a cemetery" or "a churchyard", so these
    /// must never be the token two leads agree on.
    private static let placeStopwords: Set<String> = [
        "CEMETERY", "CHURCHYARD", "CHURCH", "CREMATORIUM", "MEMORIAL",
        "BURIAL", "GROUND", "GARDEN", "GARDENS", "PARK", "THE", "AND",
        "ALL", "SAINT", "OLD", "NEW", "MUNICIPAL", "GENERAL", "DISTRICT",
        "ROAD", "STREET", "LANE", "HOUSE", "FARM",
    ]

    /// The locality-bearing tokens of a place string — letters only, ≥3 chars,
    /// stopwords dropped. "WOLLATON CEMETERY" → [WOLLATON];
    /// "ST MARY MAGDALENE CHURCHYARD" → [MARY, MAGDALENE].
    private static func significantTokens(_ s: String) -> Set<String> {
        Set(
            s.split(whereSeparator: { !$0.isLetter })
                .map { String($0).uppercased() }
                .filter { $0.count >= 3 && !placeStopwords.contains($0) }
        )
    }

    /// Two normalised places agree when they're identical or share a
    /// locality token. Precision-first: no shared token ⇒ different place ⇒
    /// don't merge. If one place has no locality token at all (e.g. bare
    /// "Cemetery"), it can't agree with anything and the leads stay split.
    static func placesCompatible(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ta = significantTokens(a)
        let tb = significantTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        return !ta.isDisjoint(with: tb)
    }

    // MARK: - Phase 3: fuzzy-bridge across surname spelling variants

    /// Merge cluster pairs the EXACT-surname block key kept apart because their
    /// surnames are spelling variants ("CAULDWELL"/"COLDWELL") — the fuzzy
    /// matches deterministic keys miss (LEAD_DISCOVERY_SPEC Phase 3). This runs
    /// AFTER `discover`, over the already-formed clusters, and is precision-
    /// first: two clusters bridge only when their surnames are close variants,
    /// their representatives pass every hard constraint (given name, birth
    /// window, born-after-death, a-person-dies-once), their birth years agree
    /// within ±2, AND their text embeddings are similar enough. The embedder
    /// (semantic MLX vectors, or the deterministic trigram fallback) only
    /// proposes; these deterministic gates decide.
    static func bridgeVariantSurnames(
        _ clusters: [EmergentCluster],
        vectorFor: (EmergentCluster) -> [Float],
        threshold: Double
    ) -> [EmergentCluster] {
        var groups = clusters
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<groups.count {
                for j in (i + 1)..<groups.count
                where clustersBridgeable(groups[i], groups[j], vectorFor: vectorFor, threshold: threshold) {
                    groups[i] = makeCluster(
                        id: groups[i].id, surname: groups[i].surname,
                        leads: groups[i].leads + groups[j].leads
                    )
                    groups.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return groups.sorted {
            $0.coherence.size != $1.coherence.size
                ? $0.coherence.size > $1.coherence.size
                : $0.id < $1.id
        }
    }

    static func clustersBridgeable(
        _ a: EmergentCluster,
        _ b: EmergentCluster,
        vectorFor: (EmergentCluster) -> [Float],
        threshold: Double
    ) -> Bool {
        // Only bridge ACROSS a surname spelling variant — same-surname clusters
        // already had their chance to merge inside discover().
        guard surnamesAreVariants(a.surname, b.surname) else { return false }
        // Require a birth signal on both and tight agreement (tighter than the
        // within-block window — bridging across surnames earns less slack).
        guard let ya = a.birthYear, let yb = b.birthYear,
              !IdentityConstraints.birthYearsContradict(
                ya, yb, tolerance: IdentityConstraints.bridgeBirthYearTolerance)
        else { return false }
        // Every other hard constraint (given name, born-after-death, dies-once)
        // must hold between the representatives — reuse the one rule set.
        guard leadsCompatible(a.representativeLead, b.representativeLead) else { return false }
        // Finally the fuzzy signal: text embeddings must be similar.
        return VectorMath.cosine(vectorFor(a), vectorFor(b)) >= threshold
    }

    /// Two surnames are spelling variants: not identical, same first letter,
    /// lengths within 2, and edit distance ≤ 2. Deterministic and cheap; the
    /// embedding threshold is the semantic backstop for false positives.
    static func surnamesAreVariants(_ a: String, _ b: String) -> Bool {
        let x = normaliseSurname(a), y = normaliseSurname(b)
        guard !x.isEmpty, !y.isEmpty, x != y else { return false }
        guard x.first == y.first, abs(x.count - y.count) <= 2 else { return false }
        return levenshtein(Array(x), Array(y)) <= 2
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
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
