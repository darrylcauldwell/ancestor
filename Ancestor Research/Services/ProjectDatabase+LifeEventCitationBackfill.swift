import Foundation
import GRDB
import AncestorKit

/// EV16 backfill (2026-08-26). `b5c8165` fixed the three derived-event
/// builders to carry their record's citation, but every row already written
/// still holds `sources: []` — an uncitable fact sitting in a real tree,
/// rendering with no badge beside the fully-cited event stating the identical
/// thing (owner dogfood: William Gladwin's "Coal Carve Mender", 1881
/// Handsworth, next to the FamilySearch-cited 1881 census it came from).
///
/// Provenance is recoverable WITHOUT GUESSING because a projected life event's
/// id is `SHA256(profileID | sourceRecordID [#discriminator])`
/// (`SourceRecord.deterministicID`). Re-deriving that id from a record still
/// in the database and matching the persisted row EXHIBITS THE PREIMAGE: the
/// row was written by that record, or a 122-bit collision occurred. This is
/// the same proof `removeAppliedRecord` already relies on to DELETE events —
/// and adding a citation is strictly safer than deleting.
///
/// THAT PROOF HOLDS ONLY FOR PASS A. Review F01 (2026-08-26): pass B does not
/// hash a stored record id, it hashes one SYNTHESISED by
/// `CensusBackfill.memberRecord`, whose id is `sourceID + member name + census
/// year` with NO household identity in it. Two unrelated households holding a
/// namesake mint the same id, so exhibiting the preimage identifies the NAME,
/// not the household. Pass B therefore leans on two extra restrictions, and
/// neither may be dropped: every id-matching household registers a claim,
/// tree-wide, INCLUDING one whose projection has no source, because a household
/// with no detail URL is still asserting the row is its own; and a household may
/// only WRITE onto profiles that are graph neighbours of its own subject, the
/// sole edge the absorb path can cross. Widest possible contest, narrowest
/// possible write. Any disagreement leaves the row blank.
///
/// It never invents a citation. The repair value is whatever
/// `projectToLifeEvents` produces TODAY from the stored record — i.e. the
/// record's own `detailURL` — so a repaired row is byte-identical to a fresh
/// apply. A record with no URL yields no source and the row stays empty, which
/// is correct: a manufactured citation is worse than none.
///
/// KNOWN RESIDUAL, reported not fixed (Review F01, 2026-08-26). Pass A's
/// preimage is only as unique as the record id it hashes, and the Triage accept
/// path mints `fieldresearcher_census_<profileID>_<year>` — so accepting a
/// SECOND, rival 1881 household for one person upserts over the first
/// (`saveEvidence` overwrites `record_json` on id conflict) while the first
/// household's derived rows keep that same id. Pass A would then cite the
/// surviving household's URL on them. Undetectable from here: the losing record
/// no longer exists in the database, so there is nothing to weigh it against,
/// and `location` cannot break the tie because `correctLocationText` rewrites
/// that column at the user's discretion (see
/// `aCorrectedPlaceDoesNotBlockTheRepair`). The fix belongs at the mint —
/// `saveAcceptedCensusEvidence` giving each accepted household its own id — not
/// here.
///
/// EXPLICITLY REJECTED as unsafe, and not to be "simplified" back in: matching
/// an uncited `.occupation` to a same-profile same-year cited `.census` event.
/// That is similarity, not proof — the app legitimately holds rival census
/// records for one year, and an 1881 occupation can equally come from an 1881
/// parish marriage.
nonisolated extension ProjectDatabase {

    /// Test/maintenance hook — the same body the v64 migration runs.
    @discardableResult
    func backfillDerivedLifeEventCitations() throws -> Int {
        try dbQueue.write { try Self.backfillDerivedLifeEventCitations($0) }
    }

    /// Returns the number of `life_events` rows that regained a citation.
    ///
    /// Runs entirely on the passed-in open `Database`: never call
    /// `loadLifeEvents` / `loadEvidenceForProfile` from here — those open
    /// their own `dbQueue.read` and would deadlock inside the migration's
    /// write transaction (the trap `removeAppliedRecord` documents).
    @discardableResult
    static func backfillDerivedLifeEventCitations(_ db: Database) throws -> Int {
        // 1. Every uncited life event, keyed by profile. `location` is
        //    deliberately not consulted anywhere in this pass —
        //    `ProjectDatabase+PlaceTextCorrection` rewrites that column, and a
        //    corrected place must not block a repairable row.
        var byProfile: [String: [UUID: LifeEvent]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM life_events") {
            guard let event = lifeEventFromRow(row), event.sources.isEmpty else { continue }
            byProfile[event.profileID, default: [:]][event.id] = event
        }
        guard !byProfile.isEmpty else { return 0 }

        // 1b. Review F01 (2026-08-26). Pass B's preimage is NOT unique —
        //     `CensusBackfill.memberRecord` mints its id from
        //     `sourceID + member name + census year` with no household
        //     identity in it, so two unrelated households holding a namesake
        //     ("field-researcher_hh_John_Land_1881") mint the same id and
        //     therefore the same event id on any profile. The hash alone
        //     therefore proves nothing for a member record, and a tree-wide
        //     pass B could stamp a stranger's census URL onto a row a
        //     different household authored.
        //
        //     The absorb path that writes those rows
        //     (`AppState.absorbCensus` ← `CensusBackfill.proposals` /
        //     `.corroborations` / `.citations`) only ever targets
        //     `linkedRelatives(of: subjectID)` — parents, spouses, children
        //     and shared-parent siblings of the profile the household is
        //     filed against. That is the ONLY relationship the write could
        //     have, so a member record is offered only to those profiles.
        //     Built here from raw edges: `buildSnapshot` opens its own
        //     `dbQueue.read` and would deadlock inside the migration.
        var parentsOf: [String: Set<String>] = [:]    // child → parents
        var childrenOf: [String: Set<String>] = [:]   // parent → children
        var spousesOf: [String: Set<String>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT from_id, to_id, type FROM relationships") {
            guard let from = row["from_id"] as String?,
                  let to = row["to_id"] as String?,
                  let type = row["type"] as String? else { continue }
            switch type {
            case "parent":
                childrenOf[from, default: []].insert(to)
                parentsOf[to, default: []].insert(from)
            case "spouse":
                spousesOf[from, default: []].insert(to)
                spousesOf[to, default: []].insert(from)
            default:
                continue
            }
        }
        /// The profiles the absorb path could have written a member record of
        /// `subject`'s household onto. Mirrors `CensusBackfill.linkedRelatives`
        /// (siblings are derived from shared parents — no sibling edges exist).
        func absorbTargets(of subject: String) -> Set<String> {
            let parents = parentsOf[subject] ?? []
            var out = parents
            out.formUnion(childrenOf[subject] ?? [])
            out.formUnion(spousesOf[subject] ?? [])
            for parent in parents { out.formUnion(childrenOf[parent] ?? []) }
            out.remove(subject)
            return out
        }

        // 2. Candidate records. Pass A is profile-scoped; a pass-B household is
        //    weighed tree-wide but may only WRITE onto its own subject's graph
        //    neighbours (see 1b).
        var passA: [String: [SourceRecord]] = [:]     // profileID → its own records
        // synthesised member-record id → the households that mint it (keyed by
        // owning-household identity), each with the profiles it may repair.
        // Bucketed by member id because every household in a bucket produces
        // the SAME three event ids for a given profile — so the id-first filter
        // hashes once per bucket rather than once per household.
        var passB: [String: [String: (record: SourceRecord, targets: Set<String>)]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT profile_id, record_json FROM evidence_records") {
            guard let profileID = row["profile_id"] as String?,
                  let json = row["record_json"] as String?,
                  let data = json.data(using: .utf8),
                  let record = try? JSONDecoder().decode(SourceRecord.self, from: data)
            // Soft skip, never fail the migration: a future Codable change
            // must not make an old row un-openable (same lenient decode
            // `loadEvidenceForProfile` uses).
            else { continue }
            passA[profileID, default: []].append(record)
            // A census household is absorbed onto LINKED RELATIVES via
            // `CensusBackfill.memberRecord`, and the absorb path writes NO
            // evidence row on the relative — so the relative's derived events
            // are reachable only through the SUBJECT's household. That is the
            // case the filed defect is; a backfill scoped to each profile's
            // own `evidence_records` would not repair it.
            if case .census(let census) = record, let household = census.household {
                // A household with no linked relatives could never have been
                // absorbed onto anybody, so it may WRITE nothing — but it is
                // still kept, because it can still contest somebody else's
                // claim on the same id (see `claims` below).
                let targets = absorbTargets(of: profileID)
                for member in household {
                    let synthesised = CensusBackfill.memberRecord(for: member, in: census)
                    // Review F01 (2026-08-26): within a bucket, dedupe on the
                    // OWNING household record (its own id + URL) — NOT on the
                    // synthesised member id, which carries no household
                    // identity, so the old key silently collapsed two
                    // genuinely different households into one candidate
                    // whenever they also shared a detailURL-less roster name.
                    // Keyed this way every distinct household survives to be
                    // weighed by the ambiguity guard, while the identical
                    // household saved on several profiles still collapses,
                    // unioning the profiles each copy could have reached.
                    let identity = "\(record.id)|\(record.common.detailURL ?? "")"
                    let memberID = synthesised.common.id
                    if let existing = passB[memberID]?[identity] {
                        passB[memberID]?[identity] = (existing.record,
                                                      existing.targets.union(targets))
                    } else {
                        passB[memberID, default: [:]][identity] = (.census(synthesised), targets)
                    }
                }
            }
        }

        // 3. Match by preimage. Nothing is written until every candidate has
        //    spoken, so a row two different records could each have authored is
        //    REFUSED rather than resolved by iteration order — the preimage
        //    proves provenance only when it is unique.
        //
        //    Two separate ledgers, and the split is the whole Review F01 fix:
        //    `claims` records what EVERY id-matching candidate would write,
        //    tree-wide and including candidates that would write nothing;
        //    `proposals` holds only what an ELIGIBLE candidate offers. A row is
        //    repaired when the claims agree — one distinct claim — and that
        //    claim is not empty. Contest is therefore judged on the widest
        //    possible field while writing is judged on the narrowest.
        var proposals: [UUID: (profileID: String, sources: [FieldSource])] = [:]
        var claims: [UUID: Set<[String]>] = [:]

        func consider(_ record: SourceRecord, profileID: String,
                      uncited: [UUID: LifeEvent], mayWrite: Bool) {
            // Cheap id-first filter: only project when an id actually hits.
            // Dropping it turns pass B's cross product into a multi-second
            // stall inside migration at project open.
            let ids = [
                SourceRecord.deterministicID(profileID: profileID, sourceRecordID: record.id),
                SourceRecord.deterministicID(profileID: profileID, sourceRecordID: record.id,
                                             discriminator: "occupation"),
                SourceRecord.deterministicID(profileID: profileID, sourceRecordID: record.id,
                                             discriminator: "residence"),
            ]
            guard ids.contains(where: { uncited[$0] != nil }) else { return }
            for projected in record.projectToLifeEvents(profileID: profileID) {
                guard let stored = uncited[projected.id],
                      stored.type == projected.type,     // shape must agree
                      // A hand-edited value is not this record's fact.
                      stored.description == projected.description
                else { continue }
                // Review F01 (2026-08-26): the claim is registered BEFORE the
                // never-manufacture test, which used to sit in the guard above
                // as `!projected.sources.isEmpty`. A rival household with no
                // detail URL projects NO source (`censusSource` returns [] when
                // `detailURL` is nil), so it `continue`d out before it could
                // register — and the one rival that DID carry a URL then won
                // uncontested and stamped a stranger's census page onto a row
                // the URL-less household authored. A household that can cite
                // nothing is still asserting that the row is ITS fact, and that
                // contradicts any rival that would cite something.
                //
                // The claim is the exact write, not just the URL, so two
                // candidates only agree when they would produce the same row.
                let claim = projected.sources
                    .map { "\($0.origin.identifier)|\($0.citation?.url ?? "")" }
                    .sorted()
                claims[projected.id, default: []].insert(claim)
                guard mayWrite, !projected.sources.isEmpty else { continue }
                if proposals[projected.id] == nil {
                    proposals[projected.id] = (profileID, projected.sources)
                }
            }
        }

        let memberBuckets = passB.map { (memberID: $0.key, households: Array($0.value.values)) }
        for (profileID, uncited) in byProfile {
            for record in passA[profileID] ?? [] {
                consider(record, profileID: profileID, uncited: uncited, mayWrite: true)
            }
            // Pass B is walked separately rather than concatenated onto pass A
            // — copying it per profile would be real retain traffic on a big
            // tree. Review F01 (2026-08-26): a household may only WRITE onto a
            // profile its own subject is linked to, because that is the only
            // edge `absorbCensusForRelative` can have crossed; it is still
            // walked against every profile, so an unrelated household that
            // mints the same member id can veto a repair it could not make.
            for bucket in memberBuckets {
                // Same id-first filter as `consider`, hoisted to the bucket:
                // every household here mints the same member id and so hits the
                // same three event ids on this profile.
                let hits = [
                    SourceRecord.deterministicID(profileID: profileID,
                                                 sourceRecordID: bucket.memberID),
                    SourceRecord.deterministicID(profileID: profileID,
                                                 sourceRecordID: bucket.memberID,
                                                 discriminator: "occupation"),
                    SourceRecord.deterministicID(profileID: profileID,
                                                 sourceRecordID: bucket.memberID,
                                                 discriminator: "residence"),
                ].contains { uncited[$0] != nil }
                guard hits else { continue }
                for household in bucket.households {
                    consider(household.record, profileID: profileID, uncited: uncited,
                             mayWrite: household.targets.contains(profileID))
                }
            }
        }

        // 4. Guarded UPDATE: re-asserts emptiness (check-before-overwrite) and
        //    touches ONE column. Review F01 (2026-08-26): the single-claim test
        //    is the ambiguity guard and `sources.isEmpty` is the
        //    never-manufacture rule — both live here rather than in `consider`
        //    so that a candidate which can cite nothing still gets a vote.
        var repaired = 0
        for (eventID, proposal) in proposals where claims[eventID]?.count == 1 {
            try db.execute(sql: """
                UPDATE life_events SET sources_json = ?
                WHERE id = ? AND profile_id = ?
                  AND (sources_json IS NULL OR TRIM(sources_json) IN ('', '[]'))
                """, arguments: [encodeJSON(proposal.sources),
                                 eventID.uuidString, proposal.profileID])
            repaired += db.changesCount
        }
        return repaired
    }
}
