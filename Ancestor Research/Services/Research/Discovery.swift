import Foundation

/// A first-class finding the research pipeline surfaces to the user.
/// Discoveries are things the user didn't explicitly ask for but are genealogically significant.
nonisolated struct Discovery: Identifiable, Sendable {
    let id: String
    let type: DiscoveryType
    let description: String
    let evidence: String
    let suggestedAction: String
    let sourceID: String?
}

/// Types of discoveries the pipeline can surface.
nonisolated enum DiscoveryType: String, Sendable {
    case newAncestor        // Ghost node could be filled
    case maidenName         // Wife's maiden name found from census mother-in-law
    case unknownSibling     // Census household reveals sibling not in tree
    case unknownChild       // Census shows child not in tree
    case spouseIdentified   // Marriage record identifies spouse
    case householdMember    // Census reveals someone living with the subject
    case militaryService    // CWGC record reveals military service
    case occupationRevealed // Census reveals occupation
    case addressFound       // Census reveals address/location
    case alternateSpelling  // Name appears with different spelling across sources
}

/// Extracts discoveries from research results.
nonisolated struct DiscoveryExtractor {

    /// The subject's own relationship-to-head in a census household
    /// (lowercased) — via the `isTarget` flag or a name match. Nil if the
    /// subject isn't located in the roster.
    static func subjectHouseholdRole(_ household: [HouseholdMember], subject: Profile) -> String? {
        if let target = household.first(where: { $0.isTarget == true }) {
            return target.relationship.lowercased()
        }
        let name = subject.displayName.uppercased()
        return household.first(where: { $0.name.uppercased() == name })?.relationship.lowercased()
    }

    /// Census enumerators record every role relative to the HEAD of household.
    /// When our subject is NOT the head, those labels are wrong for us — a
    /// fellow "Son" is the subject's *brother*, the "Head" is the subject's
    /// *father*. Re-expresses a member's role relative to the subject.
    ///
    /// Returns the subject-relative label plus whether it's specifically a
    /// sibling (so the discovery can be typed and de-duplicated correctly).
    /// Returns nil to mean "keep the recorded role" — the subject is the head
    /// (roles already read correctly), or the role is an in-law/grandparent we
    /// won't risk mis-mapping.
    static func relativeToSubject(_ memberRole: String, subjectRole: String?, memberSex: String?)
        -> (label: String, isSibling: Bool)? {
        // Only re-map when the subject is a CHILD in the household — that's the
        // case the head-relative roles get wrong.
        guard let s = subjectRole, s.contains("son") || s.contains("daughter") else { return nil }
        let m = memberRole.lowercased()
        let female = (memberSex ?? "").uppercased().hasPrefix("F")
        let isInLaw = m.contains("law")
        if m.contains("head") { return (female ? "mother" : "father", false) }
        if !isInLaw, m.contains("wife") || m == "mother" { return ("mother", false) }
        if !isInLaw, m.contains("husband") || m == "father" { return ("father", false) }
        if !isInLaw, m.contains("son") { return ("brother", true) }
        if !isInLaw, m.contains("daughter") { return ("sister", true) }
        if m.contains("brother") { return ("brother", true) }
        if m.contains("sister") { return ("sister", true) }
        return nil  // in-laws, grandparents, boarders — don't guess
    }

    /// Extract a research result and the current tree.
    static func extract(
        from result: ResearchResult,
        profile: Profile,
        snapshot: FamilyGraphSnapshot
    ) -> [Discovery] {
        var discoveries: [Discovery] = []

        // Household members not in the tree. Census roles are head-relative,
        // so re-express each one relative to the subject before labelling.
        let hhSubjectRole = Self.subjectHouseholdRole(result.householdMembers, subject: profile)
        let subjectNameUpper = profile.displayName.uppercased()
        for member in result.householdMembers {
            let nameUpper = member.name.uppercased()
            if nameUpper == subjectNameUpper { continue }   // never the subject themselves
            let isInTree = snapshot.profiles.values.contains { p in
                p.displayName.uppercased() == nameUpper
            }
            if !isInTree {
                let remap = Self.relativeToSubject(
                    member.relationship, subjectRole: hhSubjectRole, memberSex: member.sex)
                let label = remap?.label ?? member.relationship.lowercased()
                let type: DiscoveryType = if remap?.isSibling == true
                    || label.contains("brother") || label.contains("sister") {
                    .unknownSibling
                } else {
                    .householdMember
                }

                discoveries.append(Discovery(
                    id: "disc-hh-\(member.name.hashValue)",
                    type: type,
                    description: "\(member.name) (\(label))",
                    evidence: "Found in census household" +
                        (member.age.map { ", age \($0)" } ?? "") +
                        (member.birthPlace.map { ", born \($0)" } ?? ""),
                    suggestedAction: "Add to tree as \(label)",
                    sourceID: nil
                ))
            }
        }

        // Spouse from marriage records
        for cluster in result.clusters {
            for scored in cluster.records where scored.verdict == .fact {
                if case .marriage(let r) = scored.record, let spouse = r.spouseName {
                    let spouseUpper = spouse.uppercased()
                    // Suppress when a spouse is already linked. The record's
                    // spouse is often surname-only ("MARSHALL"), while the linked
                    // spouse has a full name ("Harry Marshall"), so a full-name
                    // equality check missed it and surfaced redundant discoveries.
                    // Match on surname too.
                    let hasSpouse = snapshot.spousesOf(profile.id).contains { existing in
                        let existingName = existing.displayName.uppercased()
                        let existingSurname = (existing.lastName ?? "").uppercased()
                        return existingName == spouseUpper
                            || (!existingSurname.isEmpty && existingSurname == spouseUpper)
                            || (!existingSurname.isEmpty && spouseUpper.contains(existingSurname))
                            || (!spouseUpper.isEmpty && existingName.contains(spouseUpper))
                    }
                    if !hasSpouse {
                        discoveries.append(Discovery(
                            id: "disc-spouse-\(scored.id)",
                            type: .spouseIdentified,
                            description: "Married \(spouse)",
                            evidence: scored.summary,
                            suggestedAction: "Add \(spouse) as spouse",
                            sourceID: scored.record.sourceID
                        ))
                    }
                }
            }
        }

        // Maiden name from census mother-in-law
        for cluster in result.clusters {
            for scored in cluster.records where scored.verdict == .fact {
                if case .census(let r) = scored.record, let household = r.household {
                    let headSurname = profile.lastName ?? ""
                    if let maiden = ScoringRules.maidenNameFromMotherInLaw(
                        household: household, headSurname: headSurname
                    ) {
                        discoveries.append(Discovery(
                            id: "disc-maiden-\(scored.id)",
                            type: .maidenName,
                            description: "Wife's maiden name: \(maiden)",
                            evidence: "Mother-in-law surname in \(r.censusYear) census",
                            suggestedAction: "Update wife's maiden name to \(maiden)",
                            sourceID: scored.record.sourceID
                        ))
                    }
                }
            }
        }

        // Military service
        for cluster in result.clusters {
            for scored in cluster.records {
                if case .military = scored.record {
                    discoveries.append(Discovery(
                        id: "disc-military-\(scored.id)",
                        type: .militaryService,
                        description: scored.summary,
                        evidence: "CWGC casualty record",
                        suggestedAction: "Record military service and death details",
                        sourceID: scored.record.sourceID
                    ))
                }
            }
        }

        // Occupation and address from census records
        for cluster in result.clusters {
            for scored in cluster.records where scored.verdict == .fact {
                if case .census(let r) = scored.record {
                    // Occupation revealed
                    if let occupation = r.occupation, !occupation.isEmpty {
                        discoveries.append(Discovery(
                            id: "disc-occ-\(scored.id)",
                            type: .occupationRevealed,
                            description: "\(r.censusYear) census: \(occupation)",
                            evidence: "Census occupation field",
                            suggestedAction: "Note occupation: \(occupation)",
                            sourceID: scored.record.sourceID
                        ))
                    }
                    // Address found
                    if let address = r.address, !address.isEmpty {
                        discoveries.append(Discovery(
                            id: "disc-addr-\(scored.id)",
                            type: .addressFound,
                            description: "\(r.censusYear) census: \(address)",
                            evidence: "Census address field",
                            suggestedAction: "Note address: \(address)",
                            sourceID: scored.record.sourceID
                        ))
                    }
                    // Unknown children (or siblings) — census roles are
                    // head-relative, so if the SUBJECT is a child in this
                    // household, the other Son/Daughter rows are the subject's
                    // brothers/sisters, not their children.
                    if let household = r.household {
                        let subjectRole = Self.subjectHouseholdRole(household, subject: profile)
                        let subjectIsChild = subjectRole.map {
                            $0.contains("son") || $0.contains("daughter")
                        } ?? false
                        let knownChildren = snapshot.childrenOf(profile.id)
                        let knownSiblings = snapshot.siblingsOf(profile.id)
                        let subjectName = profile.displayName.uppercased()
                        for member in household {
                            let rel = member.relationship.lowercased()
                            guard rel.contains("son") || rel.contains("daughter") else { continue }
                            // Never offer the subject themselves.
                            if member.isTarget == true { continue }
                            if member.name.uppercased() == subjectName { continue }

                            if subjectIsChild {
                                // Sibling, not child.
                                let known = knownSiblings.contains {
                                    $0.displayName.uppercased() == member.name.uppercased()
                                }
                                if known { continue }
                                let sib = rel.contains("daughter") ? "sister" : "brother"
                                discoveries.append(Discovery(
                                    id: "disc-sib-\(member.name.hashValue)_\(r.censusYear)",
                                    type: .unknownSibling,
                                    description: "\(member.name) (\(sib))",
                                    evidence: "\(r.censusYear) census household",
                                    suggestedAction: "Add \(member.name) as \(sib)",
                                    sourceID: scored.record.sourceID
                                ))
                            } else {
                                // Subject is the head/parent → genuinely a child.
                                let known = knownChildren.contains {
                                    $0.displayName.uppercased() == member.name.uppercased()
                                }
                                if known { continue }
                                discoveries.append(Discovery(
                                    id: "disc-child-\(member.name.hashValue)_\(r.censusYear)",
                                    type: .unknownChild,
                                    description: "\(member.name) (\(member.relationship))",
                                    evidence: "\(r.censusYear) census household",
                                    suggestedAction: "Add \(member.name) as \(member.relationship.lowercased())",
                                    sourceID: scored.record.sourceID
                                ))
                            }
                        }
                    }
                }
            }
        }

        return discoveries
    }
}
