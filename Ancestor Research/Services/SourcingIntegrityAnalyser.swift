import Foundation

/// Sourcing integrity report — answers "is each fact backed by a credible source?"
/// The audit's twin: instead of internal consistency, it checks evidence backing.
///
/// A fact (populated profile field) falls into one of four buckets:
///   - clean         — at least one non-manual source (e.g. FreeBMD, GEDCOM, WikiTree)
///   - manualOnly    — every source is one of the manual.* origins (incl. estimate)
///   - estimateOnly  — every source has origin == .manualEstimate (strict subset of manualOnly)
///   - unsourced     — profile.sources[field] is nil or empty
///
/// Empty/nil field values are skipped — there's nothing to source if there's no value.
nonisolated enum SourcingIntegrityAnalyser {
    static func analyse(snapshot: FamilyGraphSnapshot) -> SourcingIntegrityReport {
        var totalFields = 0
        var unsourced: [SourcingIssue] = []
        var estimateOnly: [SourcingIssue] = []
        var manualOnly: [SourcingIssue] = []

        // Sort profiles by id so the report is deterministic across runs.
        let profiles = snapshot.profiles.values.sorted { $0.id < $1.id }

        for profile in profiles {
            for field in ProfileField.allCases {
                guard let value = displayValue(for: field, profile: profile) else { continue }
                totalFields += 1

                let sources = profile.sources[field] ?? []
                if sources.isEmpty {
                    unsourced.append(makeIssue(profile: profile, field: field, value: value))
                    continue
                }

                let allEstimate = sources.allSatisfy { $0.origin == .manualEstimate }
                let allManual = sources.allSatisfy { $0.origin.isManual }

                if allEstimate {
                    estimateOnly.append(makeIssue(profile: profile, field: field, value: value))
                }
                if allManual {
                    manualOnly.append(makeIssue(profile: profile, field: field, value: value))
                }
            }
        }

        return SourcingIntegrityReport(
            totalFields: totalFields,
            unsourced: unsourced,
            estimateOnly: estimateOnly,
            manualOnly: manualOnly
        )
    }

    /// Returns the formatted display string for a populated field, or nil if the
    /// field is empty/nil (and therefore not a sourcing problem — nothing to cite).
    private static func displayValue(for field: ProfileField, profile: Profile) -> String? {
        switch field {
        case .firstName: return nonEmpty(profile.firstName)
        case .middleName: return nonEmpty(profile.middleName)
        case .lastName: return nonEmpty(profile.lastName)
        case .nickName: return nonEmpty(profile.nickName)
        case .mothersMaidenName: return nonEmpty(profile.mothersMaidenName)
        case .gender:
            guard let g = profile.gender, g != .unknown else { return nil }
            return g.rawValue.capitalized
        case .birthDate: return profile.birthDate?.original
        case .birthLocation: return nonEmpty(profile.birthLocation)
        case .deathDate: return profile.deathDate?.original
        case .deathLocation: return nonEmpty(profile.deathLocation)
        case .bio: return nonEmpty(profile.bio)
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func makeIssue(
        profile: Profile,
        field: ProfileField,
        value: String
    ) -> SourcingIssue {
        SourcingIssue(
            id: "\(profile.id):\(field.rawValue)",
            profileID: profile.id,
            profileName: profile.displayName.isEmpty ? profile.id : profile.displayName,
            field: field,
            displayValue: value
        )
    }
}

nonisolated struct SourcingIntegrityReport: Sendable {
    let totalFields: Int
    let unsourced: [SourcingIssue]
    let estimateOnly: [SourcingIssue]
    let manualOnly: [SourcingIssue]
}

/// Named `SourcingIssue` (not just `Issue`) to avoid colliding with other "Issue"
/// types that may exist elsewhere in the project (audit, leads, etc.).
nonisolated struct SourcingIssue: Sendable, Hashable, Identifiable {
    let id: String
    let profileID: String
    let profileName: String
    let field: ProfileField
    let displayValue: String
}
