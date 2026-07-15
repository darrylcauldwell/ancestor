import Foundation

/// SOURCE_WEIGHTING_SPEC Change 8 — the Sourcing report: per-field
/// evidence-chain verdicts, rendered from PERSISTED state (no run needed).
/// The successor to what Verify-mode pretended to be: instead of a special
/// run type, the question "how well is this fact proven?" is answered from
/// what the evidence chain already knows.
///
/// Verdict precedence per populated identity field:
///   contradicted  — an open dispute names the field (conflict layer)
///   corroborated  — a persisted `evidence_convergence` chain backs the
///                   field's value kind (level + independent witnesses)
///   cited         — at least one FieldSource carries a citation
///   uncorroborated — value present, nothing backs it; `searched`
///                   distinguishes "we looked and found nothing"
///                   (negative_searches rows for the field's record kinds)
///                   from "never searched"
/// Empty fields are NOT reported — a gap is the Research tab's job, not a
/// sourcing defect.
nonisolated enum FactSourcingVerdict: Equatable, Sendable {
    case contradicted(openDisputes: Int)
    case corroborated(level: ConvergenceLevel, independentWitnesses: Int)
    case cited
    case uncorroborated(searched: Bool)
}

nonisolated struct FieldSourcingRow: Identifiable, Sendable {
    let field: ProfileField
    let value: String
    let verdict: FactSourcingVerdict
    var id: String { field.rawValue }
}

nonisolated struct ProfileSourcingReport: Identifiable, Sendable {
    let profileID: String
    let displayName: String
    let rows: [FieldSourcingRow]
    var id: String { profileID }

    var contradictedCount: Int {
        rows.filter { if case .contradicted = $0.verdict { return true }; return false }.count
    }
    var corroboratedCount: Int {
        rows.filter { if case .corroborated = $0.verdict { return true }; return false }.count
    }
    var citedCount: Int {
        rows.filter { $0.verdict == .cited }.count
    }
    var uncorroboratedCount: Int {
        rows.filter { if case .uncorroborated = $0.verdict { return true }; return false }.count
    }
    /// Anything demanding attention — contradicted or uncorroborated.
    var attentionCount: Int { contradictedCount + uncorroboratedCount }
}

@MainActor
enum SourcingReportService {

    /// The identity fields the report covers, with the evidence-chain
    /// value-key prefix and negative-search record kinds each maps to.
    private static let reportFields: [(field: ProfileField, chainPrefix: String?, recordKinds: Set<String>)] = [
        (.birthDate, "birth:", ["birth", "baptism", "parish"]),
        (.birthLocation, nil, ["birth", "baptism", "parish", "census"]),
        (.deathDate, "death:", ["death", "burial", "probate", "military"]),
        (.deathLocation, nil, ["death", "burial", "probate"]),
    ]

    static func report(profile: Profile, db: ProjectDatabase) -> ProfileSourcingReport {
        let convergence = (try? db.loadEvidenceConvergence(profileID: profile.id)) ?? []
        let disputes = (try? db.openDisputes(profileID: profile.id)) ?? []
        let negatives = (try? db.loadNegativeSearches(profileID: profile.id)) ?? []
        let searchedKinds = Set(negatives.map(\.recordType))

        var rows: [FieldSourcingRow] = []
        for spec in reportFields {
            guard let value = fieldValue(spec.field, of: profile), !value.isEmpty else { continue }

            let openOnField = disputes.filter { $0.field == spec.field.rawValue }.count
            if openOnField > 0 {
                rows.append(FieldSourcingRow(
                    field: spec.field, value: value,
                    verdict: .contradicted(openDisputes: openOnField)))
                continue
            }

            if let prefix = spec.chainPrefix,
               let chain = convergence
                   .filter({ $0.valueKey.hasPrefix(prefix) })
                   .max(by: { $0.level < $1.level }) {
                rows.append(FieldSourcingRow(
                    field: spec.field, value: value,
                    verdict: .corroborated(
                        level: chain.level,
                        independentWitnesses: chain.sourcing.independentWitnessCount)))
                continue
            }

            let sources = profile.sources[spec.field] ?? []
            if sources.contains(where: { $0.citation != nil }) {
                rows.append(FieldSourcingRow(field: spec.field, value: value, verdict: .cited))
                continue
            }

            let searched = !spec.recordKinds.isDisjoint(with: searchedKinds)
            rows.append(FieldSourcingRow(
                field: spec.field, value: value,
                verdict: .uncorroborated(searched: searched)))
        }

        return ProfileSourcingReport(
            profileID: profile.id,
            displayName: profile.displayName,
            rows: rows
        )
    }

    /// Tree-wide sweep — reports for every profile with at least one
    /// populated identity field, worst-first (contradicted, then
    /// uncorroborated, then by name).
    static func treeReports(snapshot: FamilyGraphSnapshot, db: ProjectDatabase) -> [ProfileSourcingReport] {
        snapshot.profiles.values
            .map { report(profile: $0, db: db) }
            .filter { !$0.rows.isEmpty }
            .sorted { a, b in
                if a.contradictedCount != b.contradictedCount {
                    return a.contradictedCount > b.contradictedCount
                }
                if a.uncorroboratedCount != b.uncorroboratedCount {
                    return a.uncorroboratedCount > b.uncorroboratedCount
                }
                return a.displayName < b.displayName
            }
    }

    private static func fieldValue(_ field: ProfileField, of profile: Profile) -> String? {
        switch field {
        case .birthDate: profile.birthDate?.original
        case .birthLocation: profile.birthLocation
        case .deathDate: profile.deathDate?.original
        case .deathLocation: profile.deathLocation
        default: nil
        }
    }
}
