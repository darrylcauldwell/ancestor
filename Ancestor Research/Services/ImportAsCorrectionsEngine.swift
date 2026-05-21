import Foundation

/// Pure helper that turns a GEDCOM import into a set of additions plus
/// workbench hypotheses (the "Import corrections as suggestions" path —
/// DESIGN.md §13). Profiles only present in the import become direct
/// additions; profiles that overlap with the existing tree generate
/// `.fieldValue` hypotheses for any differing fields rather than
/// auto-overwriting.
///
/// Removed profiles in the imported file (i.e. existing profile not
/// present in the import) are deliberately ignored — we don't auto
/// soft-delete on import. A relative might just not have everyone the
/// user has, and silently deleting their tree on every import would be
/// catastrophic. If the user wants to remove a profile they can do so
/// explicitly.
nonisolated enum ImportAsCorrectionsEngine {

    nonisolated struct ImportResult: Sendable {
        let newProfiles: [Profile]              // Added directly (no overlap with existing)
        let hypotheses: [Hypothesis]            // Diff-driven — fieldValue claims for overlapping profiles
        let unchangedCount: Int                 // Profiles whose every field already matches
    }

    /// Compute corrections-as-suggestions diff for an imported GEDCOM
    /// against the existing snapshot.
    ///
    /// - Parameters:
    ///   - importedSnapshot: Snapshot produced by `GEDCOMParser`.
    ///   - existingSnapshot: The current tree.
    ///   - sourceLabel: Filename or origin description, used in the
    ///     `reasoning` text on each generated hypothesis.
    ///   - now: Override for `Date()` — tests pass a fixed date so the
    ///     reasoning string is deterministic.
    static func diff(
        importedSnapshot: FamilyGraphSnapshot,
        existingSnapshot: FamilyGraphSnapshot,
        sourceLabel: String,
        now: Date = Date()
    ) -> ImportResult {
        var newProfiles: [Profile] = []
        var hypotheses: [Hypothesis] = []
        var unchanged = 0

        // Walk imported profiles; everything else is fall-through.
        for (_, imported) in importedSnapshot.profiles {
            if let match = bestMatch(for: imported, in: existingSnapshot) {
                // Overlap: emit per-field hypotheses for differences.
                let perField = fieldDiffHypotheses(
                    imported: imported,
                    existing: match,
                    sourceLabel: sourceLabel,
                    now: now
                )
                if perField.isEmpty {
                    unchanged += 1
                } else {
                    hypotheses.append(contentsOf: perField)
                }
            } else {
                newProfiles.append(imported)
            }
        }

        return ImportResult(
            newProfiles: newProfiles,
            hypotheses: hypotheses,
            unchangedCount: unchanged
        )
    }

    // MARK: - Matching

    /// Find an existing profile that "is the same person" as `imported`.
    /// Strategy:
    ///   1. Exact match on any shared external ID (wikitree, familysearch,
    ///      etc.) — strongest signal.
    ///   2. Fall back to lowercase first+last name plus birth-year overlap
    ///      within ±2 years.
    private static func bestMatch(
        for imported: Profile,
        in existing: FamilyGraphSnapshot
    ) -> Profile? {
        // 1. External-ID match.
        if !imported.externalIDs.isEmpty {
            for candidate in existing.profiles.values {
                for (key, value) in imported.externalIDs {
                    if let theirs = candidate.externalIDs[key], theirs == value, !value.isEmpty {
                        return candidate
                    }
                }
            }
        }

        // 2. Name + birth-year heuristic. Both names required so we don't
        // false-match every John in a tree.
        let importedFirst = imported.firstName?.lowercased()
        let importedLast = imported.lastName?.lowercased()
        guard let f = importedFirst, !f.isEmpty,
              let l = importedLast, !l.isEmpty else {
            return nil
        }
        let importedYear = imported.birthDate?.bestYear

        for candidate in existing.profiles.values {
            guard candidate.firstName?.lowercased() == f,
                  candidate.lastName?.lowercased() == l else { continue }
            // If both have a birth year, require ±2 overlap. If either is
            // missing, accept on the name match alone — typical for early
            // profiles where dates haven't been recorded yet.
            if let iy = importedYear, let cy = candidate.birthDate?.bestYear {
                if abs(iy - cy) <= 2 { return candidate }
            } else {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Field-level diff → hypotheses

    /// Walk every `ProfileField` and emit one `.speculation` hypothesis
    /// per differing field. Two flavours:
    ///  * existing has nil, imported has a value → "fill in" suggestion.
    ///  * existing differs → "correction" suggestion with the existing
    ///    value recorded in `contradictingEvidence`.
    private static func fieldDiffHypotheses(
        imported: Profile,
        existing: Profile,
        sourceLabel: String,
        now: Date
    ) -> [Hypothesis] {
        var out: [Hypothesis] = []

        for field in ProfileField.allCases {
            let importedValue = stringValue(of: field, in: imported)
            let existingValue = stringValue(of: field, in: existing)

            // No value in the import → nothing to suggest.
            guard let iv = importedValue, !iv.isEmpty else { continue }

            if let ev = existingValue, !ev.isEmpty {
                // Both populated — only emit if they actually differ.
                if iv == ev { continue }
                out.append(Hypothesis(
                    id: UUID(),
                    claim: .fieldValue(profileID: existing.id, field: field, value: iv),
                    confidence: .speculation,
                    reasoning: "Imported from \(sourceLabel) \u{2014} differs from existing value.",
                    supportingEvidence: ["Imported value: \(iv)"],
                    contradictingEvidence: ["Existing value: \(ev)"],
                    status: .active,
                    createdAt: now,
                    resolvedAt: nil,
                    dismissalReason: nil
                ))
            } else {
                // Existing is nil/empty — pure fill-in suggestion.
                out.append(Hypothesis(
                    id: UUID(),
                    claim: .fieldValue(profileID: existing.id, field: field, value: iv),
                    confidence: .speculation,
                    reasoning: "Imported from \(sourceLabel) \u{2014} existing tree has no value.",
                    supportingEvidence: ["Imported value: \(iv)"],
                    contradictingEvidence: [],
                    status: .active,
                    createdAt: now,
                    resolvedAt: nil,
                    dismissalReason: nil
                ))
            }
        }

        return out
    }

    /// Map a `ProfileField` to its string representation on a `Profile`.
    /// Dates compare on the raw `original` string — matches the existing
    /// `DiffEngine` contract.
    private static func stringValue(of field: ProfileField, in profile: Profile) -> String? {
        switch field {
        case .firstName: return profile.firstName
        case .middleName: return profile.middleName
        case .lastName: return profile.lastName
        case .marriedSurname: return profile.marriedSurname
        case .nickName: return profile.nickName
        case .mothersMaidenName: return profile.mothersMaidenName
        case .gender: return profile.gender?.rawValue
        case .birthDate: return profile.birthDate?.original
        case .birthLocation: return profile.birthLocation
        case .deathDate: return profile.deathDate?.original
        case .deathLocation: return profile.deathLocation
        case .bio: return profile.bio
        }
    }
}
