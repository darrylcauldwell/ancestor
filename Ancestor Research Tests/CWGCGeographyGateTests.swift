import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-05 (CONNECTOR_AUDIT_2026-07.md §6.2) — the CWGC
/// geography-gate port. Pins the Python behaviour table from
/// `agent/scorer.py:236-273`:
///
///   * next-of-kin line mentions the research county / a configured
///     district / the subject's birth town → PASS
///   * non-empty line naming somewhere else → demoted. Python returns
///     "fail", and its verdict layer maps geography-fail to LEAD
///     (agent/scorer.py:80-88) — so the faithful Swift outcome is
///     `.softFail` → `.lead`, never `.impossible`.
///   * no additional_info at all → class-pass (audit-pinned amendment;
///     the cemetery genuinely can't be checked).
///
/// Includes the finding's two-namesake scenario: WWI casualties
/// 'G Brooks' with next-of-kin Belper vs Kent — previously both passed
/// geography by class; now the Kent one demotes to a lead.
struct CWGCGeographyGateTests {

    // MARK: - Helpers

    private func subject(
        givenName: String = "George",
        surname: String = "Brooks",
        birthYear: Int = 1890,
        region: Region? = nil,
        mode: ResearchMode = .extend,
        homeChapmanCode: String = "DBY"
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: givenName,
            birthYearFrom: birthYear,
            birthYearTo: birthYear,
            gender: .male,
            region: region,
            mode: mode,
            homeChapmanCode: homeChapmanCode
        )
    }

    private func militaryRecord(
        id: String = "cwgc_100001",
        surname: String = "Brooks",
        givenName: String? = "George",
        deathYear: Int = 1917,
        age: Int? = nil,
        additionalInfo: String? = nil
    ) -> SourceRecord {
        var raw: [String: String] = [:]
        if let additionalInfo { raw["additional_info"] = additionalInfo }
        let name = [givenName, surname].compactMap { $0 }.joined(separator: " ")
        return .military(MilitaryRecord(
            common: RecordCommon(
                id: id, sourceID: "cwgc",
                name: name.isEmpty ? surname : name,
                surname: surname, givenName: givenName,
                detailURL: nil, rawFields: raw
            ),
            rank: "Private", regiment: "Sherwood Foresters", unit: nil,
            serviceNumber: nil,
            dateOfDeath: "1 July \(deathYear)", deathYear: deathYear,
            age: age, cemetery: "Thiepval Memorial", graveRef: nil,
            additionalInfo: additionalInfo
        ))
    }

    private func geographyGate(_ scored: ScoredRecord) -> GateResult? {
        scored.gates.first { $0.gate == .geography }
    }

    private func classify(_ record: SourceRecord, subject: ResearchSubject) -> ScoredRecord {
        RecordScorer.classify(record: record, subject: subject, searchType: .death)
    }

    // MARK: - Python behaviour table

    @Test func inCountyNextOfKinPasses() {
        // County full-name mention — "Derbyshire" derives from the
        // subject's home Chapman code, not from any hardcoded region.
        let scored = classify(
            militaryRecord(additionalInfo: "Son of William and Mary Brooks, of Belper, Derbyshire."),
            subject: subject()
        )
        let gate = geographyGate(scored)
        #expect(gate?.outcome == .pass)
        #expect(gate?.reason.contains("next-of-kin") == true)
        #expect(scored.verdict == .fact,
                "all gates pass on a dense subject → fact")
    }

    @Test func countyShortFormMatchesCWGCStyle() {
        // CWGC writes "Derby" where config says "Derbyshire" — the
        // Python port matches the county's first five characters.
        let scored = classify(
            militaryRecord(additionalInfo: "Son of William Brooks, of Turnditch, Derby."),
            subject: subject()
        )
        #expect(geographyGate(scored)?.outcome == .pass)
    }

    @Test func configuredDistrictMentionPasses() {
        // "Ashbourne" is a configured DBY district; the line never
        // names the county.
        let scored = classify(
            militaryRecord(additionalInfo: "Son of Thomas Brooks, of Ashbourne."),
            subject: subject()
        )
        let gate = geographyGate(scored)
        #expect(gate?.outcome == .pass)
        #expect(gate?.reason.contains("Ashbourne") == true)
    }

    @Test func birthTownMentionPassesWithoutChapmanAnchor() {
        // Python's town check reads the subject's birth location (the
        // segment before the first comma) — it works even when no
        // county anchor is derivable.
        let scored = classify(
            militaryRecord(additionalInfo: "Son of John Brooks, of Turnditch."),
            subject: subject(
                region: .county("Turnditch, Derbyshire, England"),
                homeChapmanCode: ""
            )
        )
        let gate = geographyGate(scored)
        #expect(gate?.outcome == .pass)
        #expect(gate?.reason.lowercased().contains("turnditch") == true)
    }

    @Test func outOfCountyNextOfKinDemotesToLead() {
        // The Python table's fail case: a non-empty line naming
        // somewhere else. Demotion, not elimination — Python maps
        // geography-fail to LEAD.
        let scored = classify(
            militaryRecord(additionalInfo: "Son of Thomas Brooks, of Maidstone, Kent."),
            subject: subject(region: .county("Belper, Derbyshire"))
        )
        let gate = geographyGate(scored)
        #expect(gate?.outcome == .softFail)
        #expect(gate?.reason.contains("doesn't mention research area") == true)
        #expect(scored.verdict == .lead,
                "out-of-area next-of-kin demotes to lead, mirroring Python")
        #expect(scored.verdict != .impossible,
                "a mis-port to geography .fail would eliminate the record in focused modes")
    }

    @Test func noAdditionalInfoClassPasses() {
        // The class-pass survives ONLY for records with no
        // additional_info at all.
        let scored = classify(
            militaryRecord(additionalInfo: nil),
            subject: subject()
        )
        let gate = geographyGate(scored)
        #expect(gate?.outcome == .pass)
        #expect(gate?.reason.contains("class invariant") == true)
        #expect(scored.verdict == .fact)
    }

    @Test func anchorlessSubjectWithForeignLineDemotesGracefully() {
        // No chapman anchor, no birth location — the line names
        // somewhere we can't verify. Graceful demotion, never a crash
        // or an impossible.
        let scored = classify(
            militaryRecord(additionalInfo: "Son of Robert Brooks, of Toronto, Ontario."),
            subject: subject(region: nil, homeChapmanCode: "")
        )
        #expect(geographyGate(scored)?.outcome == .softFail)
        #expect(scored.verdict == .lead)
    }

    // MARK: - T1-10 feed — structured residence through the parish catalogue

    @Test func nextOfKinResidenceParishResolvesToResearchDistrict() {
        // "Turnditch" is a parish in Belper/Amber Valley district —
        // the line names neither the county nor a district, but the
        // parsed residence resolves through the parish catalogue.
        let scored = classify(
            militaryRecord(additionalInfo: "Son of John Brooks, of 5 Mill St., Turnditch."),
            subject: subject(region: nil)
        )
        let gate = geographyGate(scored)
        #expect(gate?.outcome == .pass)
        #expect(gate?.reason.contains("research-area district") == true)
    }

    // MARK: - The finding's two-namesake scenario

    @Test func kentAndBelperNamesakesAreSeparatedByNextOfKin() {
        // Two WWI casualties named G Brooks; next-of-kin Belper vs
        // Kent. Pre-T1-05 Swift passed both by class; Python demotes
        // the Kent one.
        let researcher = subject()
        let belper = classify(
            militaryRecord(
                id: "cwgc_200001",
                additionalInfo: "Son of William and Mary Brooks, of Belper, Derbyshire."
            ),
            subject: researcher
        )
        let kent = classify(
            militaryRecord(
                id: "cwgc_200002",
                additionalInfo: "Son of Thomas and Jane Brooks, of Maidstone, Kent."
            ),
            subject: researcher
        )
        #expect(belper.verdict == .fact, "in-county namesake promotes")
        #expect(kent.verdict == .lead, "out-of-county namesake demotes to lead")
        #expect(geographyGate(belper)?.outcome == .pass)
        #expect(geographyGate(kent)?.outcome == .softFail)
    }
}
