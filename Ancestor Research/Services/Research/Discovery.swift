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

    /// Extract discoveries from a research result and the current tree.
    static func extract(
        from result: ResearchResult,
        profile: Profile,
        snapshot: FamilyGraphSnapshot
    ) -> [Discovery] {
        var discoveries: [Discovery] = []

        // Household members not in the tree
        for member in result.householdMembers {
            let nameUpper = member.name.uppercased()
            let isInTree = snapshot.profiles.values.contains { p in
                p.displayName.uppercased() == nameUpper
            }
            if !isInTree {
                let relationship = member.relationship.lowercased()
                let type: DiscoveryType = if relationship.contains("brother") || relationship.contains("sister") {
                    .unknownSibling
                } else {
                    .householdMember
                }

                discoveries.append(Discovery(
                    id: "disc-hh-\(member.name.hashValue)",
                    type: type,
                    description: "\(member.name) (\(member.relationship))",
                    evidence: "Found in census household" +
                        (member.age.map { ", age \($0)" } ?? "") +
                        (member.birthPlace.map { ", born \($0)" } ?? ""),
                    suggestedAction: "Add to tree as \(member.relationship.lowercased())",
                    sourceID: nil
                ))
            }
        }

        // Spouse from marriage records
        for cluster in result.clusters {
            for scored in cluster.records where scored.verdict == .fact {
                if case .marriage(let r) = scored.record, let spouse = r.spouseName {
                    let spouseUpper = spouse.uppercased()
                    let hasSpouse = snapshot.spousesOf(profile.id).contains {
                        $0.displayName.uppercased() == spouseUpper
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
                    // Unknown children
                    if let household = r.household {
                        let children = snapshot.childrenOf(profile.id)
                        for member in household {
                            let rel = member.relationship.lowercased()
                            guard rel.contains("son") || rel.contains("daughter") else { continue }
                            let isKnown = children.contains {
                                $0.displayName.uppercased() == member.name.uppercased()
                            }
                            if !isKnown {
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
