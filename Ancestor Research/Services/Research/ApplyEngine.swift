import Foundation

/// The single record-level commit path: takes a scored record that a human
/// (or a rules-gated automation) has accepted and writes its data onto the
/// tree — directional overwrite policies, provenance, spouse-edge fills.
///
/// Extracted from `ResearchViewModel` (Phase 1 slice 3,
/// ARCHITECTURE_REVIEW_2026-07.md) so the UI accept path, the run-watcher
/// auto-accept path, and placeholder write-back share ONE implementation
/// instead of three drifting copies — the accept-flow bug class of 2026-05
/// existed precisely because these paths were maintained separately.
///
/// Write failures are collected and returned, not thrown: one failed field
/// write must not abort the remaining fields (pre-existing behaviour), and
/// must never be silent — callers surface every failure to log + UI.
nonisolated struct ApplyEngine {

    /// One failed persistence write during an apply.
    struct WriteFailure {
        let what: String
        let error: any Error
    }

    // MARK: - Record-level apply

    /// Write an accepted record's data onto the subject profile.
    /// BMD types write date/location fields under the overwrite policies;
    /// subject-side marriages fill the matching spouse edge; non-BMD types
    /// are the caller's LifeEvent-projection concern, not field writes.
    static func applyFactToSubject(
        _ scored: ScoredRecord,
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) -> [WriteFailure] {
        var failures: [WriteFailure] = []
        let origin = SourceOrigin(identifier: scored.record.sourceID)
        switch scored.record {
        case .birth(let r):
            let dateCandidate = bmdDate(year: r.birthYear, quarter: r.quarter, exact: r.birthDate)
            applyDateField(.birthDate, existing: profile.birthDate, candidate: dateCandidate, profileID: profile.id, origin: origin, db: db, failures: &failures)
            applyStringField(
                .birthLocation, existing: profile.birthLocation,
                existingSources: profile.sources[.birthLocation] ?? [],
                candidate: r.birthPlace ?? r.district,
                profileID: profile.id, origin: origin, db: db, failures: &failures
            )
        case .death(let r):
            let dateCandidate = bmdDate(year: r.deathYear, quarter: r.quarter, exact: r.deathDate)
            applyDateField(.deathDate, existing: profile.deathDate, candidate: dateCandidate, profileID: profile.id, origin: origin, db: db, failures: &failures)
            applyStringField(
                .deathLocation, existing: profile.deathLocation,
                existingSources: profile.sources[.deathLocation] ?? [],
                candidate: r.deathPlace ?? r.district,
                profileID: profile.id, origin: origin, db: db, failures: &failures
            )
        case .marriage(let m):
            applyMarriageToSubjectSpouseEdge(m, profileID: profile.id, snapshot: snapshot, db: db, failures: &failures)
        case .pedigree, .census, .burial, .military, .probate, .parish:
            // Non-BMD types fall through to the LifeEvent projection path in the caller.
            break
        }
        return failures
    }

    /// Apply a subject-side marriage record to the spouse edge between this
    /// subject and the matching spouse profile. Match is by surname (the
    /// `Spouse` field in BMD post-1912 marriage rows carries the spouse's
    /// surname). Marriage data is written only into nil columns via
    /// `fillRelationshipMarriage` — existing values the user typed manually
    /// are never overwritten (`Check Before Overwrite` rule).
    private static func applyMarriageToSubjectSpouseEdge(
        _ m: MarriageRecord,
        profileID: String,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase,
        failures: inout [WriteFailure]
    ) {
        guard let recordSpouseRaw = m.spouseName?.trimmingCharacters(in: .whitespaces),
              !recordSpouseRaw.isEmpty else { return }
        // BMD spouse field is normally just a surname (post-1912 marriages).
        // Defensive split: pick the trailing token in case it's "GIVEN SURNAME".
        let recordSpouseSurname = (recordSpouseRaw.split(separator: " ").last.map(String.init)
            ?? recordSpouseRaw).uppercased()

        let spouseEdges = snapshot.relationships.filter { rel in
            rel.type == .spouse && (rel.from == profileID || rel.to == profileID)
        }
        let matched = spouseEdges.first { rel in
            let otherID = rel.from == profileID ? rel.to : rel.from
            guard let other = snapshot.profiles[otherID] else { return false }
            return (other.lastName ?? "").uppercased() == recordSpouseSurname
        }
        guard let edge = matched else { return }

        let dateCandidate = bmdDate(year: m.marriageYear, quarter: m.quarter, exact: m.marriageDate)
        let locationCandidate = m.marriagePlace ?? m.district
        attempt("Record marriage on spouse edge", into: &failures) {
            try db.fillRelationshipMarriage(
                relationshipID: edge.id,
                candidateDate: dateCandidate,
                candidateLocation: locationCandidate
            )
        }
    }

    private static func applyDateField(
        _ field: ProfileField,
        existing: GenealogicalDate?,
        candidate: GenealogicalDate?,
        profileID: String,
        origin: SourceOrigin,
        db: ProjectDatabase,
        failures: inout [WriteFailure]
    ) {
        guard let candidate else { return }
        if shouldOverwriteDateField(existing: existing, candidate: candidate) {
            attempt("Apply \(field) date", into: &failures) {
                _ = try db.editProfile(profileID: profileID, changes: [], dateChanges: [(field, existing, candidate)], source: origin)
            }
        } else {
            attempt("Record alternative \(field) fact", into: &failures) {
                _ = try db.recordAlternativeFact(profileID: profileID, field: field, rawValue: candidate.original, source: origin)
            }
        }
    }

    private static func applyStringField(
        _ field: ProfileField,
        existing: String?,
        existingSources: [FieldSource],
        candidate: String?,
        profileID: String,
        origin: SourceOrigin,
        db: ProjectDatabase,
        failures: inout [WriteFailure]
    ) {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return }
        if shouldOverwriteStringField(existing: existing, existingSources: existingSources, candidateOrigin: origin) {
            attempt("Apply \(field) value", into: &failures) {
                _ = try db.editProfile(profileID: profileID, changes: [(field, existing, trimmed)], dateChanges: [], source: origin)
            }
        } else {
            attempt("Record alternative \(field) fact", into: &failures) {
                _ = try db.recordAlternativeFact(profileID: profileID, field: field, rawValue: trimmed, source: origin)
            }
        }
    }

    private static func attempt(_ what: String, into failures: inout [WriteFailure], _ op: () throws -> Void) {
        do { try op() } catch { failures.append(WriteFailure(what: what, error: error)) }
    }

    // MARK: - Overwrite policies

    /// Should an applied date overwrite the profile's existing value, or only
    /// be logged as an alternative fact?
    ///
    /// The "Check Before Overwrite" rule (`feedback_check_before_overwrite.md`)
    /// is **directional**: never overwrite *precise* data with *imprecise*
    /// data. The original `existing == nil` guard implemented the rule as
    /// **absolute** — any set value blocks any incoming value — which means a
    /// wide GEDCOM range like `BET 1869 AND 1896` blocks a 31-source
    /// cluster-confirmed `Dec 1883`. Fix: overwrite when the candidate's
    /// year-span is **strictly narrower** than the existing value's.
    ///
    /// Same-span candidates (e.g. two different precise quarters) do not
    /// overwrite — that's a disambiguation problem (the multi-hypothesis
    /// pivot owns it). They still land in `field_sources` via the
    /// `recordAlternativeFact` branch, preserving evidence for later.
    static func shouldOverwriteDateField(
        existing: GenealogicalDate?,
        candidate: GenealogicalDate
    ) -> Bool {
        guard let existing else { return true }
        return yearSpan(of: candidate) < yearSpan(of: existing)
    }

    private static func yearSpan(of date: GenealogicalDate) -> Int {
        guard let earliest = date.earliest, let latest = date.latest else { return .max }
        return latest - earliest
    }

    /// Should an applied string overwrite the profile's existing value, or
    /// only be logged as an alternative fact?
    ///
    /// Strings have no precision axis like dates, so we substitute
    /// provenance via `SourceOrigin.tier`. A higher-tier candidate
    /// overrides a lower-tier existing value:
    ///
    /// - existing nil/empty → write candidate
    /// - existing's highest known tier < candidate's tier → overwrite
    /// - otherwise → keep existing, log candidate as alternative fact
    ///
    /// Defensive default when the existing value is set but `field_sources`
    /// is empty: treat existing as `.userAuthoritative` (don't overwrite).
    /// In normal use every Profile.* write also writes `field_sources`, so
    /// this branch only fires if the audit log is corrupt — better to err
    /// toward preserving the user's data than to silently overwrite.
    ///
    /// Same-tier candidates do not overwrite — that's a disambiguation
    /// problem (multi-hypothesis investigation owns it for cases where two
    /// research sources disagree). They still land in `field_sources` via
    /// `recordAlternativeFact`.
    static func shouldOverwriteStringField(
        existing: String?,
        existingSources: [FieldSource],
        candidateOrigin: SourceOrigin
    ) -> Bool {
        if (existing ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return true }
        guard let existingTier = existingSources.map(\.origin.tier).max() else {
            return false
        }
        return candidateOrigin.tier > existingTier
    }

    // MARK: - BMD dates

    /// Build a `GenealogicalDate` from a BMD record's year + quarter. BMD
    /// quarters are labelled by the END month ("Mar quarter" = Jan–Mar);
    /// year-granularity storage means we keep that nuance in the original
    /// string ("Mar 1976") rather than in earliest/latest.
    static func bmdDate(year: Int?, quarter: String?, exact: String?) -> GenealogicalDate? {
        if let exact = exact?.trimmingCharacters(in: .whitespaces), !exact.isEmpty {
            return GenealogicalDate(parsing: exact)
        }
        guard let year else { return nil }
        if let q = quarter?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            return GenealogicalDate(parsing: "\(q) \(year)")
        }
        return GenealogicalDate(parsing: String(year))
    }

    // MARK: - Birth-year candidate

    /// Pure apply: does the actual write through `ProjectDatabase`.
    /// Static + nonisolated so unit tests can exercise it without an
    /// `AppState` harness. Returns void on success; throws on missing
    /// profile / unsuitable hypothesis.
    static func applyBirthYearCandidate(
        _ hypothesis: ResearchHypothesis,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws {
        guard case .birthYearCandidate(let profileID, let year) = hypothesis.kind else {
            throw ApplyBirthYearCandidateError.wrongKind
        }
        guard hypothesis.isDeterministicallySupported else {
            throw ApplyBirthYearCandidateError.notSupported
        }
        guard let profile = snapshot.profiles[profileID] else {
            throw ApplyBirthYearCandidateError.profileMissing(profileID)
        }

        // Prefer an existing precise source attesting to this year — its
        // raw preserves month detail ("Dec 1883" vs bare "1883") and its
        // origin preserves provenance tier.
        let chosen = (profile.sources[.birthDate] ?? []).first { src in
            let parsed = GenealogicalDate(parsing: src.raw)
            guard let e = parsed.earliest, let l = parsed.latest else { return false }
            return e == l && e == year
        }
        let raw = chosen?.raw ?? String(year)
        let origin = chosen?.origin ?? .engineEnrichment
        let candidate = GenealogicalDate(parsing: raw)

        _ = try db.editProfile(
            profileID: profile.id,
            changes: [],
            dateChanges: [(.birthDate, profile.birthDate, candidate)],
            source: origin
        )
    }

    /// Errors thrown by `applyBirthYearCandidate`.
    enum ApplyBirthYearCandidateError: Error {
        case wrongKind
        case notSupported
        case profileMissing(String)
    }
}
