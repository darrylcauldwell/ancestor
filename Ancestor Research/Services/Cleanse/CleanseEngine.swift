import Foundation
import os

/// CLEANSE_WIZARD_SPEC §3 — generates findings for a profile or the whole
/// tree, and applies the user\u{2019}s chosen action.
///
/// Generation is on-demand (not cached): each call to `findings(for:)` runs
/// the rule set fresh against the current profile state, then filters out any
/// finding whose (profileID, fieldKey) is flagged unresolvable in the
/// `cleanse_unresolvable_flags` table.
///
/// Apply path mutates the database and returns; callers are responsible for
/// refreshing the snapshot they show in their views.
@MainActor
@Observable
final class CleanseEngine {

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "CleanseEngine"
    )

    private let database: ProjectDatabase
    private let snapshotProvider: () -> FamilyGraphSnapshot
    private let gazetteer: LocationGazetteer
    private let sourceInfoMap: [String: SourceInfo]

    init(
        database: ProjectDatabase,
        snapshot: @escaping () -> FamilyGraphSnapshot,
        sourceInfoMap: [String: SourceInfo],
        gazetteer: LocationGazetteer = .shared
    ) {
        self.database = database
        self.snapshotProvider = snapshot
        self.sourceInfoMap = sourceInfoMap
        self.gazetteer = gazetteer
    }

    // MARK: - Generation

    /// All findings the wizard should present for one profile, in the order
    /// the spec recommends (locations first, then parents, then dates).
    /// Excludes any finding the user has marked unresolvable.
    func findings(for profileID: String) -> [CleanseFinding] {
        let snap = snapshotProvider()
        guard let profile = snap.profiles[profileID] else {
            return []
        }
        var results: [CleanseFinding] = []

        if let nameFinding = givenNameFinding(for: profile) {
            results.append(nameFinding)
        }
        if let locationFinding = locationFinding(for: profile) {
            results.append(locationFinding)
        }
        if let parentFinding = parentFinding(for: profile, snapshot: snap) {
            results.append(parentFinding)
        }
        if let birthDateFinding = bareYearFinding(
            for: profile,
            field: .birthDate,
            date: profile.birthDate
        ) {
            results.append(birthDateFinding)
        }
        if let deathDateFinding = bareYearFinding(
            for: profile,
            field: .deathDate,
            date: profile.deathDate
        ) {
            results.append(deathDateFinding)
        }

        return results.filter { !isUnresolvable($0) }
    }

    /// Findings across the whole tree, in profile-display order. Profiles
    /// with zero findings are omitted from the result.
    func findingsForAllProfiles() -> [(profile: Profile, findings: [CleanseFinding])] {
        let snap = snapshotProvider()
        return snap.profiles.values
            .sorted { ($0.lastName ?? "") < ($1.lastName ?? "") }
            .compactMap { profile in
                let f = findings(for: profile.id)
                return f.isEmpty ? nil : (profile, f)
            }
    }

    // MARK: - Apply

    /// Resolve a single finding with the user\u{2019}s chosen action. Throws on
    /// database errors only; `.skip` and a no-op `.applyProposedRelatives([])`
    /// are silent no-ops.
    func apply(_ action: CleanseAction, to finding: CleanseFinding) throws {
        switch action {
        case .skip:
            return

        case .markUnresolvable:
            try database.markCleanseUnresolvable(
                profileID: finding.profileID,
                field: finding.fieldKey
            )

        case .applyLocationMatch(let entry):
            try applyLocation(
                finding: finding,
                displayName: entry.displayName,
                code: entry.id
            )

        case .applyLocationFreeform(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // If the new text now resolves to exactly one entry, attach the code
            // automatically rather than re-prompting next run.
            let matches = gazetteer.match(trimmed)
            if matches.count == 1 {
                try applyLocation(
                    finding: finding,
                    displayName: matches[0].displayName,
                    code: matches[0].id
                )
            } else {
                try applyLocation(finding: finding, displayName: trimmed, code: nil)
            }

        case .applyProposedRelatives(let proposals):
            guard !proposals.isEmpty else { return }
            for proposal in proposals {
                _ = try database.acceptProposedRelative(proposal)
            }

        case .applyBareYearQuarter(let quarter):
            guard case .bareYearDate(_, let field, let year, _) = finding else {
                Self.logger.error("applyBareYearQuarter on non-bare-year finding \(finding.kind)")
                return
            }
            try applyBareYearQuarter(
                profileID: finding.profileID,
                field: field,
                year: year,
                quarter: quarter
            )

        case .applyGivenMiddleSplit(let first, let middle):
            try applyGivenMiddleSplit(
                finding: finding,
                first: first,
                middle: middle
            )
        }
    }

    // MARK: - Finding generators

    /// Fires when `firstName` holds more than one token while `middleName` is
    /// empty — the import folded the middle name into the given field. Detection
    /// is `Profile.impliedGivenMiddleSplit`, shared with `GivenNameContainsMiddleRule`
    /// so the audit chip and the cleanse fix agree on which records are affected.
    private func givenNameFinding(for profile: Profile) -> CleanseFinding? {
        guard let split = profile.impliedGivenMiddleSplit else { return nil }
        return .givenNameContainsMiddle(
            profileID: profile.id,
            currentGiven: profile.firstName ?? "",
            proposedFirst: split.first,
            proposedMiddle: split.middle
        )
    }

    private func locationFinding(for profile: Profile) -> CleanseFinding? {
        guard let raw = profile.birthLocation?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        let alreadyCoded = profile.birthLocationCode?.isEmpty == false
        let matches = gazetteer.match(raw)

        if alreadyCoded {
            // Code is set — no follow-up needed. (Mismatch detection between
            // the freeform string and the structured code is out of scope.)
            return nil
        }

        if matches.isEmpty {
            // No-match: surface unmatched-location with fuzzy near-misses.
            return .unmatchedLocation(
                profileID: profile.id,
                rawValue: raw,
                fuzzyMatches: fuzzyMatches(for: raw)
            )
        }
        if matches.count == 1 {
            return .unconfirmedLocation(
                profileID: profile.id,
                rawValue: raw,
                match: matches[0]
            )
        }
        return .ambiguousLocation(
            profileID: profile.id,
            rawValue: raw,
            candidates: matches
        )
    }

    /// Best-effort near-miss matches when an exact lookup returned nothing.
    /// Tries the first three letters as a prefix — cheap and surfaces
    /// "Wrksworth" \u{2192} "Wirksworth" / "Crich" style typos without dragging
    /// in a full Levenshtein implementation. Empty list when the input is too
    /// short or shares no prefix with anything we ship.
    private func fuzzyMatches(for query: String) -> [GazetteerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return [] }
        let prefix = String(q.prefix(3))
        return gazetteer.match(prefix, limit: 5)
    }

    private func parentFinding(
        for profile: Profile,
        snapshot: FamilyGraphSnapshot
    ) -> CleanseFinding? {
        // Already has parents — nothing to surface.
        if !snapshot.parentsOf(profile.id).isEmpty { return nil }

        let evidence: [EvidenceRecord]
        do {
            evidence = try database.loadEvidenceForProfile(profile.id)
        } catch {
            Self.logger.error("loadEvidenceForProfile failed: \(error.localizedDescription)")
            return nil
        }

        // Re-wrap each evidence row as a ScoredRecord so the inference engine
        // sees the same shape it would from the pipeline\u{2019}s in-memory facts.
        // The verdict already lives on the row from the original scoring pass;
        // the gates / summary aren\u{2019}t read by the inference rule so they can
        // be empty.
        let scored: [ScoredRecord] = evidence.map { row in
            ScoredRecord(
                id: row.id,
                record: row.record,
                verdict: row.verdict,
                gates: [],
                summary: ""
            )
        }

        let subject = ResearchSubject.fromProfile(profile, snapshot: snapshot, mode: .extend)

        let proposals = ParentInferenceEngine.infer(
            from: scored,
            subject: subject,
            existingParents: [],
            sourceInfoMap: sourceInfoMap
        )

        return proposals.isEmpty
            ? nil
            : .missingParentFromBirthRecord(profileID: profile.id, proposals: proposals)
    }

    private func bareYearFinding(
        for profile: Profile,
        field: CleanseDateField,
        date: GenealogicalDate?
    ) -> CleanseFinding? {
        guard let date,
              date.qualifier == .yearOnly,
              let year = date.earliest,
              year == date.latest
        else { return nil }

        let availableQuarter = (try? quarterFromEvidence(profileID: profile.id, field: field, year: year)) ?? nil
        return .bareYearDate(
            profileID: profile.id,
            field: field,
            year: year,
            availableQuarter: availableQuarter
        )
    }

    /// If a confirmed BMD record exists for this profile in the same year and
    /// carries a quarter string, surface it as a one-tap apply.
    private func quarterFromEvidence(
        profileID: String,
        field: CleanseDateField,
        year: Int
    ) throws -> String? {
        let evidence = try database.loadEvidenceForProfile(profileID)
        for row in evidence where row.verdict == .fact {
            switch (field, row.record) {
            case (.birthDate, .birth(let birth)) where birth.birthYear == year:
                if let q = birth.quarter, !q.isEmpty { return q }
            case (.deathDate, .death(let death)) where death.deathYear == year:
                if let q = death.quarter, !q.isEmpty { return q }
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Apply helpers

    private func applyLocation(
        finding: CleanseFinding,
        displayName: String,
        code: String?
    ) throws {
        guard let profile = snapshotProvider().profiles[finding.profileID]
        else { throw CleanseError.profileNotFound(finding.profileID) }

        _ = try database.editProfile(
            profileID: profile.id,
            changes: [(
                field: .birthLocation,
                oldValue: profile.birthLocation,
                newValue: displayName
            )],
            dateChanges: [],
            source: .manual
        )
        try database.updateProfileLocationCodes(
            profileID: profile.id,
            birthCode: code,
            deathCode: profile.deathLocationCode
        )
    }

    /// Split a folded given name into firstName + middleName. Manual-sourced
    /// (the user reviewed and accepted the split), so it takes the standard
    /// directional-overwrite path like any other manual correction.
    private func applyGivenMiddleSplit(
        finding: CleanseFinding,
        first: String,
        middle: String
    ) throws {
        guard let profile = snapshotProvider().profiles[finding.profileID]
        else { throw CleanseError.profileNotFound(finding.profileID) }

        _ = try database.editProfile(
            profileID: profile.id,
            changes: [
                (field: .firstName, oldValue: profile.firstName, newValue: first),
                (field: .middleName, oldValue: profile.middleName, newValue: middle),
            ],
            dateChanges: [],
            source: .manual
        )
    }

    private func applyBareYearQuarter(
        profileID: String,
        field: CleanseDateField,
        year: Int,
        quarter: String
    ) throws {
        guard let profile = snapshotProvider().profiles[profileID]
        else { throw CleanseError.profileNotFound(profileID) }

        let oldDate: GenealogicalDate?
        let profileField: ProfileField
        switch field {
        case .birthDate:
            oldDate = profile.birthDate
            profileField = .birthDate
        case .deathDate:
            oldDate = profile.deathDate
            profileField = .deathDate
        }

        // "Q2 1850" is the canonical surface form. The parser folds it back
        // to qualifier .exact / earliest == latest == year, but keeps the
        // original string for display — exactly what we want.
        let newDate = GenealogicalDate(parsing: "\(quarter) \(year)")

        _ = try database.editProfile(
            profileID: profileID,
            changes: [],
            dateChanges: [(field: profileField, oldDate: oldDate, newDate: newDate)],
            source: .manual
        )
    }

    // MARK: - Unresolvable filter

    private func isUnresolvable(_ finding: CleanseFinding) -> Bool {
        (try? database.isCleanseUnresolvable(
            profileID: finding.profileID,
            field: finding.fieldKey
        )) ?? false
    }
}
