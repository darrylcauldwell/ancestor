import Foundation
import AncestorKit

// WikiTree MergeEdit payload builder (WT1 — WIKITREE_MERGEEDIT_SPEC §3/§4).
//
// Pure projection from an evidence-backed local profile onto the documented
// Special:MergeEdit JSON-path fields. All contribution policy lives here so
// the launcher (WT2) is dumb plumbing:
//  - eligibility: has a wikitree ID, deceased, at least one sendable change;
//  - a field is sendable only when the app's value DIFFERS from WikiTree's
//    last-known value (the `.wikitree`-origin FieldSource stamped at import)
//    AND carries research/user provenance — estimates never overwrite
//    WikiTree data, in either direction;
//  - `expected` carries the twin value for every sent field (WikiTree skips
//    the update when the live profile no longer matches — their own
//    check-before-overwrite);
//  - the Bio append block is generated here; the launcher MUST pair it with
//    `options.mergeBio = 1` (without it MergeEdit overwrites the whole
//    biography — spec invariant).

nonisolated struct WikiTreeMergeEditPayload: Sendable, Equatable {
    /// WikiTree ID in `Name-1234` form (the `user_name` identifier).
    let userName: String
    /// MergeEdit field → new value (the `person` object).
    let personFields: [String: String]
    /// MergeEdit field → the twin's last-known value (the `expected` object).
    /// Empty string when the twin held nothing — a populated live value then
    /// correctly skips on WikiTree's side.
    let expectedFields: [String: String]
    /// Rendered §4 research-notes block, or nil when there is nothing to cite.
    let bioAppend: String?
    /// Change-summary text (honest provenance in WikiTree's change log).
    let summary: String
    /// Corrections MergeEdit cannot carry (e.g. maiden surname —
    /// LastNameAtBirth is not an accepted field). Surfaced in the UI, never
    /// silently dropped.
    let manualNotes: [String]
}

nonisolated enum WikiTreeMergeEdit {

    /// (app profile field, MergeEdit field, current app value)
    private static func mappedFields(_ profile: Profile) -> [(ProfileField, String, String?)] {
        [
            (.firstName, "FirstName", profile.firstName),
            (.middleName, "MiddleName", profile.middleName),
            (.marriedSurname, "LastNameCurrent", profile.marriedSurname),
            (.nickName, "Nicknames", profile.nickName),
            (.birthDate, "BirthDate", profile.birthDate?.original),
            (.birthLocation, "BirthLocation", profile.birthLocation),
            (.deathDate, "DeathDate", profile.deathDate?.original),
            (.deathLocation, "DeathLocation", profile.deathLocation),
            (.gender, "Gender", wikiTreeGender(profile.gender)),
        ]
    }

    /// Build the contribution payload, or nil when the profile is ineligible
    /// or has nothing sendable. `date` is injected (determinism/testability)
    /// and appears in the research-notes header.
    static func build(
        profile: Profile,
        lifeEvents: [LifeEvent] = [],
        currentYear: Int,
        date: String
    ) -> WikiTreeMergeEditPayload? {
        guard let wikiTreeID = profile.wikiTreeID, !wikiTreeID.isEmpty else { return nil }
        // Living people never leave the app — same test as the FS write leg.
        guard !FamilySearchTreeEncoder.isLiving(profile, currentYear: currentYear) else { return nil }

        var person: [String: String] = [:]
        var expected: [String: String] = [:]
        var manualNotes: [String] = []

        for (field, mergeEditField, appValue) in mappedFields(profile) {
            guard let appValue = appValue?.trimmingCharacters(in: .whitespaces), !appValue.isEmpty else { continue }
            let twinValue = latestWikiTreeRaw(profile, field: field) ?? ""
            guard appValue != twinValue else { continue }
            guard hasContributableProvenance(profile, field: field) else { continue }
            person[mergeEditField] = appValue
            expected[mergeEditField] = twinValue
        }

        // Maiden surname is deliberately NOT sendable (LastNameAtBirth is
        // absent from MergeEdit's accepted fields) — surface the divergence
        // instead of dropping it.
        if let maiden = profile.lastName?.trimmingCharacters(in: .whitespaces), !maiden.isEmpty {
            let twinMaiden = latestWikiTreeRaw(profile, field: .lastName) ?? ""
            if !twinMaiden.isEmpty, maiden != twinMaiden, hasContributableProvenance(profile, field: .lastName) {
                manualNotes.append(
                    "Maiden surname differs (app “\(maiden)”, WikiTree “\(twinMaiden)”) — MergeEdit cannot edit Last Name at Birth; change it manually on WikiTree.")
            }
        }

        let bioAppend = researchNotesBlock(
            profile: profile, lifeEvents: lifeEvents, sentFields: person, date: date)

        guard !person.isEmpty || bioAppend != nil else { return nil }

        let fieldList = person.keys.sorted().joined(separator: ", ")
        let summary = person.isEmpty
            ? "Sourced citations from Ancestor Research."
            : "Sourced update from Ancestor Research: \(fieldList)."

        return WikiTreeMergeEditPayload(
            userName: wikiTreeID,
            personFields: person,
            expectedFields: expected,
            bioAppend: bioAppend,
            summary: summary,
            manualNotes: manualNotes)
    }

    // MARK: - §4 research-notes block

    /// The appended bio block: per-field fact lines with their first citation
    /// as a `<ref>`, then remaining distinct citations as bullets. Citations
    /// already visible in the profile's bio text are skipped (conservative
    /// substring test on URL and page locator — when unsure, include; the
    /// review page lets Darryl delete).
    static func researchNotesBlock(
        profile: Profile,
        lifeEvents: [LifeEvent],
        sentFields: [String: String],
        date: String
    ) -> String? {
        let existingBio = profile.bio ?? ""
        func alreadyCited(_ citation: Citation) -> Bool {
            if let url = citation.url, !url.isEmpty, existingBio.contains(url) { return true }
            if let page = citation.page, !page.isEmpty, existingBio.contains(page) { return true }
            return false
        }

        var lines: [String] = []
        var usedKeys = Set<String>()

        // Per-field lines for the fields this contribution sends.
        let fieldLabels: [(ProfileField, String, String)] = [
            (.birthDate, "BirthDate", "Birth"),
            (.birthLocation, "BirthLocation", "Birth place"),
            (.deathDate, "DeathDate", "Death"),
            (.deathLocation, "DeathLocation", "Death place"),
        ]
        for (field, mergeEditField, label) in fieldLabels {
            guard let value = sentFields[mergeEditField] else { continue }
            guard let citation = firstResearchCitation(profile, field: field), !alreadyCited(citation) else { continue }
            lines.append("* \(label): \(value)<ref>\(citation.formatted)</ref>")
            usedKeys.insert(citationKey(citation))
        }

        // Remaining distinct research citations (profile fields + life events).
        var citations = profile.sources.values.flatMap { $0 }
            .filter { $0.origin.tier != .initialImport }
            .compactMap(\.citation)
        citations += lifeEvents.filter { !$0.sensitive }
            .flatMap(\.sources)
            .filter { $0.origin.tier != .initialImport }
            .compactMap(\.citation)
        for citation in citations where !citation.isEmpty {
            let key = citationKey(citation)
            guard !usedKeys.contains(key), !alreadyCited(citation) else { continue }
            usedKeys.insert(key)
            lines.append("* \(citation.formatted)")
        }

        guard !lines.isEmpty else { return nil }
        return "=== Research notes (\(date), Ancestor Research) ===\n" + lines.joined(separator: "\n")
    }

    // MARK: - Leaf helpers

    /// The twin's last-known WikiTree value: the most recent `.wikitree`-origin
    /// FieldSource raw for the field (stamped by the importer).
    static func latestWikiTreeRaw(_ profile: Profile, field: ProfileField) -> String? {
        profile.sources[field]?
            .filter { $0.origin == .wikitree }
            .max(by: { $0.addedAt < $1.addedAt })?
            .raw
    }

    /// Check-before-overwrite gate: only research-grade or user-authoritative
    /// values contribute; import-tier values never round-trip back.
    static func hasContributableProvenance(_ profile: Profile, field: ProfileField) -> Bool {
        profile.sources[field]?.contains { $0.origin.tier != .initialImport } ?? false
    }

    private static func firstResearchCitation(_ profile: Profile, field: ProfileField) -> Citation? {
        profile.sources[field]?
            .filter { $0.origin.tier != .initialImport }
            .compactMap(\.citation)
            .first { !$0.isEmpty }
    }

    private static func wikiTreeGender(_ gender: Gender?) -> String? {
        switch gender {
        case .male: "Male"
        case .female: "Female"
        default: nil   // MergeEdit accepts Male/Female; anything else stays local
        }
    }

    /// Run-stable dedup key (FNV-1a — same reasoning as the FS encoder:
    /// `Hasher` is process-seeded and would break cross-run stability).
    static func citationKey(_ citation: Citation) -> String {
        let fields = [citation.repository, citation.collection, citation.title,
                      citation.page, citation.url, citation.notes]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in fields.map({ $0 ?? "" }).joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}
