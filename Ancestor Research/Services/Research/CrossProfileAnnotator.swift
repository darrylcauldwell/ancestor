import Foundation
import AncestorKit

/// #CPC-Change3 — the in-run half of cross-profile corroboration
/// (`CROSS_PROFILE_CORROBORATION_SPEC.md` Change 3).
///
/// Runs pre-scoring, beside `annotateMarriagesWithSamePagePartner`: for each
/// candidate marriage record in the batch, consult every TREE-LINKED
/// SPOUSE's persisted evidence (via an injected lookup — the
/// `childEvidenceMMNLookup` pattern; no DB access here) and, on a unique
/// canonical-reference-key corroboration, stamp the record's
/// `corroborating*` fields so the pure family-context gate — and, from
/// Change 4, the verdict layer — can read them deterministically. The
/// annotation is recomputed on every run from persisted state, which is
/// what makes the eventual elevation re-stomp-proof by construction.
///
/// Decision-11 corpus, stated for surface-independence: the subject side is
/// the CURRENT BATCH plus the subject's own persisted marriage evidence;
/// the partner side is the spouse's persisted evidence. This change moves
/// no verdicts (property-tested): a gate-4 pass affects `wouldApply` only.
nonisolated enum CrossProfileAnnotator {

    struct Outcome {
        let records: [SourceRecord]
        let annotatedCount: Int
        let trace: [String]
    }

    // MARK: - Directed fetch (multi-marriage completion)

    /// One register page to fetch the SUBJECT's own side from.
    struct DirectedFetchTarget: Equatable {
        let volume: String
        let page: String
        let year: Int
        let district: String?
    }

    /// PURE work-list for cross-profile *directed fetch* (the discovery half
    /// of corroboration): the marriage references a TREE-LINKED SPOUSE
    /// already holds but the subject LACKS. Turns corroboration from a JOIN
    /// (connect two existing records) into DISCOVERY (use one spouse's
    /// record to go find the other's) — closing the twice-married-person gap
    /// where a person's second marriage exists only under the spouse who was
    /// researched. The record is not hidden: it is the same-page neighbour
    /// of the spouse's own entry.
    ///
    /// Deduped by (volume, page, year); returns nothing for references the
    /// subject already holds, or spouse records without a keyable vol/page.
    static func directedFetchTargets(
        subjectHeld: [MarriageRecord],
        spouseHeld: [MarriageRecord],
        districtResolver: ((String) -> String?)? = nil
    ) -> [DirectedFetchTarget] {
        let subjectKeys = Set(subjectHeld.compactMap {
            SamePageCouplePairing.canonicalReferenceKey($0, districtResolver: districtResolver)
        })
        var seen = Set<String>()
        var out: [DirectedFetchTarget] = []
        for m in spouseHeld {
            guard let key = SamePageCouplePairing.canonicalReferenceKey(m, districtResolver: districtResolver),
                  !subjectKeys.contains(key),
                  let vol = m.volume?.trimmingCharacters(in: .whitespaces), !vol.isEmpty,
                  let page = m.page?.trimmingCharacters(in: .whitespaces), !page.isEmpty,
                  let year = m.marriageYear
            else { continue }
            let dedup = "\(vol.uppercased())/\(page.uppercased())/\(year)"
            guard seen.insert(dedup).inserted else { continue }
            out.append(.init(volume: vol, page: page, year: year, district: m.district))
        }
        return out
    }

    static func annotate(
        records: [SourceRecord],
        subjectProfileID: String?,
        snapshot: FamilyGraphSnapshot,
        evidenceLookup: ((String) -> [EvidenceRecord])?,
        childMMNLookup: ((String) -> String?)? = nil,
        districtResolver: ((String) -> String?)? = nil
    ) -> Outcome {
        // Lead-subjects and user-input subjects have no profile id — and no
        // tree edges — so the step is a deterministic no-op for them, as is
        // any run built without a database behind the lookup.
        guard let subjectProfileID,
              let subjectProfile = snapshot.profiles[subjectProfileID],
              let evidenceLookup
        else { return Outcome(records: records, annotatedCount: 0, trace: []) }

        let spouseEdges = snapshot.relationships.filter {
            $0.type == .spouse && ($0.from == subjectProfileID || $0.to == subjectProfileID)
        }
        guard !spouseEdges.isEmpty else {
            return Outcome(records: records, annotatedCount: 0, trace: [])
        }

        // Batch marriages needing annotation. Nothing to do → skip the
        // evidence loads entirely.
        var batchIDs = Set<String>()
        var subjectCorpus: [(id: String, record: MarriageRecord)] = []
        for record in records {
            if case .marriage(let m) = record, m.corroboratingSpouseProfileID == nil {
                subjectCorpus.append((id: m.common.id, record: m))
                batchIDs.insert(m.common.id)
            }
        }
        guard !batchIDs.isEmpty else {
            return Outcome(records: records, annotatedCount: 0, trace: [])
        }

        // Subject corpus = batch + subject's own persisted marriage
        // evidence (dedup by id) — the stated Decision-11 ambiguity corpus.
        for row in evidenceLookup(subjectProfileID)
        where row.userStatus != .discarded && row.verdict != .impossible {
            guard case .marriage(let m) = row.record,
                  !batchIDs.contains(row.sourceRecordID) else { continue }
            subjectCorpus.append((id: row.sourceRecordID, record: m))
        }

        var trace: [String] = []
        // recordID → annotation; key → claiming edge count (a key claimed
        // by two edges of this subject refuses all claimants, Decision 11).
        var annotations: [String: (key: String, spouseID: String, spouseRecordID: String,
                                   tier: String, anchor: String)] = [:]
        var edgeCountByKey: [String: Int] = [:]

        for edge in spouseEdges {
            let partnerID = edge.from == subjectProfileID ? edge.to : edge.from
            guard let partnerProfile = snapshot.profiles[partnerID] else { continue }
            let partnerMarriages = evidenceLookup(partnerID)
                .filter { $0.userStatus != .discarded && $0.verdict != .impossible }
                .compactMap { row -> (id: String, record: MarriageRecord)? in
                    guard case .marriage(let m) = row.record else { return nil }
                    return (id: row.sourceRecordID, record: m)
                }
            guard !partnerMarriages.isEmpty else { continue }

            let outcome = SpousePairCorroborator.corroborate(
                subjectMarriages: subjectCorpus,
                partnerMarriages: partnerMarriages,
                subject: CorroborationSweep.pairMember(subjectProfile, snapshot: snapshot),
                partner: CorroborationSweep.pairMember(partnerProfile, snapshot: snapshot),
                childMMNAnchors: childAnchors(
                    subjectID: subjectProfileID, partnerID: partnerID,
                    snapshot: snapshot, childMMNLookup: childMMNLookup),
                edgeID: edge.id.uuidString,
                districtResolver: districtResolver
            )
            guard case .found(let finding) = outcome else {
                if case .none(let reason) = outcome, reason.hasPrefix("near-miss") {
                    trace.append(reason)
                }
                continue
            }

            edgeCountByKey[finding.canonicalKey, default: 0] += 1
            let anchorKind: String = {
                switch finding.anchor {
                case .strong: return "strong"
                case .weak: return "weak"
                case .none: return "none"
                }
            }()
            for recordID in finding.subjectCollapsedRecordIDs where batchIDs.contains(recordID) {
                annotations[recordID] = (
                    key: finding.canonicalKey,
                    spouseID: partnerID,
                    spouseRecordID: finding.partnerRecordID,
                    tier: finding.tier.rawValue,
                    anchor: anchorKind
                )
            }
            trace.append(contentsOf: finding.trace)
        }

        guard !annotations.isEmpty else {
            return Outcome(records: records, annotatedCount: 0, trace: trace)
        }

        var out: [SourceRecord] = []
        out.reserveCapacity(records.count)
        var count = 0
        for record in records {
            guard case .marriage(let m) = record,
                  let a = annotations[m.common.id],
                  edgeCountByKey[a.key] == 1
            else {
                out.append(record)
                continue
            }
            out.append(.marriage(MarriageRecord(
                common: m.common,
                marriageYear: m.marriageYear,
                marriageDate: m.marriageDate,
                marriagePlace: m.marriagePlace,
                quarter: m.quarter,
                district: m.district,
                volume: m.volume,
                page: m.page,
                spouseName: m.spouseName,
                partnerSurnameFromSamePage: m.partnerSurnameFromSamePage,
                corroboratingSpouseProfileID: a.spouseID,
                corroboratingSpouseRecordID: a.spouseRecordID,
                corroborationTier: a.tier,
                corroborationAnchor: a.anchor
            )))
            count += 1
        }
        return Outcome(records: out, annotatedCount: count, trace: trace)
    }

    /// Child anchors for the pair: union of both members' children,
    /// mother's-maiden-name from the child's profile field first, else the
    /// injected evidence lookup (`childEvidenceMMNLookup` — reused, not
    /// duplicated).
    private static func childAnchors(
        subjectID: String, partnerID: String,
        snapshot: FamilyGraphSnapshot,
        childMMNLookup: ((String) -> String?)?
    ) -> [SpousePairCorroborator.ChildMMNAnchor] {
        var seen = Set<String>()
        var anchors: [SpousePairCorroborator.ChildMMNAnchor] = []
        for parentID in [subjectID, partnerID] {
            for child in snapshot.childrenOf(parentID) where seen.insert(child.id).inserted {
                let mmn: String? = {
                    if let field = child.mothersMaidenName, !field.isEmpty { return field }
                    return childMMNLookup?(child.id)
                }()
                guard let mmn else { continue }
                anchors.append(.init(
                    mothersMaidenName: mmn,
                    birthYear: child.birthDate?.earliest
                ))
            }
        }
        return anchors
    }
}
