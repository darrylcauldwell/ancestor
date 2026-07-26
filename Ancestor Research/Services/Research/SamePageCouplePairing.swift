import Foundation

/// Pre-Sep-1912 FreeBMD marriage entries lack the spouse-surname column —
/// the index records each marriage twice (once under the groom, once under
/// the bride) but the "other party" field is blank. The two sides are always
/// registered on the same `(volume, page)` of the same GRO district book,
/// so fetching the spouse-side query separately and pairing on the reference
/// tuple recovers the partner surname deterministically.
///
/// This helper is the pure pairing logic. The pipeline (`ResearchPipeline
/// .annotateMarriagesWithSamePagePartner`) is the I/O side: it dispatches
/// the spouse-side FreeBMD query and then calls `annotate(...)` here. Pure
/// so tests can verify the pairing without spinning up the dispatcher.
///
/// `MarriageEnrichmentEngine` does a conceptually similar grouping for the
/// `.parentMarriage` and `.subjectSpouseMarriage` hypothesis flows, but it
/// operates on `MarriageEntry` (a flattened view tailored to those graders)
/// and joins both surname sides into a fresh outcome enum. This helper is
/// the lighter form: annotate an existing subject-side `MarriageRecord` in
/// place with the recovered partner surname.
nonisolated enum SamePageCouplePairing {

    /// BMD reference key — two marriage entries with the same key are the
    /// same registered marriage. Returns nil when `volume` or `page` is
    /// missing; without them there's no usable pairing axis.
    ///
    /// Year/quarter/district are included because volume + page alone can
    /// collide across years (the BMD index reuses volume codes per year).
    static func referenceKey(_ m: MarriageRecord) -> String? {
        guard let year = m.marriageYear,
              let vol = m.volume?.trimmingCharacters(in: .whitespaces), !vol.isEmpty,
              let page = m.page?.trimmingCharacters(in: .whitespaces), !page.isEmpty
        else { return nil }
        let q = (m.quarter ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        let d = (m.district ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return "\(year)|\(q)|\(d)|\(vol.uppercased())|\(page.uppercased())"
    }

    // MARK: - Canonical key (#CPC-Change1)

    /// Canonical components for CROSS-BATCH joins (cross-profile
    /// corroboration, `CROSS_PROFILE_CORROBORATION_SPEC.md` Decision 2).
    ///
    /// `referenceKey` is safe when both sides come from ONE fetch session;
    /// the two sides of one marriage held by two PROFILES were transcribed
    /// and fetched independently (bride-batch vs groom-batch), where FreeBMD
    /// district strings are transcriber-variant ("Chapel le F." observed in
    /// the wild) and volume/page can carry leading zeros. So the canonical
    /// form additionally: collapses internal whitespace runs, strips leading
    /// zeros from volume/page (mirroring `WitnessIdentity.norm`), and
    /// resolves the district through an injectable canonicaliser — the I/O
    /// halves pass a `FreeBMDDistrictCatalogue` lookup; tests pass fakes;
    /// the corroborator itself stays pure. A resolver that abstains (nil)
    /// falls back to basic normalisation. Same fail-closed contract as
    /// `referenceKey`: nil without year + volume + page.
    static func canonicalComponents(
        _ m: MarriageRecord,
        districtResolver: ((String) -> String?)? = nil
    ) -> (year: Int, quarter: String, district: String, volume: String, page: String)? {
        guard let year = m.marriageYear,
              let vol = canonicalUnit(m.volume),
              let page = canonicalUnit(m.page)
        else { return nil }
        let quarter = basicNorm(m.quarter) ?? ""
        let rawDistrict = basicNorm(m.district) ?? ""
        let district: String
        if rawDistrict.isEmpty {
            district = ""
        } else if let resolved = districtResolver?(rawDistrict).flatMap({ basicNorm($0) }) {
            district = resolved
        } else {
            district = rawDistrict
        }
        return (year, quarter, district, vol, page)
    }

    /// The canonical key string over `canonicalComponents`.
    static func canonicalReferenceKey(
        _ m: MarriageRecord,
        districtResolver: ((String) -> String?)? = nil
    ) -> String? {
        guard let c = canonicalComponents(m, districtResolver: districtResolver) else { return nil }
        return "\(c.year)|\(c.quarter)|\(c.district)|\(c.volume)|\(c.page)"
    }

    /// The district-and-quarter-blind sub-key ("year|volume|page") used for
    /// NEAR-MISS diagnostics: two records agreeing here while their full
    /// canonical keys differ are surfaced for observation, never auto-joined.
    static func canonicalPageKey(
        _ m: MarriageRecord,
        districtResolver: ((String) -> String?)? = nil
    ) -> String? {
        guard let c = canonicalComponents(m, districtResolver: districtResolver) else { return nil }
        return "\(c.year)|\(c.volume)|\(c.page)"
    }

    /// Uppercase, trim, collapse internal whitespace runs. nil for empty.
    private static func basicNorm(_ s: String?) -> String? {
        guard let s else { return nil }
        let collapsed = s.uppercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// `basicNorm` + leading-zero strip (à la `WitnessIdentity.norm`) for
    /// volume/page units.
    private static func canonicalUnit(_ s: String?) -> String? {
        guard let n = basicNorm(s) else { return nil }
        let stripped = String(n.drop(while: { $0 == "0" }))
        return stripped.isEmpty ? nil : stripped
    }

    /// Annotate subject-side marriage records with `partnerSurnameFromSamePage`
    /// recovered from same-page spouse-side entries. Records that don't have a
    /// reference key (vol/page missing), don't have a same-page pair, or
    /// already carry a `partnerSurnameFromSamePage` are left untouched.
    ///
    /// Non-marriage records pass through unchanged. Pure function; no I/O.
    static func annotate(
        subjectSideRecords records: [SourceRecord],
        spouseSideMarriages: [MarriageRecord]
    ) -> (annotated: [SourceRecord], pairCount: Int) {
        guard !spouseSideMarriages.isEmpty else { return (records, 0) }

        // Group spouse-side entries by key, then COLLAPSE duplication before
        // judging ambiguity (#CPC-Change1, spec Decision 13). Duplicates at
        // one key are the NORMAL case: the pipeline feeds this from two
        // fetch paths (page lookup + surname sweep) with no cross-path
        // dedup, and FreeBMD holds multiple volunteer transcriptions of one
        // index line under distinct row ids. Only the partner SURNAME is
        // consumed downstream, so entries agreeing on surname collapse to
        // one representative; distinct surnames at one key are a genuine
        // ambiguity — which entry is the partner? — and drop the key
        // entirely (when in doubt, split). The previous dict build was
        // last-write-wins: benign for identical duplicates, silent on
        // conflicts.
        var grouped: [String: [MarriageRecord]] = [:]
        for m in spouseSideMarriages {
            guard let key = referenceKey(m) else { continue }
            grouped[key, default: []].append(m)
        }
        var spouseByKey: [String: MarriageRecord] = [:]
        for (key, entries) in grouped {
            var seenIDs = Set<String>()
            var unique: [MarriageRecord] = []
            for e in entries where seenIDs.insert(e.common.id).inserted {
                unique.append(e)
            }
            let surnames = Set(unique.compactMap {
                $0.common.surname?.trimmingCharacters(in: .whitespaces).uppercased()
            }.filter { !$0.isEmpty })
            guard surnames.count == 1, let surname = surnames.first else { continue }
            spouseByKey[key] = unique.first {
                $0.common.surname?.trimmingCharacters(in: .whitespaces).uppercased() == surname
            }
        }
        guard !spouseByKey.isEmpty else { return (records, 0) }

        var out: [SourceRecord] = []
        out.reserveCapacity(records.count)
        var pairCount = 0
        for rec in records {
            guard case .marriage(let m) = rec,
                  m.partnerSurnameFromSamePage == nil,
                  let key = referenceKey(m),
                  let partner = spouseByKey[key],
                  let partnerSurname = partner.common.surname?
                    .trimmingCharacters(in: .whitespaces),
                  !partnerSurname.isEmpty
            else {
                out.append(rec)
                continue
            }
            let updated = MarriageRecord(
                common: m.common,
                marriageYear: m.marriageYear,
                marriageDate: m.marriageDate,
                marriagePlace: m.marriagePlace,
                quarter: m.quarter,
                district: m.district,
                volume: m.volume,
                page: m.page,
                spouseName: m.spouseName,
                partnerSurnameFromSamePage: partnerSurname
            )
            out.append(.marriage(updated))
            pairCount += 1
        }
        return (out, pairCount)
    }
}
