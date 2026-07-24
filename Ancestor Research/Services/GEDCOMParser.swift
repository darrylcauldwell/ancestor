import Foundation

/// Parses GEDCOM 5.5.1 and 7.0 files into a FamilyGraphSnapshot.
/// Custom implementation for full control over edge cases from
/// different exporters (Ancestry, WikiTree, FindMyPast, MyHeritage).
///
/// 7.0 is a near-superset of what we already read for INDI/FAM/SOUR — the
/// only material differences this parser handles are:
///   - detecting the `2 VERS 7.0` declaration in the header
///   - tolerating top-level `0 @M{n}@ OBJE` records (skipped — attachments
///     come from the project DB or GEDZip extraction, not from inline OBJE)
///   - tolerating `1 OBJE @M{n}@` references inside INDI (skipped)
nonisolated struct GEDCOMParser {

    struct ParseResult {
        let snapshot: FamilyGraphSnapshot
        let warnings: [String]
        let individualCount: Int
        let familyCount: Int
        /// Version detected from the file's header. Defaults to `.v5_5_1`
        /// when the header is missing or malformed.
        let version: GEDCOMVersion
    }

    /// Parse a GEDCOM file at the given path.
    static func parse(fileAt path: String) throws -> ParseResult {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return parse(content: content)
    }

    /// Parse GEDCOM content string.
    static func parse(content: String) -> ParseResult {
        let lines = content.components(separatedBy: .newlines)
        let records = splitIntoRecords(lines)
        var warnings: [String] = []

        // Detect spec version from the HEAD record. Look for `2 VERS x.y`
        // immediately under `1 GEDC`. Defaults to 5.5.1 when missing.
        let version = detectVersion(records: records)

        // Build the REPO and SOUR lookup tables before walking individuals.
        // INDI events reference SOUR records via `2 SOUR @Sn@`, and SOUR
        // records reference REPO records via `1 REPO @Rn@`.
        let repos = buildRepositoryLookup(records: records)
        let sources = buildSourceLookup(records: records, repositories: repos)

        // M16.2 — multimedia warning. Plain `.ged` carries metadata only;
        // the actual files live alongside the document and are not bundled.
        // Count both top-level OBJE records and inline `1 OBJE @Mn@` refs
        // so users see one number that matches what they'd lose.
        let objeCount = countMultimediaReferences(records: records)
        if objeCount > 0 {
            warnings.append(
                "Found \(objeCount) multimedia references but plain GEDCOM doesn't carry the files. Use .gdz to bundle media, or import the original photos separately."
            )
        }

        // Phase 1: Parse individuals. 7.0 inputs may carry top-level
        // `0 @M{n}@ OBJE` records — skip them silently; attachment
        // metadata enters our model via the project DB / GEDZip
        // extraction, not via inline OBJE.
        var profiles: [String: Profile] = [:]
        var indiCount = 0
        for record in records where record.tag == "INDI" {
            indiCount += 1
            let profile = parseIndividual(record, sources: sources, warnings: &warnings)
            profiles[profile.id] = profile
        }

        // Phase 2: Parse families → relationships
        var relationships: [Relationship] = []
        var famCount = 0
        for record in records where record.tag == "FAM" {
            famCount += 1
            let rels = parseFamily(record, profiles: profiles, warnings: &warnings)
            relationships.append(contentsOf: rels)
        }

        let snapshot = FamilyGraphSnapshot(profiles: profiles, relationships: relationships)
        return ParseResult(
            snapshot: snapshot,
            warnings: warnings,
            individualCount: indiCount,
            familyCount: famCount,
            version: version
        )
    }

    // MARK: - Source / Repository Lookups

    /// Pre-decoded `0 @S{n}@ SOUR` record — every field that may be needed
    /// when reconstructing a `Citation` for an inline `2 SOUR @S{n}@` ref
    /// inside an INDI event.
    private struct SOURRecord {
        let xref: String
        let title: String?
        let collection: String?
        let repository: String?
        let url: String?
        let notes: String?
        let dateAccessed: Date?
    }

    /// Build `[xref → repository name]` from top-level `0 @R{n}@ REPO`
    /// records. Repositories carry a `1 NAME` (sometimes `1 ADDR`); we
    /// only keep the name today since `Citation.repository` is a single
    /// freeform string.
    private static func buildRepositoryLookup(records: [GEDCOMRecord]) -> [String: String] {
        var out: [String: String] = [:]
        for record in records where record.tag == "REPO" {
            guard let xref = record.xref else { continue }
            for line in record.children where line.tag == "NAME" {
                if let name = line.value, !name.isEmpty {
                    out[xref] = name
                    break
                }
            }
        }
        return out
    }

    /// Build `[xref → SOURRecord]` from top-level `0 @S{n}@ SOUR` records.
    /// Repository references resolve via the supplied `repositories` map.
    private static func buildSourceLookup(
        records: [GEDCOMRecord],
        repositories: [String: String]
    ) -> [String: SOURRecord] {
        var out: [String: SOURRecord] = [:]
        for record in records where record.tag == "SOUR" {
            guard let xref = record.xref else { continue }
            var title: String?
            var collection: String?
            var repository: String?
            var url: String?
            var notes: String?
            var dateAccessed: Date?

            var i = 0
            while i < record.children.count {
                let line = record.children[i]
                if line.level == 1 {
                    switch line.tag {
                    case "TITL":
                        title = collectText(of: i, in: record.children, primary: line.value)
                    case "ABBR":
                        // Exporter writes `1 ABBR <collection>`. Treat ABBR
                        // as the collection identifier for round-trips.
                        collection = collectText(of: i, in: record.children, primary: line.value)
                    case "REPO":
                        // `1 REPO @Rn@` — resolve via the repository table.
                        // Some GEDCOMs put a freeform string after REPO
                        // instead of an xref; honour either form.
                        if let v = line.value, v.hasPrefix("@"), v.hasSuffix("@") {
                            repository = repositories[v]
                        } else if let v = line.value, !v.isEmpty {
                            repository = v
                        }
                    case "PUBL":
                        // Exporter encodes repository as PUBL since we
                        // don't emit REPO records today. Fall back to PUBL
                        // when no REPO ref produced a name.
                        if repository == nil {
                            repository = collectText(of: i, in: record.children, primary: line.value)
                        }
                    case "AUTH":
                        // Authors are not modelled on Citation; preserve
                        // them in `notes` so they round-trip back out.
                        if let v = collectText(of: i, in: record.children, primary: line.value),
                           !v.isEmpty {
                            notes = (notes.map { $0 + "\n" } ?? "") + "Author: \(v)"
                        }
                    case "_URL":
                        url = collectText(of: i, in: record.children, primary: line.value)
                    case "NOTE":
                        let body = collectText(of: i, in: record.children, primary: line.value) ?? ""
                        notes = notes.map { $0 + "\n" + body } ?? body
                    case "DATE":
                        if let raw = line.value {
                            dateAccessed = parseGEDCOMDate(raw)
                        }
                    default: break
                    }
                }
                i += 1
            }

            out[xref] = SOURRecord(
                xref: xref,
                title: title,
                collection: collection,
                repository: repository,
                url: url,
                notes: notes,
                dateAccessed: dateAccessed
            )
        }
        return out
    }

    /// Combine `1 TAG value` with any immediately-following `2 CONT` /
    /// `2 CONC` continuation lines so multi-line values round-trip cleanly.
    /// Returns nil when no text accumulates (so empty values stay nil).
    private static func collectText(
        of index: Int,
        in lines: [GEDCOMLine],
        primary: String?
    ) -> String? {
        var out = primary ?? ""
        let parentLevel = lines[index].level
        var j = index + 1
        while j < lines.count && lines[j].level > parentLevel {
            let sub = lines[j]
            if sub.level == parentLevel + 1 {
                if sub.tag == "CONT" {
                    out += "\n" + (sub.value ?? "")
                } else if sub.tag == "CONC" {
                    out += sub.value ?? ""
                }
            }
            j += 1
        }
        return out.isEmpty ? nil : out
    }

    /// Parse a GEDCOM date value into a `Date`. Used for `1 DATE` on SOUR
    /// records (citation access dates). Returns nil when the format isn't
    /// the canonical `D MMM YYYY` exporter shape — date fields on profiles
    /// use `GenealogicalDate` instead and don't go through here.
    private static func parseGEDCOMDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    /// Count `0 @M{n}@ OBJE` records plus inline `1 OBJE @M{n}@` references
    /// inside INDI records. Used by the M16.2 plain-`.ged` warning so the
    /// number reported to the user reflects what they'd lose.
    private static func countMultimediaReferences(records: [GEDCOMRecord]) -> Int {
        var count = 0
        for record in records {
            if record.tag == "OBJE" { count += 1 }
            if record.tag == "INDI" {
                for line in record.children where line.level == 1 && line.tag == "OBJE" {
                    count += 1
                }
            }
        }
        return count
    }

    /// Walk the HEAD record looking for `1 GEDC / 2 VERS x.y`. Returns
    /// `.v7_0` when the version string starts with "7.", otherwise
    /// defaults to `.v5_5_1` (the legacy interchange format).
    private static func detectVersion(records: [GEDCOMRecord]) -> GEDCOMVersion {
        guard let head = records.first(where: { $0.tag == "HEAD" }) else {
            return .v5_5_1
        }
        var i = 0
        while i < head.children.count {
            let line = head.children[i]
            if line.level == 1 && line.tag == "GEDC" {
                let subs = subordinates(of: i, in: head.children)
                for sub in subs where sub.tag == "VERS" {
                    if let raw = sub.value?.trimmingCharacters(in: .whitespaces),
                       raw.hasPrefix("7.") {
                        return .v7_0
                    }
                    return .v5_5_1
                }
            }
            i += 1
        }
        return .v5_5_1
    }

    // MARK: - Line Parsing

    /// A parsed GEDCOM line: level, optional xref, tag, optional value.
    private struct GEDCOMLine {
        let level: Int
        let xref: String?
        let tag: String
        let value: String?
    }

    /// A top-level record (level 0) with its child lines.
    private struct GEDCOMRecord {
        let xref: String?
        let tag: String
        let children: [GEDCOMLine]
    }

    /// Split raw lines into level-0 records.
    private static func splitIntoRecords(_ lines: [String]) -> [GEDCOMRecord] {
        var records: [GEDCOMRecord] = []
        var currentLines: [GEDCOMLine] = []
        var currentXref: String?
        var currentTag: String?

        for rawLine in lines {
            guard let parsed = parseLine(rawLine) else { continue }

            if parsed.level == 0 {
                // Flush previous record
                if let tag = currentTag {
                    records.append(GEDCOMRecord(
                        xref: currentXref, tag: tag, children: currentLines
                    ))
                }
                currentXref = parsed.xref
                currentTag = parsed.tag
                currentLines = []
            } else {
                currentLines.append(parsed)
            }
        }

        // Flush last record
        if let tag = currentTag {
            records.append(GEDCOMRecord(
                xref: currentXref, tag: tag, children: currentLines
            ))
        }

        return records
    }

    /// Parse a single GEDCOM line.
    /// Format: LEVEL [XREF] TAG [VALUE]
    /// Examples:
    ///   0 @I123@ INDI
    ///   1 NAME John /Smith/
    ///   2 DATE 1 JAN 1887
    private static func parseLine(_ raw: String) -> GEDCOMLine? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard let level = Int(parts[0]), parts.count >= 2 else { return nil }

        if parts.count >= 2 && parts[1].hasPrefix("@") && parts[1].hasSuffix("@") {
            // Has xref: "0 @I123@ INDI"
            let xref = parts[1]
            let tag = parts.count >= 3 ? parts[2].components(separatedBy: " ").first ?? parts[2] : ""
            return GEDCOMLine(level: level, xref: xref, tag: tag, value: nil)
        } else {
            // No xref: "1 NAME John /Smith/"
            let tag = parts[1]
            let value = parts.count >= 3 ? parts[2] : nil
            return GEDCOMLine(level: level, xref: nil, tag: tag, value: value)
        }
    }

    // MARK: - Individual Parsing

    private static func parseIndividual(
        _ record: GEDCOMRecord,
        sources sourceLookup: [String: SOURRecord],
        warnings: inout [String]
    ) -> Profile {
        let id = record.xref ?? UUID().uuidString
        var firstName: String?
        var lastName: String?
        var gender: Gender?
        var birthDate: GenealogicalDate?
        var birthLocation: String?
        var deathDate: GenealogicalDate?
        var deathLocation: String?

        var sources: [ProfileField: [FieldSource]] = [:]
        let now = Date()

        var i = 0
        while i < record.children.count {
            let line = record.children[i]

            switch line.tag {
            case "NAME":
                // Parse "John /Smith/" format
                if let nameValue = line.value {
                    let parsed = parseGEDCOMName(nameValue)
                    firstName = parsed.given
                    lastName = parsed.surname
                }
                // Check for subordinate GIVN/SURN which override
                let subs = subordinates(of: i, in: record.children)
                for sub in subs {
                    if sub.tag == "GIVN", let v = sub.value { firstName = v }
                    if sub.tag == "SURN", let v = sub.value { lastName = v }
                }

            case "SEX":
                if let v = line.value {
                    switch v.uppercased() {
                    case "M": gender = .male
                    case "F": gender = .female
                    default: gender = .unknown
                    }
                }

            case "BIRT":
                // Resolve the best citation once for this event so date and
                // location field sources both reference the same SOUR.
                let eventCitation = bestCitation(
                    forEventAt: i,
                    in: record.children,
                    sourceLookup: sourceLookup,
                    warnings: &warnings
                )
                let subs = subordinates(of: i, in: record.children)
                for sub in subs {
                    if sub.level == 2 && sub.tag == "DATE", let v = sub.value {
                        birthDate = GenealogicalDate(parsing: v)
                        sources[.birthDate, default: []].append(
                            FieldSource(
                                origin: .gedcom, raw: v, addedAt: now,
                                citation: eventCitation?.citation,
                                quality: eventCitation?.quality
                            )
                        )
                    }
                    if sub.level == 2 && sub.tag == "PLAC", let v = sub.value {
                        birthLocation = v
                        sources[.birthLocation, default: []].append(
                            FieldSource(
                                origin: .gedcom, raw: v, addedAt: now,
                                citation: eventCitation?.citation,
                                quality: eventCitation?.quality
                            )
                        )
                    }
                }

            case "DEAT":
                let eventCitation = bestCitation(
                    forEventAt: i,
                    in: record.children,
                    sourceLookup: sourceLookup,
                    warnings: &warnings
                )
                let subs = subordinates(of: i, in: record.children)
                for sub in subs {
                    if sub.level == 2 && sub.tag == "DATE", let v = sub.value {
                        deathDate = GenealogicalDate(parsing: v)
                        sources[.deathDate, default: []].append(
                            FieldSource(
                                origin: .gedcom, raw: v, addedAt: now,
                                citation: eventCitation?.citation,
                                quality: eventCitation?.quality
                            )
                        )
                    }
                    if sub.level == 2 && sub.tag == "PLAC", let v = sub.value {
                        deathLocation = v
                        sources[.deathLocation, default: []].append(
                            FieldSource(
                                origin: .gedcom, raw: v, addedAt: now,
                                citation: eventCitation?.citation,
                                quality: eventCitation?.quality
                            )
                        )
                    }
                }

            default:
                break
            }

            i += 1
        }

        // Split a multi-token given string into a first name + middle name(s).
        // GEDCOM keeps all forenames in one field — the pre-surname NAME
        // segment or the GIVN tag — with no separate middle-name tag, so a name
        // like "Lilian Mary" imports as a single given string. Convention: the
        // first token is the given name, the remainder are middle name(s).
        // Storing them in the distinct firstName/middleName fields keeps the
        // data faithful to how the app models names, and lets the middle-name
        // scorer guard fire on imported profiles directly rather than relying on
        // RecordScorer's runtime compensation split.
        var middleName: String?
        if let fn = firstName {
            let tokens = fn.split(separator: " ").map(String.init)
            if tokens.count >= 2 {
                firstName = tokens.first
                middleName = tokens.dropFirst().joined(separator: " ")
            }
        }

        if let fn = firstName {
            sources[.firstName, default: []].append(
                FieldSource(origin: .gedcom, raw: fn, addedAt: now)
            )
        }
        if let mn = middleName {
            sources[.middleName, default: []].append(
                FieldSource(origin: .gedcom, raw: mn, addedAt: now)
            )
        }
        if let ln = lastName {
            sources[.lastName, default: []].append(
                FieldSource(origin: .gedcom, raw: ln, addedAt: now)
            )
        }

        return Profile(
            id: id,
            externalIDs: ["gedcom": id],
            firstName: firstName,
            middleName: middleName,
            lastName: lastName,
            gender: gender,
            attributes: nil,
            birthDate: birthDate,
            birthLocation: birthLocation,
            deathDate: deathDate,
            deathLocation: deathLocation,
            bio: nil,
            isDeleted: false,
            sources: sources,
            disputes: [:]
        )
    }

    // MARK: - Citation Resolution

    /// Resolved citation + quality for an event, or nil when the event has
    /// no usable SOUR refs.
    private struct ResolvedCitation {
        let citation: Citation
        let quality: EvidenceQuality?
    }

    /// Walk an event's `2 SOUR @S{n}@` children at index `eventIndex` and
    /// pick the highest-quality resolved citation. Ties go to the
    /// first-encountered ref (source order). Dangling references emit a
    /// warning but don't crash.
    ///
    /// `eventIndex` points at the level-1 line (BIRT/DEAT/etc.) inside
    /// `lines` (which is `record.children` for the surrounding INDI).
    private static func bestCitation(
        forEventAt eventIndex: Int,
        in lines: [GEDCOMLine],
        sourceLookup: [String: SOURRecord],
        warnings: inout [String]
    ) -> ResolvedCitation? {
        guard eventIndex < lines.count else { return nil }
        let eventLevel = lines[eventIndex].level

        var best: (resolved: ResolvedCitation, qualityRank: Int, order: Int)?

        var j = eventIndex + 1
        var order = 0
        while j < lines.count && lines[j].level > eventLevel {
            let sub = lines[j]
            // Inline `2 SOUR @S1@` — `parseLine` parks the xref in `value`.
            if sub.level == eventLevel + 1, sub.tag == "SOUR",
               let value = sub.value, value.hasPrefix("@"), value.hasSuffix("@") {

                let xref = value
                guard let sourRecord = sourceLookup[xref] else {
                    // M16.1 — dangling reference. Skip without crashing.
                    warnings.append("Citation reference \(xref) not found in SOUR records")
                    j += 1
                    order += 1
                    continue
                }

                // Read inline `3 PAGE` and `3 QUAY` from the SOUR ref's
                // own subordinates (not the event's, since multiple SOURs
                // can sit under one event with different PAGE/QUAY each).
                var page: String?
                var quality: EvidenceQuality?
                let sourSubs = subordinates(of: j, in: lines)
                for ss in sourSubs where ss.level == eventLevel + 2 {
                    if ss.tag == "PAGE" {
                        page = collectText(of: indexOf(ss, after: j, in: lines) ?? j, in: lines, primary: ss.value)
                    }
                    if ss.tag == "QUAY", let raw = ss.value, let v = Int(raw),
                       let q = EvidenceQuality(rawValue: v) {
                        quality = q
                    }
                }

                let citation = buildCitation(from: sourRecord, page: page)
                let rank = quality?.rawValue ?? -1
                if best == nil || rank > best!.qualityRank {
                    best = (
                        ResolvedCitation(citation: citation, quality: quality),
                        rank,
                        order
                    )
                }
                order += 1
            }
            j += 1
        }

        return best?.resolved
    }

    /// Locate the absolute index of `target` in `lines` starting at `from`.
    /// Used because `subordinates(of:in:)` returns line copies — to fetch
    /// the indexed `collectText` for that copy we need its position back.
    /// Returns nil when not found (treat the caller's fallback as authoritative).
    private static func indexOf(
        _ target: GEDCOMLine,
        after from: Int,
        in lines: [GEDCOMLine]
    ) -> Int? {
        var k = from + 1
        while k < lines.count {
            let l = lines[k]
            if l.level == target.level && l.tag == target.tag && l.value == target.value {
                return k
            }
            k += 1
        }
        return nil
    }

    /// Reconstruct a `Citation` from a pre-decoded SOUR record plus the
    /// inline `3 PAGE` text that lived on the event reference. The PAGE
    /// string was assembled by the exporter as `page, collection,
    /// repository`; we strip trailing chunks that match the SOUR record's
    /// collection or repository so re-export is byte-identical.
    private static func buildCitation(
        from record: SOURRecord,
        page rawPage: String?
    ) -> Citation {
        let strippedPage: String?
        if let raw = rawPage, !raw.isEmpty {
            var parts = raw.components(separatedBy: ", ")
            // Pop trailing parts that match repository or collection.
            while let last = parts.last {
                if last == record.repository || last == record.collection {
                    parts.removeLast()
                } else {
                    break
                }
            }
            let joined = parts.joined(separator: ", ")
            strippedPage = joined.isEmpty ? nil : joined
        } else {
            strippedPage = nil
        }

        // The exporter falls back to the URL when no other locator parts
        // are present. Avoid double-storing in that case.
        let pageOut: String?
        if let p = strippedPage, p == record.url {
            pageOut = nil
        } else {
            pageOut = strippedPage
        }

        return Citation(
            repository: record.repository,
            collection: record.collection,
            title: record.title,
            page: pageOut,
            url: record.url,
            dateAccessed: record.dateAccessed,
            notes: record.notes
        )
    }

    /// Parse GEDCOM name format: "Given Names /Surname/"
    private static func parseGEDCOMName(_ raw: String) -> (given: String?, surname: String?) {
        // Extract surname from between slashes
        let parts = raw.components(separatedBy: "/")
        let given = parts[0].trimmingCharacters(in: .whitespaces)
        let surname: String?
        if parts.count >= 2 {
            let s = parts[1].trimmingCharacters(in: .whitespaces)
            surname = s.isEmpty ? nil : s
        } else {
            surname = nil
        }
        return (given.isEmpty ? nil : given, surname)
    }

    // MARK: - Family Parsing

    private static func parseFamily(
        _ record: GEDCOMRecord,
        profiles: [String: Profile],
        warnings: inout [String]
    ) -> [Relationship] {
        var husbID: String?
        var wifeID: String?
        var childIDs: [String] = []
        var marriageDate: GenealogicalDate?

        var i = 0
        while i < record.children.count {
            let line = record.children[i]

            switch line.tag {
            case "HUSB":
                husbID = line.value
            case "WIFE":
                wifeID = line.value
            case "CHIL":
                if let childRef = line.value {
                    childIDs.append(childRef)
                }
            case "MARR":
                let subs = subordinates(of: i, in: record.children)
                for sub in subs {
                    if sub.tag == "DATE", let v = sub.value {
                        marriageDate = GenealogicalDate(parsing: v)
                    }
                    // PLAC for marriages could be stored on the relationship
                    // but currently we only track the date
                }
            default:
                break
            }

            i += 1
        }

        var relationships: [Relationship] = []

        // Spouse relationship
        if let h = husbID, let w = wifeID {
            relationships.append(Relationship(
                id: UUID(), from: h, to: w,
                type: .spouse,
                role: nil,
                subtype: .unknown,
                marriageDate: marriageDate,
                marriageLocation: nil,
                divorceDate: nil
            ))
        }

        // Parent-child relationships
        // HUSB → father, WIFE → mother (GEDCOM convention)
        // Falls back to .unspecified if parent not in profiles or gender ambiguous
        for childID in childIDs {
            if let h = husbID {
                let role: ParentRole
                if let parent = profiles[h] {
                    role = parent.gender == .male ? .father : (parent.gender == .female ? .mother : .unspecified)
                } else {
                    role = .father // HUSB convention
                }
                relationships.append(Relationship(
                    id: UUID(), from: h, to: childID,
                    type: .parent,
                    role: role,
                    subtype: .unknown, // No PEDI tag → unknown
                    marriageDate: nil,
                    marriageLocation: nil,
                    divorceDate: nil
                ))
            }
            if let w = wifeID {
                let role: ParentRole
                if let parent = profiles[w] {
                    role = parent.gender == .female ? .mother : (parent.gender == .male ? .father : .unspecified)
                } else {
                    role = .mother // WIFE convention
                }
                relationships.append(Relationship(
                    id: UUID(), from: w, to: childID,
                    type: .parent,
                    role: role,
                    subtype: .unknown,
                    marriageDate: nil,
                    marriageLocation: nil,
                    divorceDate: nil
                ))
            }
        }

        return relationships
    }

    // MARK: - Helpers

    /// Get subordinate lines (level > current line's level) immediately following index.
    private static func subordinates(of index: Int, in lines: [GEDCOMLine]) -> [GEDCOMLine] {
        guard index < lines.count else { return [] }
        let parentLevel = lines[index].level
        var subs: [GEDCOMLine] = []
        var j = index + 1
        while j < lines.count && lines[j].level > parentLevel {
            subs.append(lines[j])
            j += 1
        }
        return subs
    }
}
