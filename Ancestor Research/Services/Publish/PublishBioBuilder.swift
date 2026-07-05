import Foundation

// PUBLISHER_SPEC Change 6 — publish-time biography synthesis.
//
// Deterministic prose from COMMITTED facts only: profile vitals, stored
// life_events rows, and relationship edges — never research results,
// never a model. The sentence engine is the shared
// `NarrativeAssembler.templateNarrative` (retained in Phase 0 for exactly
// this); this builder is the LifeEvent→NarrativeLifeEvent adapter plus
// the §Change 6 relative-redaction rules:
//   * a relative resolving to `nameOnly` appears by displayName only —
//     no dates or places attach to them (the marriage year is a fact
//     about both parties, so it is stripped when the spouse is redacted);
//   * a relative resolving to `omit` does not appear at all;
//   * sensitive life events never contribute to prose.
nonisolated enum PublishBioBuilder {

    /// Neutral citation for adapter-built events — the template only
    /// reads year/location/description from these. Fixed epoch date keeps
    /// bundle exports byte-identical (never `Date()` in the pure layer).
    private static let committedFactCitation = RenderedCitation(
        full: "", short: "", url: nil,
        accessedAt: Date(timeIntervalSince1970: 0), sourceID: "committed")

    static func bio(
        for profile: Profile,
        lifeEvents: [LifeEvent],
        snapshot: FamilyGraphSnapshot,
        resolved: [String: ResolvedPublishPolicy]
    ) -> String {
        var events: [NarrativeLifeEvent] = []

        // Vitals — the canonical profile fields are the committed truth.
        if let birthYear = profile.birthDate?.bestYear {
            events.append(NarrativeLifeEvent(
                type: .birth, year: birthYear, location: profile.birthLocation,
                description: "", sourceID: "committed", citation: committedFactCitation))
        }
        if let deathYear = profile.deathDate?.bestYear {
            events.append(NarrativeLifeEvent(
                type: .death, year: deathYear, location: profile.deathLocation,
                description: "", sourceID: "committed", citation: committedFactCitation))
        }

        // Marriages — spouse edges, redaction-aware. Deterministic order.
        let spouseEdges = snapshot.relationships
            .filter { $0.type == .spouse && ($0.from == profile.id || $0.to == profile.id) }
            .sorted { ($0.marriageDate?.bestYear ?? .max, $0.id.uuidString)
                    < ($1.marriageDate?.bestYear ?? .max, $1.id.uuidString) }
        for edge in spouseEdges {
            let partnerID = edge.from == profile.id ? edge.to : edge.from
            guard let partnerPolicy = resolved[partnerID], partnerPolicy != .omit,
                  let partner = snapshot.profiles[partnerID] else { continue }
            let redacted = partnerPolicy == .nameOnly
            events.append(NarrativeLifeEvent(
                type: .marriage,
                year: redacted ? nil : edge.marriageDate?.bestYear,
                location: redacted ? nil : edge.marriageLocation,
                description: partner.displayName,
                sourceID: "committed", citation: committedFactCitation))
        }

        // Census appearances — committed life_events rows, never sensitive.
        for event in lifeEvents
        where event.profileID == profile.id && event.type == .census && !event.sensitive {
            events.append(NarrativeLifeEvent(
                type: .census, year: event.date?.bestYear, location: event.location,
                description: "", sourceID: "committed", citation: committedFactCitation))
        }

        var bio = NarrativeAssembler.templateNarrative(profile: profile, events: events)

        // Children sentence — composed here rather than in the shared
        // template so the research-path prose is untouched. Full children
        // carry a birth year; nameOnly children are a bare name; omitted
        // children are absent. Ordered by birth year then name.
        let childSentence = childrenSentence(for: profile, snapshot: snapshot, resolved: resolved)
        if let childSentence {
            bio += " " + childSentence
        }
        return bio
    }

    private static func childrenSentence(
        for profile: Profile,
        snapshot: FamilyGraphSnapshot,
        resolved: [String: ResolvedPublishPolicy]
    ) -> String? {
        var entries: [(sortYear: Int, name: String, label: String)] = []
        for edge in snapshot.relationships
        where edge.type == .parent && edge.from == profile.id {
            guard let policy = resolved[edge.to], policy != .omit,
                  let child = snapshot.profiles[edge.to] else { continue }
            let birthYear = policy == .full ? child.birthDate?.bestYear : nil
            let label = birthYear.map { "\(child.displayName) (b. \($0))" } ?? child.displayName
            entries.append((birthYear ?? .max, child.displayName, label))
        }
        guard !entries.isEmpty else { return nil }
        entries.sort { ($0.sortYear, $0.name) < ($1.sortYear, $1.name) }
        let names = entries.map(\.label)
        let list: String
        if names.count == 1 {
            list = names[0]
        } else {
            list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let firstName = profile.firstName ?? profile.displayName
        return "\(firstName)'s children: \(list)."
    }
}
