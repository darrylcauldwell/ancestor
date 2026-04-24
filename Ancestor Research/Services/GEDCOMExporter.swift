import Foundation

/// Exports a FamilyGraphSnapshot to GEDCOM 5.5.1 format.
/// This is lossy interop — app-specific data (disputes, source provenance
/// beyond first source, transaction history) is dropped. See DESIGN.md §5.10.
nonisolated struct GEDCOMExporter {

    struct ExportResult {
        let content: String
        let individualCount: Int
        let familyCount: Int
        let dropped: [String]
    }

    /// Export to a file at the given path.
    static func export(_ snapshot: FamilyGraphSnapshot, to path: String) throws -> ExportResult {
        let result = export(snapshot)
        try result.content.write(toFile: path, atomically: true, encoding: .utf8)
        return result
    }

    /// Export to a GEDCOM string.
    static func export(_ snapshot: FamilyGraphSnapshot) -> ExportResult {
        var lines: [String] = []
        var dropped: [String] = []

        // Header
        lines.append(contentsOf: [
            "0 HEAD",
            "1 SOUR AncestorResearch",
            "2 NAME \(AppConstants.displayName)",
            "1 DATE \(formatHeaderDate(Date()))",
            "1 GEDC",
            "2 VERS 5.5.1",
            "2 FORM LINEAGE-LINKED",
            "1 CHAR UTF-8",
        ])

        // Submitter
        lines.append("0 @SUBM1@ SUBM")
        lines.append("1 NAME \(AppConstants.displayName)")

        // Individuals
        var indiCount = 0
        let sortedProfiles = snapshot.profiles.values.sorted { $0.id < $1.id }
        for profile in sortedProfiles {
            indiCount += 1
            lines.append(contentsOf: exportIndividual(profile))

            // Track dropped data
            if !profile.disputes.isEmpty {
                dropped.append("Dropped \(profile.disputes.count) dispute(s) for \(profile.displayName)")
            }
            for (field, sources) in profile.sources where sources.count > 1 {
                dropped.append("Dropped \(sources.count - 1) additional source(s) for \(profile.displayName).\(field.rawValue)")
            }
        }

        // Families — reconstruct FAM records from relationships
        let families = buildFamilies(from: snapshot)
        var famCount = 0
        for family in families {
            famCount += 1
            lines.append(contentsOf: exportFamily(family))
        }

        // Trailer
        lines.append("0 TRLR")

        return ExportResult(
            content: lines.joined(separator: "\n") + "\n",
            individualCount: indiCount,
            familyCount: famCount,
            dropped: dropped
        )
    }

    // MARK: - Individual Export

    private static func exportIndividual(_ profile: Profile) -> [String] {
        var lines: [String] = []
        lines.append("0 \(profile.id) INDI")

        // Name
        let given = profile.firstName ?? ""
        let surname = profile.lastName ?? ""
        if !given.isEmpty || !surname.isEmpty {
            lines.append("1 NAME \(given) /\(surname)/")
            if !given.isEmpty { lines.append("2 GIVN \(given)") }
            if !surname.isEmpty { lines.append("2 SURN \(surname)") }
        }

        // Gender
        if let gender = profile.gender {
            switch gender {
            case .male: lines.append("1 SEX M")
            case .female: lines.append("1 SEX F")
            case .unknown: lines.append("1 SEX U")
            }
        }

        // Birth
        if profile.birthDate != nil || profile.birthLocation != nil {
            lines.append("1 BIRT")
            if let date = profile.birthDate {
                lines.append("2 DATE \(date.original)")
            }
            if let place = profile.birthLocation {
                lines.append("2 PLAC \(place)")
            }
        }

        // Death
        if profile.deathDate != nil || profile.deathLocation != nil {
            lines.append("1 DEAT")
            if let date = profile.deathDate {
                lines.append("2 DATE \(date.original)")
            }
            if let place = profile.deathLocation {
                lines.append("2 PLAC \(place)")
            }
        }

        return lines
    }

    // MARK: - Family Reconstruction

    /// A reconstructed FAM record for export.
    private struct ExportFamily {
        let id: String
        let husbandID: String?
        let wifeID: String?
        let childIDs: [String]
        let marriageDate: GenealogicalDate?
    }

    /// Reconstruct FAM records from spouse + parent relationships.
    /// Each unique couple (or single parent with children) becomes one FAM.
    private static func buildFamilies(from snapshot: FamilyGraphSnapshot) -> [ExportFamily] {
        var families: [String: ExportFamily] = [:]
        var famCounter = 1

        // Process spouse relationships first — each creates a FAM
        for rel in snapshot.relationships where rel.type == .spouse {
            let key = [rel.from, rel.to].sorted().joined(separator: "+")
            if families[key] == nil {
                // Determine HUSB/WIFE by gender
                let p1 = snapshot.profiles[rel.from]
                let p2 = snapshot.profiles[rel.to]
                let husbID: String?
                let wifeID: String?
                if p1?.gender == .male {
                    husbID = rel.from
                    wifeID = rel.to
                } else if p2?.gender == .male {
                    husbID = rel.to
                    wifeID = rel.from
                } else {
                    husbID = rel.from
                    wifeID = rel.to
                }
                families[key] = ExportFamily(
                    id: "@F\(famCounter)@",
                    husbandID: husbID,
                    wifeID: wifeID,
                    childIDs: [],
                    marriageDate: rel.marriageDate
                )
                famCounter += 1
            }
        }

        // Process parent relationships — assign children to families.
        // A child may appear in multiple families (biological + step-parent).
        // Group parent edges per child, then split into pairs/singles to form FAMs.
        var childToParentEdges: [String: [Relationship]] = [:]
        for rel in snapshot.relationships where rel.type == .parent {
            childToParentEdges[rel.to, default: []].append(rel)
        }

        for (childID, parentEdges) in childToParentEdges {
            // Group parent edges into family units.
            // If parents are a couple (have a spouse edge), they're one family.
            // Otherwise each parent is a separate family unit for this child.
            let parentIDs = parentEdges.map(\.from)
            var assigned: Set<String> = []

            // First: find pairs that are spouses
            for i in 0..<parentIDs.count {
                guard !assigned.contains(parentIDs[i]) else { continue }
                for j in (i + 1)..<parentIDs.count {
                    guard !assigned.contains(parentIDs[j]) else { continue }
                    let pair = [parentIDs[i], parentIDs[j]].sorted()
                    let key = pair.joined(separator: "+")
                    if families[key] != nil {
                        // This pair has a spouse FAM — add child to it
                        let existing = families[key]!
                        var children = existing.childIDs
                        if !children.contains(childID) { children.append(childID) }
                        families[key] = ExportFamily(
                            id: existing.id, husbandID: existing.husbandID,
                            wifeID: existing.wifeID, childIDs: children,
                            marriageDate: existing.marriageDate
                        )
                        assigned.insert(parentIDs[i])
                        assigned.insert(parentIDs[j])
                    }
                }
            }

            // Second: remaining unassigned parents get their own FAM
            for parentID in parentIDs where !assigned.contains(parentID) {
                let key = parentID
                if let existing = families[key] {
                    var children = existing.childIDs
                    if !children.contains(childID) { children.append(childID) }
                    families[key] = ExportFamily(
                        id: existing.id, husbandID: existing.husbandID,
                        wifeID: existing.wifeID, childIDs: children,
                        marriageDate: existing.marriageDate
                    )
                } else {
                    let parent = snapshot.profiles[parentID]
                    let isHusb = parent?.gender != .female
                    families[key] = ExportFamily(
                        id: "@F\(famCounter)@",
                        husbandID: isHusb ? parentID : nil,
                        wifeID: isHusb ? nil : parentID,
                        childIDs: [childID],
                        marriageDate: nil
                    )
                    famCounter += 1
                }
            }
        }

        return families.values.sorted { $0.id < $1.id }
    }

    private static func exportFamily(_ family: ExportFamily) -> [String] {
        var lines: [String] = []
        lines.append("0 \(family.id) FAM")

        if let husb = family.husbandID {
            lines.append("1 HUSB \(husb)")
        }
        if let wife = family.wifeID {
            lines.append("1 WIFE \(wife)")
        }
        for childID in family.childIDs {
            lines.append("1 CHIL \(childID)")
        }
        if let date = family.marriageDate {
            lines.append("1 MARR")
            lines.append("2 DATE \(date.original)")
        }

        return lines
    }

    // MARK: - Helpers

    private static func formatHeaderDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date).uppercased()
    }
}
