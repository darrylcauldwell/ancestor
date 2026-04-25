import Foundation
import os

/// Processes pending facts submitted by the Field Researcher.
/// Reads from pending_facts table, runs the Evidence Firewall,
/// scores through the 4-gate scorer, detects discrepancies,
/// and prepares findings for human review.
@MainActor
final class PendingFactsProcessor {
    private let db: ProjectDatabase
    private let snapshot: FamilyGraphSnapshot
    private let sourceInfoMap: [String: SourceInfo]
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "PendingFacts")

    init(db: ProjectDatabase, snapshot: FamilyGraphSnapshot, sourceInfoMap: [String: SourceInfo]) {
        self.db = db
        self.snapshot = snapshot
        self.sourceInfoMap = sourceInfoMap
    }

    /// Process all pending facts for a profile. Returns processed results for review.
    func process(profileID: String) async -> [ProcessedFinding] {
        let pendingRows: [[String: Any]]
        do {
            pendingRows = try db.loadPendingFacts(profileID: profileID)
        } catch {
            logger.error("Failed to load pending facts: \(error.localizedDescription)")
            return []
        }

        guard let profile = snapshot.profiles[profileID] else { return [] }

        var processed: [ProcessedFinding] = []
        var citedURLs: Set<String> = []

        // Load existing cited URLs for source-recycling detection
        if let existingURLs = try? db.loadCitedURLs(profileID: profileID) {
            citedURLs = existingURLs
        }

        for row in pendingRows {
            guard let id = row["id"] as? String,
                  let field = row["fact_kind"] as? String,
                  let value = row["value_json"] as? String else { continue }

            let sourceURL = row["source_url"] as? String ?? ""
            let sourceTitle = row["source_title"] as? String ?? ""
            let evidenceText = row["evidence_text"] as? String ?? ""
            let reasoning = row["reasoning"] as? String ?? ""
            let confidence = row["confidence"] as? String ?? "medium"
            let agentID = row["agent_id"] as? String ?? "unknown"

            let finding = PendingFact(
                id: id, profileID: profileID, field: field, value: value,
                sourceURL: sourceURL, sourceTitle: sourceTitle,
                evidenceText: String(evidenceText.prefix(200)),
                reasoning: reasoning, confidence: confidence,
                agentID: agentID, submittedAt: Date(),
                verificationStatus: .pending
            )

            // Step 1: Hallucination checks (Rule 6)
            let birthYear = profile.birthDate?.earliest
            let deathYear = profile.deathDate?.earliest
            if let rejection = await EvidenceFirewall.validate(
                finding: finding,
                existingCitedURLs: citedURLs,
                profileBirthYear: birthYear,
                profileDeathYear: deathYear
            ) {
                logger.info("Firewall rejected: \(rejection)")
                processed.append(ProcessedFinding(
                    finding: finding, status: .rejected, rejectionReason: rejection,
                    scorerVerdict: nil, discrepancy: nil, sourceTier: nil
                ))
                continue
            }

            // Step 2: URL verification (Rule 2)
            let verification = await EvidenceFirewall.verifyURL(
                url: finding.sourceURL, evidenceText: finding.evidenceText
            )
            switch verification {
            case .verified(let pageData, let pageHash):
                logger.info("URL verified: \(finding.sourceURL)")
                // Cache the page for provenance
                cachePageData(url: finding.sourceURL, data: pageData, hash: pageHash)
            case .restricted(let reason):
                logger.info("Restricted source: \(reason)")
                // Proceed but mark as restricted
            case .contentMismatch(let reason):
                logger.info("Content mismatch: \(reason)")
                processed.append(ProcessedFinding(
                    finding: finding, status: .rejected, rejectionReason: "URL content mismatch: \(reason)",
                    scorerVerdict: nil, discrepancy: nil, sourceTier: nil
                ))
                continue
            case .failed(let reason):
                logger.info("URL verification failed: \(reason)")
                processed.append(ProcessedFinding(
                    finding: finding, status: .rejected, rejectionReason: "URL verification failed: \(reason)",
                    scorerVerdict: nil, discrepancy: nil, sourceTier: nil
                ))
                continue
            }

            // Step 3: Look up source tier from URL (Rule 5)
            let tierEntry = SourceTierRegistry.lookup(url: finding.sourceURL)

            // Step 4: Build a SourceRecord and score through 4-gate scorer
            let subject = ResearchSubject.fromProfile(profile, snapshot: snapshot, mode: .extend)
            let sourceRecord = buildSourceRecord(from: finding, tierEntry: tierEntry)

            if let sourceRecord {
                let scored = RecordScorer.classify(
                    record: sourceRecord, subject: subject, searchType: fieldToRecordType(finding.field)
                )

                // Step 5: Check discrepancy with existing tree data
                let discrepancy = detectDiscrepancy(finding: finding, profile: profile, tierEntry: tierEntry)

                processed.append(ProcessedFinding(
                    finding: finding,
                    status: scored.verdict == .impossible ? .rejected : .readyForReview,
                    rejectionReason: scored.verdict == .impossible ? "4-gate scorer: impossible" : nil,
                    scorerVerdict: scored.verdict,
                    discrepancy: discrepancy,
                    sourceTier: tierEntry
                ))
            } else {
                // Couldn't build a source record (e.g. narrative finding)
                processed.append(ProcessedFinding(
                    finding: finding, status: .readyForReview,
                    rejectionReason: nil, scorerVerdict: nil,
                    discrepancy: nil, sourceTier: tierEntry
                ))
            }

            citedURLs.insert(finding.sourceURL)
        }

        logger.info("Processed \(processed.count) pending facts for \(profileID): \(processed.filter { $0.status == .readyForReview }.count) ready for review")
        return processed
    }

    // MARK: - Helpers

    private func buildSourceRecord(from finding: PendingFact, tierEntry: SourceTierEntry) -> SourceRecord? {
        let common = RecordCommon(
            id: finding.id, sourceID: "field-researcher",
            name: nil, surname: nil, givenName: nil,
            detailURL: finding.sourceURL, rawFields: [
                "evidence_text": String(finding.evidenceText.prefix(200)),
                "source_title": finding.sourceTitle,
            ]
        )

        switch finding.field {
        case "birthDate", "baptismDate":
            let year = EvidenceFirewall.extractYear(from: finding.value)
            return .birth(BirthRecord(
                common: common, birthYear: year, birthDate: finding.value,
                birthPlace: nil, quarter: nil, district: nil, volume: nil,
                page: nil, mothersMaidenName: nil
            ))
        case "deathDate", "burialDate":
            let year = EvidenceFirewall.extractYear(from: finding.value)
            return .death(DeathRecord(
                common: common, deathYear: year, deathDate: finding.value,
                deathPlace: nil, age: nil, quarter: nil, district: nil,
                volume: nil, page: nil, spouseSurname: nil
            ))
        case "marriageDate":
            let year = EvidenceFirewall.extractYear(from: finding.value)
            return .marriage(MarriageRecord(
                common: common, marriageYear: year, marriageDate: finding.value,
                marriagePlace: nil, quarter: nil, district: nil, volume: nil,
                page: nil, spouseName: nil
            ))
        default:
            return nil  // Non-record fields (occupation, address) don't map to SourceRecord
        }
    }

    private func fieldToRecordType(_ field: String) -> RecordType {
        switch field {
        case "birthDate", "baptismDate": return .birth
        case "deathDate", "burialDate": return .death
        case "marriageDate": return .marriage
        default: return .birth  // fallback
        }
    }

    private func detectDiscrepancy(
        finding: PendingFact, profile: Profile, tierEntry: SourceTierEntry
    ) -> ResearchDiscrepancy? {
        let existingValue: String?
        switch finding.field {
        case "birthDate", "baptismDate": existingValue = profile.birthDate?.original
        case "deathDate", "burialDate": existingValue = profile.deathDate?.original
        default: existingValue = nil
        }

        guard let existing = existingValue,
              let existingYear = EvidenceFirewall.extractYear(from: existing),
              let findingYear = EvidenceFirewall.extractYear(from: finding.value),
              existingYear != findingYear else { return nil }

        let delta = abs(existingYear - findingYear)
        let severity = DiscrepancySeverityTable.severity(
            sourceTier: tierEntry.trustTier, absDelta: delta, convergence: .singleSource
        )

        return ResearchDiscrepancy(
            field: finding.field, existingValue: existing,
            sourceValue: finding.value, sourceID: "field-researcher",
            severity: severity.severity, reasoning: severity.reasoning
        )
    }

    private func cachePageData(url: String, data: Data, hash: String) {
        // Store page data to Application Support for provenance
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("dev.dreamfold.Ancestor-Research/page-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let filename = EvidenceFirewall.idempotencyKey(profileID: "", field: "", value: "", sourceURL: url)
        let filePath = cacheDir.appendingPathComponent("\(filename).html")
        try? data.write(to: filePath)
    }
}

/// A finding that has been through the Evidence Firewall and scorer.
struct ProcessedFinding: Identifiable {
    let id: String
    let finding: PendingFact
    let status: ProcessedStatus
    let rejectionReason: String?
    let scorerVerdict: RecordVerdict?
    let discrepancy: ResearchDiscrepancy?
    let sourceTier: SourceTierEntry?

    init(finding: PendingFact, status: ProcessedStatus, rejectionReason: String?,
         scorerVerdict: RecordVerdict?, discrepancy: ResearchDiscrepancy?, sourceTier: SourceTierEntry?) {
        self.id = finding.id
        self.finding = finding
        self.status = status
        self.rejectionReason = rejectionReason
        self.scorerVerdict = scorerVerdict
        self.discrepancy = discrepancy
        self.sourceTier = sourceTier
    }

    enum ProcessedStatus {
        case readyForReview
        case rejected
    }
}
