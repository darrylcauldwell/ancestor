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

        var spouseByKey: [String: MarriageRecord] = [:]
        for m in spouseSideMarriages {
            guard let key = referenceKey(m) else { continue }
            spouseByKey[key] = m
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
