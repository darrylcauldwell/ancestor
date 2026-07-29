import Foundation

/// A formatted citation following Evidence Explained conventions.
nonisolated struct RenderedCitation: Sendable {
    let full: String        // Full citation for notes
    let short: String       // Short form for subsequent references
    let url: String?        // Direct link if available
    let accessedAt: Date    // When the record was retrieved
    let sourceID: String    // Which source produced this

    var accessedString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: accessedAt)
    }
}

/// Renders citations from raw record fields per source.
/// Each source has its own citation format following Evidence Explained.
nonisolated struct CitationRenderer {

    /// Render a citation for a source record.
    static func cite(_ record: SourceRecord, accessedAt: Date = Date()) -> RenderedCitation {
        // FamilySearch feeds every record type, but the per-type templates
        // below cite each type's ORIGINAL provider (FreeBMD/GRO, FreeCen,
        // Find a Grave, CWGC…). A citation must name the repository the
        // record actually came from — dispatch on source before type.
        if record.sourceID == "familysearch" {
            return citeFamilySearch(record, accessedAt: accessedAt)
        }
        switch record {
        case .birth(let r):
            return citeBMDRecord(
                type: "Birth", common: r.common,
                year: r.birthYear, quarter: r.quarter,
                district: r.district, volume: r.volume, page: r.page,
                accessedAt: accessedAt
            )
        case .death(let r):
            return citeBMDRecord(
                type: "Death", common: r.common,
                year: r.deathYear, quarter: r.quarter,
                district: r.district, volume: r.volume, page: r.page,
                accessedAt: accessedAt
            )
        case .marriage(let r):
            return citeBMDRecord(
                type: "Marriage", common: r.common,
                year: r.marriageYear, quarter: r.quarter,
                district: r.district, volume: r.volume, page: r.page,
                accessedAt: accessedAt
            )
        case .census(let r):
            return citeCensus(r, accessedAt: accessedAt)
        case .burial(let r):
            return citeBurial(r, accessedAt: accessedAt)
        case .military(let r):
            return citeMilitary(r, accessedAt: accessedAt)
        case .probate(let r):
            return citeProbate(r, accessedAt: accessedAt)
        case .parish(let r):
            return citeParish(r, accessedAt: accessedAt)
        case .pedigree(let r):
            return citePedigree(r, accessedAt: accessedAt)
        }
    }

    // MARK: - FamilySearch (any record type)

    /// FS records carry their collection identity in rawFields — cite that
    /// plus the ark, never another provider's template.
    private static func citeFamilySearch(_ record: SourceRecord, accessedAt: Date) -> RenderedCitation {
        let common = record.common
        let name = common.name
            ?? [common.givenName, common.surname].compactMap { $0 }.joined(separator: " ")
        let year = eventYear(of: record).map(String.init)
        let ark = common.rawFields["ark"] ?? common.detailURL

        // FS sourceTitles often read: Entry for John Ayre, "England,
        // Northumberland, Parish Registers, 1538-1950" — the quoted
        // segment is the collection proper.
        var collection = common.rawFields["collection.title"]
        if let raw = collection,
           let q1 = raw.firstIndex(of: "\""), let q2 = raw.lastIndex(of: "\""), q1 < q2 {
            collection = String(raw[raw.index(after: q1)..<q2])
        }

        var full = collection.map { "\"\($0),\" " } ?? ""
        full += "FamilySearch (\(ark ?? "https://www.familysearch.org")), \(name)"
        if let year { full += ", \(year)" }
        full += "; accessed \(formatDate(accessedAt))."

        let short = "FamilySearch: \(name)" + (year.map { ", \($0)" } ?? "")

        return RenderedCitation(
            full: full, short: short,
            url: ark,
            accessedAt: accessedAt,
            sourceID: common.sourceID
        )
    }

    /// The record's own event year — the date a citation should carry.
    private static func eventYear(of record: SourceRecord) -> Int? {
        switch record {
        case .birth(let r): r.birthYear
        case .death(let r): r.deathYear
        case .marriage(let r): r.marriageYear
        case .census(let r): r.censusYear
        case .burial(let r): r.deathYear ?? r.birthYear
        case .military(let r): r.deathYear
        case .probate(let r): r.deathYear
        case .parish(let r): r.eventYear
        case .pedigree(let r): r.birthYear ?? r.deathYear
        }
    }

    // MARK: - FreeBMD (Birth/Death/Marriage)

    private static func citeBMDRecord(
        type: String, common: RecordCommon,
        year: Int?, quarter: String?,
        district: String?, volume: String?, page: String?,
        accessedAt: Date
    ) -> RenderedCitation {
        let name = [common.givenName, common.surname].compactMap { $0 }.joined(separator: " ")
        let yearStr = year.map(String.init) ?? "?"
        let qStr = quarter ?? ""
        let loc = district ?? ""
        let ref = [volume, page].compactMap { $0 }.joined(separator: "/")

        let full: String
        if common.sourceID == "freebmd" {
            full = "\"England & Wales, Civil Registration \(type) Index, \(yearStr),\" " +
                   "FreeBMD (https://www.freebmd.org.uk), " +
                   "\(name), \(qStr) \(yearStr), \(loc)" +
                   (ref.isEmpty ? "" : ", vol. \(ref)") +
                   "; accessed \(formatDate(accessedAt))."
        } else {
            full = "England & Wales, GRO \(type) Index, \(yearStr), " +
                   "\(name), \(qStr) \(yearStr), \(loc)" +
                   (ref.isEmpty ? "" : ", vol. \(ref)") + "."
        }

        let short = "\(type): \(name), \(qStr) \(yearStr), \(loc)"

        return RenderedCitation(
            full: full, short: short,
            url: common.detailURL,
            accessedAt: accessedAt,
            sourceID: common.sourceID
        )
    }

    // MARK: - FreeCen (Census)

    private static func citeCensus(_ r: CensusRecord, accessedAt: Date) -> RenderedCitation {
        let name = r.common.name ?? [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
        let parish = r.parish ?? r.district ?? ""
        let birthPlace = r.birthPlace ?? ""

        let full = "\"\(r.censusYear) England Census,\" " +
                   "FreeCen (https://www.freecen.org.uk), " +
                   "\(name), age \(r.age.map(String.init) ?? "?"), " +
                   "\(parish), born \(birthPlace)" +
                   "; accessed \(formatDate(accessedAt))."

        let short = "Census \(r.censusYear): \(name), \(parish)"

        return RenderedCitation(
            full: full, short: short,
            url: r.common.detailURL,
            accessedAt: accessedAt,
            sourceID: r.common.sourceID
        )
    }

    // MARK: - Find a Grave (Burial)

    private static func citeBurial(_ r: BurialRecord, accessedAt: Date) -> RenderedCitation {
        let name = r.common.name ?? [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
        let cemetery = r.cemetery ?? ""
        let location = r.burialLocation ?? ""

        let full = "Find a Grave, database and images " +
                   "(https://www.findagrave.com), memorial \(r.memorialID.map(String.init) ?? "?"), " +
                   "\(name), \(cemetery), \(location)" +
                   "; accessed \(formatDate(accessedAt))."

        let short = "Find a Grave: \(name), \(cemetery)"

        return RenderedCitation(
            full: full, short: short,
            url: r.common.detailURL,
            accessedAt: accessedAt,
            sourceID: r.common.sourceID
        )
    }

    // MARK: - CWGC (Military)

    private static func citeMilitary(_ r: MilitaryRecord, accessedAt: Date) -> RenderedCitation {
        let name = r.common.name ?? [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
        let regiment = r.regiment ?? ""
        let rank = r.rank ?? ""
        let dod = r.dateOfDeath ?? ""

        let full = "Commonwealth War Graves Commission, " +
                   "Casualty Details (https://www.cwgc.org), " +
                   "\(rank) \(name), \(regiment), died \(dod)" +
                   "; accessed \(formatDate(accessedAt))."

        let short = "CWGC: \(rank) \(name), \(regiment)"

        return RenderedCitation(
            full: full, short: short,
            url: r.common.detailURL,
            accessedAt: accessedAt,
            sourceID: r.common.sourceID
        )
    }

    // MARK: - Probate

    private static func citeProbate(_ r: ProbateRecord, accessedAt: Date) -> RenderedCitation {
        let name = r.common.name ?? [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
        let grantType = r.grantType ?? "Probate"
        let date = r.probateDate ?? ""

        let full = "England & Wales, National Probate Calendar, " +
                   "\(name), \(grantType) \(date)" +
                   (r.address.map { ", \($0)" } ?? "") + "."

        let short = "\(grantType): \(name), \(date)"

        return RenderedCitation(
            full: full, short: short,
            url: r.common.detailURL,
            accessedAt: accessedAt,
            sourceID: r.common.sourceID
        )
    }

    // MARK: - Parish

    private static func citeParish(_ r: ParishRecord, accessedAt: Date) -> RenderedCitation {
        let name = r.common.name ?? [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
        let event = r.eventType ?? "record"
        let parish = r.parish ?? ""
        let year = r.eventYear.map(String.init) ?? "?"

        // Register/archive reference from the typed detail when present —
        // church + register type + film locate the ORIGINAL page, which is
        // what a citation is for.
        var reference = ""
        if let register = r.detail?.register {
            let parts = [
                r.detail?.churchName,
                register.registerType,
                register.registerEntryNumber.map { "entry \($0)" },
                register.film.map { "film \($0)" },
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { reference = " (\(parts.joined(separator: ", ")))" }
        }

        // Transcriber attribution (FREEREG_INTEGRATION_SPEC §2/§3.1):
        // FreeREG's value IS the volunteers' transcription work — credit
        // them on the citation whenever the record carries the credit.
        var attribution = ""
        if let provenance = r.detail?.provenance {
            let credit = provenance.credit ?? provenance.transcribedBy
            if let credit, !credit.isEmpty {
                attribution = " Transcription credit: \(credit)."
            }
        }

        let full = "\(parish) Parish Register, \(event) of \(name), \(year)\(reference).\(attribution)"
        let short = "Parish: \(name), \(event) \(year)"

        return RenderedCitation(
            full: full, short: short,
            url: r.common.detailURL,
            accessedAt: accessedAt,
            sourceID: r.common.sourceID
        )
    }

    // MARK: - Pedigree

    private static func citePedigree(_ r: PedigreeRecord, accessedAt: Date) -> RenderedCitation {
        let name = r.common.name ?? [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
        let location = r.location ?? ""

        let full = "Pedigree resource, \(name), \(location)."
        let short = "Pedigree: \(name)"

        return RenderedCitation(
            full: full, short: short,
            url: r.common.detailURL,
            accessedAt: accessedAt,
            sourceID: r.common.sourceID
        )
    }

    // MARK: - Helpers

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
