import Foundation

/// Scored result — a source record classified through 4 gates.
nonisolated struct ScoredRecord: Identifiable, Sendable {
    let id: String
    let record: SourceRecord
    let verdict: RecordVerdict
    let gates: [GateResult]
    let summary: String
}

nonisolated enum RecordVerdict: String, Codable, Sendable {
    case fact, lead, impossible
}

nonisolated struct GateResult: Sendable {
    let gate: ScoringGate
    let outcome: GateOutcome
    let reason: String
}

nonisolated enum ScoringGate: String, Codable, Sendable {
    case name, date, geography, familyContext
}

nonisolated enum GateOutcome: String, Codable, Sendable {
    case pass
    case fail           // hard fail — disqualifies (name mismatch, date impossibility)
    case softFail       // non-disqualifying — geography/type mismatch is suspicious but not fatal
    case impossible     // violates hard temporal rules
    case skip           // gate not applicable (no data to check)
}

/// Deterministic record classifier — fact, lead, or impossible.
/// Faithfully ported from Python's agent/scorer.py.
///
/// A record is a FACT only if ALL gates pass. If any gate fails
/// but the record looks promising, it's a LEAD. If a hard rule
/// is violated, it's IMPOSSIBLE.
nonisolated struct RecordScorer {

    /// Classify a source record against a known person.
    static func classify(
        record: SourceRecord,
        subject: ResearchSubject,
        searchType: RecordType
    ) -> ScoredRecord {
        var gates: [GateResult] = []
        var failed: [ScoringGate] = []

        // GATE 1: NAME
        let nameResult = checkName(record: record, subject: subject)
        gates.append(nameResult)
        if nameResult.outcome == .fail { failed.append(.name) }

        // GATE 2: DATE
        let dateResult = checkDate(record: record, subject: subject, searchType: searchType)
        gates.append(dateResult)
        if dateResult.outcome == .impossible {
            return ScoredRecord(
                id: record.id, record: record, verdict: .impossible,
                gates: gates, summary: summarise(record: record, searchType: searchType)
            )
        }
        if dateResult.outcome == .fail { failed.append(.date) }

        // GATE 3: GEOGRAPHY
        let geoResult = checkGeography(record: record, subject: subject)
        gates.append(geoResult)
        if geoResult.outcome == .fail { failed.append(.geography) }

        // GATE 4: FAMILY CONTEXT (bonus)
        let familyResult = checkFamilyContext(record: record, subject: subject)
        if familyResult.outcome != .skip {
            gates.append(familyResult)
        }

        // VERDICT
        // Hard fail on name or date → impossible (wrong person or temporally impossible)
        // All gates pass with no softFails → fact
        // All gates pass but has softFails (geography/type) → lead (promising but suspicious)
        // Any hard fail on geography → lead
        let hasSoftFails = gates.contains { $0.outcome == .softFail }
        let verdict: RecordVerdict
        if failed.isEmpty && !hasSoftFails {
            verdict = .fact
        } else if failed.isEmpty && hasSoftFails {
            verdict = .lead
        } else if failed.contains(.name) {
            verdict = .impossible
        } else {
            verdict = .lead
        }

        return ScoredRecord(
            id: record.id, record: record, verdict: verdict,
            gates: gates, summary: summarise(record: record, searchType: searchType)
        )
    }

    // MARK: - Gate 1: Name

    private static func checkName(record: SourceRecord, subject: ResearchSubject) -> GateResult {
        let personSurname = (subject.surname ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        let personGiven = (subject.givenName ?? "").uppercased().trimmingCharacters(in: .whitespaces)

        var recordSurname = (record.surname ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        var recordGiven = (record.givenName ?? record.name ?? "").uppercased().trimmingCharacters(in: .whitespaces)

        // FreeCen returns full name in "name" field — split it
        if recordSurname.isEmpty && !recordGiven.isEmpty {
            let parts = recordGiven.split(separator: " ")
            if parts.count >= 2 {
                recordGiven = String(parts[0])
                recordSurname = String(parts.last!)
            }
        }

        if recordSurname.isEmpty || personSurname.isEmpty {
            return GateResult(gate: .name, outcome: .fail, reason: "cannot compare — missing surname")
        }

        let surnameScore = ScoringRules.nameSimilarity(recordSurname, personSurname)
        if surnameScore < 0.7 {
            return GateResult(gate: .name, outcome: .fail, reason: "surname mismatch: \(recordSurname) vs \(personSurname)")
        }

        var givenScore = 0.5
        if !recordGiven.isEmpty && !personGiven.isEmpty {
            givenScore = ScoringRules.nameSimilarity(recordGiven, personGiven)
            if givenScore < 0.7 {
                return GateResult(gate: .name, outcome: .fail, reason: "given name mismatch: \(recordGiven) vs \(personGiven)")
            }
        } else if recordGiven.isEmpty {
            return GateResult(gate: .name, outcome: .fail, reason: "no given name in record to compare")
        }

        return GateResult(gate: .name, outcome: .pass, reason: String(format: "surname=%.2f, given=%.2f", surnameScore, givenScore))
    }

    // MARK: - Gate 2: Date

    private static func checkDate(record: SourceRecord, subject: ResearchSubject, searchType: RecordType) -> GateResult {
        guard let birthYear = subject.birthYearFrom else {
            return GateResult(gate: .date, outcome: .fail, reason: "insufficient date information")
        }

        let recordYear = extractYear(from: record)
        guard let recordYear else {
            return GateResult(gate: .date, outcome: .fail, reason: "insufficient date information")
        }

        let deathYear = subject.deathYearFrom
        let validation = ScoringRules.validateRecord(recordYear: recordYear, birthYear: birthYear, deathYear: deathYear, recordType: searchType.rawValue)
        if validation.hasPrefix("impossible") {
            return GateResult(gate: .date, outcome: .impossible, reason: validation)
        }

        switch searchType {
        case .death:
            let ageAtDeath = recordYear - birthYear
            // Check age field if available
            if case .death(let dr) = record, let recordedAge = dr.age {
                if ScoringRules.yearsMatch(recordedAge, ageAtDeath, tolerance: 2) {
                    return GateResult(gate: .date, outcome: .pass, reason: "age at death \(recordedAge) matches expected \(ageAtDeath)")
                } else {
                    return GateResult(gate: .date, outcome: .fail, reason: "age at death \(recordedAge) doesn't match expected \(ageAtDeath)")
                }
            }
            if 15 <= ageAtDeath && ageAtDeath <= 100 {
                return GateResult(gate: .date, outcome: .pass, reason: "died \(recordYear), age ~\(ageAtDeath) (plausible)")
            }
            return GateResult(gate: .date, outcome: .fail, reason: "died \(recordYear), age ~\(ageAtDeath) (unusual)")

        case .marriage:
            if !ScoringRules.checkMarriageAge(birthYear: birthYear, marriageYear: recordYear) {
                return GateResult(gate: .date, outcome: .impossible, reason: "married \(recordYear) at age \(recordYear - birthYear)")
            }
            let age = recordYear - birthYear
            if 16 <= age && age <= 60 {
                return GateResult(gate: .date, outcome: .pass, reason: "married \(recordYear), age ~\(age) (typical)")
            }
            if age > 70 {
                return GateResult(gate: .date, outcome: .impossible, reason: "married \(recordYear) at age ~\(age)")
            }
            return GateResult(gate: .date, outcome: .fail, reason: "married \(recordYear), age ~\(age) (unusual)")

        case .census:
            if case .census(let cr) = record, let censusBirth = cr.birthYear {
                if ScoringRules.yearsMatch(censusBirth, birthYear, tolerance: ScoringRules.censusAgeTolerance) {
                    return GateResult(gate: .date, outcome: .pass, reason: "census birth year \(censusBirth) matches ~\(birthYear)")
                }
                let diff = abs(censusBirth - birthYear)
                return GateResult(gate: .date, outcome: .fail, reason: "census birth year \(censusBirth) is \(diff) years off")
            }
            return GateResult(gate: .date, outcome: .fail, reason: "no birth year in census record")

        default:
            // Birth or unknown
            if ScoringRules.yearsMatch(recordYear, birthYear, tolerance: ScoringRules.birthYearTolerance) {
                return GateResult(gate: .date, outcome: .pass, reason: "year \(recordYear) matches ~\(birthYear)")
            }
            let diff = abs(recordYear - birthYear)
            if diff <= 5 {
                return GateResult(gate: .date, outcome: .fail, reason: "year \(recordYear) is \(diff) years from ~\(birthYear)")
            }
            return GateResult(gate: .date, outcome: .impossible, reason: "year \(recordYear) is \(diff) years from ~\(birthYear)")
        }
    }

    // MARK: - Gate 3: Geography

    private static func checkGeography(record: SourceRecord, subject: ResearchSubject) -> GateResult {
        // Extract district from record
        var district = ""
        switch record {
        case .birth(let r): district = r.district ?? ""
        case .death(let r): district = r.district ?? ""
        case .marriage(let r): district = r.district ?? ""
        case .census(let r): district = r.district ?? ""
        default: break
        }

        if district.isEmpty {
            // Check FamilySearch-style place fields
            var county = ""
            switch record {
            case .census(let r): county = r.birthCounty ?? r.birthPlace ?? ""
            case .burial(let r): county = r.burialLocation ?? ""
            default: break
            }
            if county.lowercased().contains("derby") {
                return GateResult(gate: .geography, outcome: .pass, reason: "Derbyshire")
            }
            if !county.isEmpty {
                return GateResult(gate: .geography, outcome: .softFail, reason: "location: \(String(county.prefix(50)))")
            }
            return GateResult(gate: .geography, outcome: .softFail, reason: "no location data")
        }

        let districtClean = district.replacingOccurrences(of: " district", with: "").trimmingCharacters(in: .whitespaces)

        if let nonLocal = ScoringRules.isNonLocal(districtClean, forHomeChapman: subject.homeChapmanCode) {
            return GateResult(gate: .geography, outcome: .softFail, reason: "\(districtClean) is in \(nonLocal), not local")
        }

        if ScoringRules.isLocalDistrict(districtClean, forHomeChapman: subject.homeChapmanCode) {
            return GateResult(gate: .geography, outcome: .pass, reason: "\(districtClean) is in research area")
        }

        return GateResult(gate: .geography, outcome: .softFail, reason: "unknown district: \(districtClean)")
    }

    // MARK: - Gate 4: Family Context

    private static func checkFamilyContext(record: SourceRecord, subject: ResearchSubject) -> GateResult {
        guard let context = subject.familyContext else {
            return GateResult(gate: .familyContext, outcome: .skip, reason: "no family context available")
        }

        // Check census household for known family members
        if case .census(let census) = record, let household = census.household {
            // Spouse match
            if let spouseName = context.spouseName {
                let spouseInHousehold = household.contains { member in
                    let rel = member.relationship.lowercased()
                    let isSpouse = rel.contains("wife") || rel.contains("husband")
                    return isSpouse && ScoringRules.nameSimilarity(member.name.uppercased(), spouseName.uppercased()) >= 0.7
                }
                if spouseInHousehold {
                    return GateResult(gate: .familyContext, outcome: .pass, reason: "spouse \(spouseName) found in household")
                }
            }

            // Child match
            for childName in context.childNames {
                let childInHousehold = household.contains { member in
                    let rel = member.relationship.lowercased()
                    let isChild = rel.contains("son") || rel.contains("daughter") || rel.contains("child")
                    return isChild && ScoringRules.nameSimilarity(member.name.uppercased(), childName.uppercased()) >= 0.7
                }
                if childInHousehold {
                    return GateResult(gate: .familyContext, outcome: .pass, reason: "child \(childName) found in household")
                }
            }

            // No family members found — soft fail (suspicious but not disqualifying)
            if context.spouseName != nil || !context.childNames.isEmpty {
                return GateResult(gate: .familyContext, outcome: .softFail, reason: "no known family members in household")
            }
        }

        // Marriage record — check spouse name match
        if case .marriage(let marriage) = record, let spouseName = marriage.spouseName {
            if let knownSpouse = context.spouseName {
                if ScoringRules.nameSimilarity(spouseName.uppercased(), knownSpouse.uppercased()) >= 0.7 {
                    return GateResult(gate: .familyContext, outcome: .pass, reason: "spouse matches: \(spouseName)")
                }
            }
            if let knownSurname = context.spouseSurname {
                let parts = spouseName.uppercased().split(separator: " ")
                if let recordSurname = parts.last, ScoringRules.nameSimilarity(String(recordSurname), knownSurname.uppercased()) >= 0.7 {
                    return GateResult(gate: .familyContext, outcome: .pass, reason: "spouse surname matches: \(recordSurname)")
                }
            }
        }

        return GateResult(gate: .familyContext, outcome: .skip, reason: "no family context applicable for this record type")
    }

    // MARK: - Helpers

    /// Extract a year from a SourceRecord based on its type.
    private static func extractYear(from record: SourceRecord) -> Int? {
        switch record {
        case .birth(let r): return r.birthYear
        case .death(let r): return r.deathYear
        case .marriage(let r): return r.marriageYear
        case .census(let r): return r.censusYear
        case .burial(let r): return r.deathYear ?? r.birthYear
        case .military(let r): return r.deathYear
        case .probate(let r): return r.deathYear
        case .parish(let r): return r.eventYear
        case .pedigree(let r): return r.birthYear
        }
    }

    /// Create a one-line summary of a record.
    static func summarise(record: SourceRecord, searchType: RecordType) -> String {
        switch record {
        case .birth(let r):
            let name = [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
            return "\(name), \(r.quarter ?? "") \(r.birthYear.map(String.init) ?? "?"), \(r.district ?? "")"
        case .death(let r):
            let name = [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
            let ageStr = r.age.map { ", age \($0)" } ?? ""
            return "\(name), \(r.quarter ?? "") \(r.deathYear.map(String.init) ?? "?"), \(r.district ?? "")\(ageStr)"
        case .marriage(let r):
            let name = [r.common.givenName, r.common.surname].compactMap { $0 }.joined(separator: " ")
            let spouseStr = r.spouseName.map { ", spouse \($0)" } ?? ""
            return "\(name), \(r.quarter ?? "") \(r.marriageYear.map(String.init) ?? "?")\(spouseStr)"
        case .census(let r):
            return "\(r.common.name ?? "?"), census \(r.censusYear), born \(r.birthYear.map(String.init) ?? "?") \(r.birthPlace ?? "")"
        case .military(let r):
            return "\(r.common.name ?? "?"), \(r.rank ?? "") \(r.regiment ?? ""), died \(r.dateOfDeath ?? "?")"
        case .burial(let r):
            return "\(r.common.name ?? "?"), \(r.cemetery ?? "")"
        case .probate(let r):
            return "\(r.common.name ?? "?"), \(r.grantType ?? "probate") \(r.probateDate ?? "")"
        case .parish(let r):
            return "\(r.common.name ?? "?"), \(r.eventType ?? "") \(r.eventYear.map(String.init) ?? "?")"
        case .pedigree(let r):
            return "\(r.common.name ?? "?"), b.\(r.birthYear.map(String.init) ?? "?") \(r.location ?? "")"
        }
    }
}
