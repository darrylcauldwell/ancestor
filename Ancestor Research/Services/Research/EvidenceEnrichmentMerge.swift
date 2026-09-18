import Foundation
import AncestorKit

/// EV31 (2026-08-26), second half — stop a research run throwing away evidence
/// the user already paid a request for.
///
/// `ProjectDatabase.saveEvidence` upserts on the composite id and its
/// `ON CONFLICT DO UPDATE` sets `record_json = excluded.record_json` wholesale.
/// Record ids are stable across runs (`FreeREGSource.stableRecordID` is derived
/// from the entry URL), and a run re-scores from the SEARCH RESULTS TABLE,
/// whose rows are built with `fatherName: nil, motherName: nil` and no
/// `detail:` at all. So the next run over the same profile overwrites a fetched
/// register entry with the bare row it came from: the parents vanish,
/// `canLoadParishDetail` flips back to true, and the user is asked to spend
/// another GET against a volunteer service for a page the app already had.
/// The same applies to a census whose household was fetched by
/// `loadCensusHousehold` and then re-scored from a roster-less search row.
///
/// This is a restore, never a guess: it only ever carries forward a payload the
/// app itself fetched and stored for the SAME record id from the SAME source,
/// and the fresh record always wins where it has a value of its own. Identity
/// (id, name, detail URL) is taken from the fresh row without exception — the
/// FT-12 rule that enrichment must never flip a record's identity.
///
/// Pure and side-effect free so it can be dropped into the persistence choke
/// point (`ProjectDatabase.saveEvidence`, which is the only writer of
/// `record_json` on the run path) without widening its responsibilities.
/// `nonisolated` because the choke point it serves — `ProjectDatabase`, itself
/// a `nonisolated final class` — writes evidence off the main actor. The
/// functions here are pure transforms over value types, so there is nothing to
/// isolate; without this the app target's MainActor-by-default isolation makes
/// them uncallable from the one place they exist to be called.
nonisolated enum EvidenceEnrichmentMerge {

    /// The record that should be written for `fresh`, given whatever is already
    /// stored under the same evidence id. Returns `fresh` unchanged when there
    /// is nothing to preserve, when the ids differ, or when the two records are
    /// of different kinds.
    static func preservingEnrichment(fresh: SourceRecord, stored: SourceRecord?) -> SourceRecord {
        guard let stored, stored.id == fresh.id else { return fresh }
        switch (fresh, stored) {
        case (.parish(let f), .parish(let s)):
            return .parish(mergedParish(fresh: f, stored: s))
        case (.census(let f), .census(let s)):
            return .census(mergedCensus(fresh: f, stored: s))
        default:
            return fresh
        }
    }

    /// A fetched register entry (`detail`, and the flat parent projection it
    /// produced) survives a re-score. A fresh row that somehow carries its own
    /// detail — the top hit of a search is enriched in-run
    /// (`enrichWithDetail(cap: 1)`) — is newer and wins.
    static func mergedParish(fresh: ParishRecord, stored: ParishRecord) -> ParishRecord {
        guard fresh.detail == nil || fresh.fatherName == nil || fresh.motherName == nil,
              stored.detail != nil || stored.fatherName != nil || stored.motherName != nil
        else { return fresh }
        var raw = fresh.common.rawFields
        for (key, value) in stored.common.rawFields where raw[key] == nil {
            raw[key] = value
        }
        let common = RecordCommon(
            id: fresh.common.id,
            sourceID: fresh.common.sourceID,
            name: fresh.common.name,
            surname: fresh.common.surname,
            givenName: fresh.common.givenName,
            detailURL: fresh.common.detailURL ?? stored.common.detailURL,
            rawFields: raw,
            placeARK: fresh.common.placeARK ?? stored.common.placeARK,
            collectionCompleteness: fresh.common.collectionCompleteness
                ?? stored.common.collectionCompleteness,
            volatilityScore: fresh.common.volatilityScore ?? stored.common.volatilityScore)
        return ParishRecord(
            common: common,
            eventType: fresh.eventType ?? stored.eventType,
            eventDate: fresh.eventDate ?? stored.eventDate,
            eventYear: fresh.eventYear ?? stored.eventYear,
            parish: fresh.parish ?? stored.parish,
            county: fresh.county ?? stored.county,
            fatherName: fresh.fatherName ?? stored.fatherName,
            motherName: fresh.motherName ?? stored.motherName,
            detail: fresh.detail ?? stored.detail)
    }

    /// A fetched household roster survives a re-score from a roster-less search
    /// row. An empty array counts as "no roster" — the search path never
    /// invents one, so an empty roster is absence, not a claim that the
    /// schedule listed nobody.
    static func mergedCensus(fresh: CensusRecord, stored: CensusRecord) -> CensusRecord {
        guard (fresh.household ?? []).isEmpty, !(stored.household ?? []).isEmpty else { return fresh }
        var raw = fresh.common.rawFields
        for (key, value) in stored.common.rawFields where raw[key] == nil {
            raw[key] = value
        }
        let common = RecordCommon(
            id: fresh.common.id,
            sourceID: fresh.common.sourceID,
            name: fresh.common.name,
            surname: fresh.common.surname,
            givenName: fresh.common.givenName,
            detailURL: fresh.common.detailURL ?? stored.common.detailURL,
            rawFields: raw,
            placeARK: fresh.common.placeARK ?? stored.common.placeARK,
            collectionCompleteness: fresh.common.collectionCompleteness
                ?? stored.common.collectionCompleteness,
            volatilityScore: fresh.common.volatilityScore ?? stored.common.volatilityScore)
        return CensusRecord(
            common: common,
            censusYear: fresh.censusYear,
            age: fresh.age ?? stored.age,
            birthYear: fresh.birthYear ?? stored.birthYear,
            birthPlace: fresh.birthPlace ?? stored.birthPlace,
            birthCounty: fresh.birthCounty ?? stored.birthCounty,
            relationship: fresh.relationship ?? stored.relationship,
            occupation: fresh.occupation ?? stored.occupation,
            address: fresh.address ?? stored.address,
            parish: fresh.parish ?? stored.parish,
            district: fresh.district ?? stored.district,
            household: stored.household)
    }
}
