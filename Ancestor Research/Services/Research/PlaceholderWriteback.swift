import Foundation

/// Promotes a thin `@FR_*@` placeholder profile to a richer one when
/// its own research results converge strongly on a single given name.
/// Implements ENGINE_FOUNDATION_SPEC #Change2 (the "thin → rich"
/// pipeline).
///
/// Pure consensus logic in `propose(from:)`; side-effects (UPDATE
/// profile through the audit path) in `apply(...)`. Splitting them
/// keeps the decision unit-testable without a live SQLite.
///
/// Idempotency: `apply` re-reads the profile and re-checks density;
/// once a profile has been enriched to `.rich`, subsequent calls
/// short-circuit. No risk of stomping a value the user supplied or
/// a previous round wrote.
nonisolated struct PlaceholderWriteback {

    // MARK: - Thresholds (in-code constants per spec; config.yaml
    // exposure deferred to #Change1b / #Change2b).

    /// Minimum number of records (carrying any given name) required
    /// before consensus is even considered. Below this, agreement is
    /// just noise.
    static let minSupportingRecords: Int = 5

    /// The dominant given name must account for at least this share
    /// of all records carrying any given name.
    static let givenNameConsensusFloor: Double = 0.7

    /// The second-most-common given name must account for **at most**
    /// this share. Together with the floor above, this enforces
    /// "one name dominates, runner-up is no contest" — refuses
    /// write-back when two names share the field roughly evenly.
    static let runnerUpCeiling: Double = 0.2

    // MARK: - Proposal

    nonisolated struct Proposal: Equatable, Sendable {
        let givenName: String
        let birthYearEarliest: Int?
        let birthYearLatest: Int?
        let supportingRecordCount: Int
    }

    // MARK: - Record-type extractor

    /// Pull a birth-year signal out of a SourceRecord. Each record
    /// type contributes whatever it can — birth records are direct,
    /// census records derive the year from age, baptism parish events
    /// approximate, etc. Returns nil when the record type carries no
    /// usable birth-year signal (death/marriage on their own).
    static func extractBirthYear(from record: SourceRecord) -> Int? {
        switch record {
        case .birth(let r): return r.birthYear
        case .census(let r): return r.birthYear
        case .burial(let r): return r.birthYear
        case .pedigree(let r): return r.birthYear
        case .parish(let r):
            // Baptism is close to birth; other parish events are not.
            let type = (r.eventType ?? "").lowercased()
            return type == "baptism" ? r.eventYear : nil
        case .death, .marriage, .military, .probate:
            return nil
        }
    }

    // MARK: - Decision (pure)

    /// Decide whether a write-back proposal exists, given the scored
    /// records the engine produced for this thin placeholder.
    ///
    /// `records` is the call-site's extraction from `result.allScoredRecords`:
    /// pairs of `(givenName, birthYear)` from records the scorer did
    /// **not** classify `.impossible`. Caller-driven extraction keeps
    /// the decision function pure.
    static func propose(
        from records: [(givenName: String?, birthYear: Int?)]
    ) -> Proposal? {
        // 1. Keep only records that carry a given name.
        let withGiven: [(name: String, lower: String, birthYear: Int?)] = records.compactMap { r in
            let trimmed = (r.givenName ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return (name: trimmed, lower: trimmed.lowercased(), birthYear: r.birthYear)
        }
        guard withGiven.count >= minSupportingRecords else { return nil }

        // 2. Group by lowercased given name.
        var counts: [String: Int] = [:]
        var yearsByName: [String: [Int]] = [:]
        var firstOriginalByName: [String: String] = [:]
        for r in withGiven {
            counts[r.lower, default: 0] += 1
            if let y = r.birthYear {
                yearsByName[r.lower, default: []].append(y)
            }
            if firstOriginalByName[r.lower] == nil {
                firstOriginalByName[r.lower] = r.name
            }
        }

        // 3. Rank by support count.
        let ranked = counts.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return nil }

        let totalWithGiven = Double(withGiven.count)
        let topShare = Double(top.value) / totalWithGiven
        guard topShare >= givenNameConsensusFloor else { return nil }

        if ranked.count >= 2 {
            let runnerUp = Double(ranked[1].value) / totalWithGiven
            guard runnerUp <= runnerUpCeiling else { return nil }
        }

        // 4. Year window comes from supporting records that carry a
        // year. If none do, leave the window nil — the caller will
        // skip the date write-back.
        let years = yearsByName[top.key] ?? []
        let earliest = years.min()
        let latest = years.max()

        // 5. Preserve original casing from the records (FreeBMD often
        // returns ALL CAPS; we don't want "JENNIFER" written into the
        // tree if the records said so).
        let originalCase = firstOriginalByName[top.key] ?? top.key.capitalized

        return Proposal(
            givenName: originalCase,
            birthYearEarliest: earliest,
            birthYearLatest: latest,
            supportingRecordCount: top.value
        )
    }

    // MARK: - Apply (side-effecting)

    /// Apply a proposal to the given profile. Re-reads the profile,
    /// re-checks density, and writes through `ProjectDatabase.editProfile`
    /// so the change lands in `field_changes` / `field_sources` /
    /// `transactions` (full audit trail) under
    /// `SourceOrigin.engineEnrichment`.
    ///
    /// Returns `true` when the write actually happened, `false` when
    /// the profile was no longer thin (so we declined to touch it).
    @discardableResult
    static func apply(
        proposal: Proposal,
        profileID: String,
        db: ProjectDatabase
    ) throws -> Bool {
        guard let profile = try db.loadProfile(id: profileID) else {
            return false
        }

        // Re-check density: if the profile is no longer thin (another
        // pass or a manual edit already enriched it), refuse to
        // overwrite. Memory: feedback_check_before_overwrite.md.
        let currentSubject = ResearchSubject(
            surname: profile.lastName,
            givenName: profile.firstName,
            birthYearFrom: profile.birthDate?.earliest,
            birthYearTo: profile.birthDate?.latest,
            gender: nil,
            region: nil,
            mode: .discover
        )
        guard InformationDensity.from(subject: currentSubject) == .thin else {
            return false
        }

        // Build the date change only when (a) the proposal carries a
        // year window and (b) the existing date is missing or wider.
        var dateChanges: [(field: ProfileField, oldDate: GenealogicalDate?, newDate: GenealogicalDate?)] = []
        if let newEarliest = proposal.birthYearEarliest,
           let newLatest = proposal.birthYearLatest {
            let newDate = GenealogicalDate(
                original: newEarliest == newLatest ? "\(newEarliest)" : "BET \(newEarliest) AND \(newLatest)",
                earliest: newEarliest,
                latest: newLatest,
                isApproximate: newEarliest != newLatest,
                qualifier: newEarliest == newLatest ? .yearOnly : .between
            )
            let oldDate = profile.birthDate
            let newSpan = newLatest - newEarliest
            let oldSpan: Int? = {
                guard let oe = oldDate?.earliest, let ol = oldDate?.latest else { return nil }
                return ol - oe
            }()
            // Only narrow, never widen, the existing window.
            if oldSpan == nil || newSpan < oldSpan! {
                dateChanges.append((field: .birthDate, oldDate: oldDate, newDate: newDate))
            }
        }

        let nameChange: (field: ProfileField, oldValue: String?, newValue: String?) =
            (field: .firstName, oldValue: profile.firstName, newValue: proposal.givenName)

        _ = try db.editProfile(
            profileID: profileID,
            changes: [nameChange],
            dateChanges: dateChanges,
            source: .engineEnrichment
        )
        return true
    }
}
