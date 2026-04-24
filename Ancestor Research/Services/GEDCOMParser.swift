import Foundation

/// Parses GEDCOM 5.5.1 files into a FamilyGraphSnapshot.
/// Custom implementation for full control over edge cases from
/// different exporters (Ancestry, WikiTree, FindMyPast, MyHeritage).
nonisolated struct GEDCOMParser {

    struct ParseResult {
        let snapshot: FamilyGraphSnapshot
        let warnings: [String]
        let individualCount: Int
        let familyCount: Int
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

        // Phase 1: Parse individuals
        var profiles: [String: Profile] = [:]
        var indiCount = 0
        for record in records where record.tag == "INDI" {
            indiCount += 1
            let profile = parseIndividual(record, warnings: &warnings)
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
            familyCount: famCount
        )
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

    private static func parseIndividual(_ record: GEDCOMRecord, warnings: inout [String]) -> Profile {
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
                let subs = subordinates(of: i, in: record.children)
                for sub in subs {
                    if sub.tag == "DATE", let v = sub.value {
                        birthDate = GenealogicalDate(parsing: v)
                        sources[.birthDate, default: []].append(
                            FieldSource(origin: .gedcom, raw: v, addedAt: now)
                        )
                    }
                    if sub.tag == "PLAC", let v = sub.value {
                        birthLocation = v
                        sources[.birthLocation, default: []].append(
                            FieldSource(origin: .gedcom, raw: v, addedAt: now)
                        )
                    }
                }

            case "DEAT":
                let subs = subordinates(of: i, in: record.children)
                for sub in subs {
                    if sub.tag == "DATE", let v = sub.value {
                        deathDate = GenealogicalDate(parsing: v)
                        sources[.deathDate, default: []].append(
                            FieldSource(origin: .gedcom, raw: v, addedAt: now)
                        )
                    }
                    if sub.tag == "PLAC", let v = sub.value {
                        deathLocation = v
                        sources[.deathLocation, default: []].append(
                            FieldSource(origin: .gedcom, raw: v, addedAt: now)
                        )
                    }
                }

            default:
                break
            }

            i += 1
        }

        if let fn = firstName {
            sources[.firstName, default: []].append(
                FieldSource(origin: .gedcom, raw: fn, addedAt: now)
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
            lastName: lastName,
            gender: gender,
            birthDate: birthDate,
            birthLocation: birthLocation,
            deathDate: deathDate,
            deathLocation: deathLocation,
            bio: nil,
            sources: sources,
            disputes: [:]
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
