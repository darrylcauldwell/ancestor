import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-02 + T1-06 (score side) + T1-11
/// (CONNECTOR_AUDIT_2026-07.md §6.1/§6.2) — CWGC fields the scorer and
/// projection previously parsed but ignored.
struct CWGCRecordScoringTests {

    // MARK: - Helpers

    private func subject(
        givenName: String = "Ernest",
        middleName: String? = nil,
        surname: String = "Cauldwell",
        birthYear: Int = 1887
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: givenName,
            middleName: middleName,
            birthYearFrom: birthYear,
            birthYearTo: birthYear,
            gender: .male,
            region: nil,
            mode: .extend,
            homeChapmanCode: "DBY"
        )
    }

    private func militaryRecord(
        id: String = "cwgc_300001",
        surname: String = "Cauldwell",
        givenName: String? = "Ernest",
        deathYear: Int = 1918,
        age: Int? = nil,
        initials: String? = nil
    ) -> SourceRecord {
        var raw: [String: String] = [:]
        if let initials { raw["initials"] = initials }
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
            dateOfDeath: "21 March \(deathYear)", deathYear: deathYear,
            age: age, cemetery: "Arras Memorial", graveRef: nil,
            additionalInfo: nil
        ))
    }

    private func gate(_ scored: ScoredRecord, _ gate: ScoringGate) -> GateResult? {
        scored.gates.first { $0.gate == gate }
    }

    private func classify(_ record: SourceRecord, subject: ResearchSubject) -> ScoredRecord {
        RecordScorer.classify(record: record, subject: subject, searchType: .death)
    }

    // MARK: - T1-02 — date gate consumes CWGC's parsed AgeAtDeath

    @Test func consistentMilitaryAgePassesDateGate() {
        // Born 1887, died 1918 aged 31 — exactly consistent.
        let scored = classify(militaryRecord(age: 31), subject: subject())
        let date = gate(scored, .date)
        #expect(date?.outcome == .pass)
        #expect(date?.reason.contains("age at death 31") == true)
        #expect(scored.verdict == .fact)
    }

    @Test func inconsistentMilitaryAgeFailsDateGate() {
        // The audit's disambiguation case: an 'E Cauldwell' aged 19 in
        // 1918 previously passed because recordedAge was always nil for
        // military records and [15,100] intersected the window.
        let scored = classify(militaryRecord(age: 19), subject: subject())
        let date = gate(scored, .date)
        #expect(date?.outcome == .fail)
        #expect(date?.reason.contains("age at death 19") == true)
        #expect(scored.verdict == .lead,
                "a fully-disambiguating age mismatch must demote the record")
    }

    @Test func twoSameNameCasualtiesDifferingOnlyByAgeAreSeparated() {
        // The audit's recommendation test verbatim: two same-name
        // MilitaryRecords differing only by age.
        let researcher = subject()
        let aged31 = classify(militaryRecord(id: "cwgc_300010", age: 31), subject: researcher)
        let aged19 = classify(militaryRecord(id: "cwgc_300011", age: 19), subject: researcher)
        #expect(aged31.verdict == .fact)
        #expect(aged19.verdict == .lead)
    }

    @Test func unknownMilitaryAgeKeepsPlausibleBandBehaviour() {
        // CWGC's AgeAtDeath=0 parses to nil — the permissive band is
        // still the right fallback when no age is recorded.
        let scored = classify(militaryRecord(age: nil), subject: subject())
        #expect(gate(scored, .date)?.outcome == .pass)
    }

    // MARK: - T1-06 (score side) — initials-indexed casualties

    @Test func matchingInitialsPassTheNameGate() {
        // Forename empty, Initials "E V" — subject Ernest Victor.
        let scored = classify(
            militaryRecord(givenName: nil, initials: "E V"),
            subject: subject(givenName: "Ernest", middleName: "Victor")
        )
        let name = gate(scored, .name)
        #expect(name?.outcome == .pass)
        #expect(name?.reason.contains("initials") == true)
    }

    @Test func initialsOnlyRecordNoLongerFailsOnNonsenseComparison() {
        // Regression pin: the gate previously compared the SURNAME
        // against the given name ("given name mismatch: CAULDWELL vs
        // ERNEST") — a misleading audit-trail reason.
        let scored = classify(
            militaryRecord(givenName: nil, initials: "E"),
            subject: subject(givenName: "Ernest")
        )
        let name = gate(scored, .name)
        #expect(name?.outcome == .pass)
        #expect(name?.reason.contains("given name mismatch") == false)
    }

    @Test func contradictingFirstInitialFailsTheNameGate() {
        let scored = classify(
            militaryRecord(givenName: nil, initials: "T"),
            subject: subject(givenName: "Ernest")
        )
        let name = gate(scored, .name)
        #expect(name?.outcome == .fail)
        #expect(name?.reason.contains("initials mismatch") == true)
        #expect(scored.verdict == .impossible, "name fail is a rejection")
    }

    @Test func extraRecordInitialsBeyondKnownNamesStillPass() {
        // Record "E V" vs subject "Ernest" with no recorded middle name —
        // the subject's data may be incomplete; don't reject.
        let scored = classify(
            militaryRecord(givenName: nil, initials: "E V"),
            subject: subject(givenName: "Ernest")
        )
        #expect(gate(scored, .name)?.outcome == .pass)
    }

    @Test func contradictingMiddleInitialFails() {
        // Record "E V" vs subject Ernest Peter — V contradicts P.
        let scored = classify(
            militaryRecord(givenName: nil, initials: "E V"),
            subject: subject(givenName: "Ernest", middleName: "Peter")
        )
        #expect(gate(scored, .name)?.outcome == .fail)
    }

    @Test func noForenameAndNoInitialsFailsHonestly() {
        let scored = classify(
            militaryRecord(givenName: nil, initials: nil),
            subject: subject(givenName: "Ernest")
        )
        let name = gate(scored, .name)
        #expect(name?.outcome == .fail)
        #expect(name?.reason.contains("no forename or initials") == true)
    }

    @Test func dottedInitialsFormatIsAccepted() {
        // CWGC occasionally punctuates: "E.V."
        let scored = classify(
            militaryRecord(givenName: nil, initials: "E.V."),
            subject: subject(givenName: "Ernest", middleName: "Victor")
        )
        #expect(gate(scored, .name)?.outcome == .pass)
    }
}

/// T1-11 — parsed fields no longer dropped at the projection layer.
struct CWGCProjectionTests {

    @Test func militaryProjectionCarriesHonoursAndCountryOfService() {
        let record = SourceRecord.military(MilitaryRecord(
            common: RecordCommon(
                id: "cwgc_400001", sourceID: "cwgc",
                name: "Ernest Cauldwell", surname: "Cauldwell", givenName: "Ernest",
                detailURL: nil,
                rawFields: [
                    "honours": "M M",
                    "country_of_service": "United Kingdom",
                ]
            ),
            rank: "Serjeant", regiment: "Sherwood Foresters", unit: nil,
            serviceNumber: "12345",
            dateOfDeath: "21 March 1918", deathYear: 1918,
            age: 31, cemetery: "Arras Memorial", graveRef: "Bay 7",
            additionalInfo: nil
        ))
        let event = record.projectToLifeEvent(profileID: "profile-1")
        guard case .military(let details)? = event?.details else {
            Issue.record("expected military details on the projected LifeEvent")
            return
        }
        #expect(details.honours == "M M")
        #expect(details.countryOfService == "United Kingdom")
    }

    @Test func burialProjectionCarriesFindAGravePlot() {
        let record = SourceRecord.burial(BurialRecord(
            common: RecordCommon(
                id: "findagrave_98765", sourceID: "findagrave",
                name: "Ernest Cauldwell", surname: "Cauldwell", givenName: "Ernest",
                detailURL: nil,
                rawFields: ["plot": "Section B, Plot 12"]
            ),
            deathYear: 1959,
            cemetery: "Belper Cemetery",
            isVeteran: false
        ))
        let event = record.projectToLifeEvent(profileID: "profile-1")
        guard case .burial(let details)? = event?.details else {
            Issue.record("expected burial details on the projected LifeEvent")
            return
        }
        #expect(details.plot == "Section B, Plot 12")
    }

    @Test func emptyRawFieldsStayNilAtProjection() {
        let record = SourceRecord.military(MilitaryRecord(
            common: RecordCommon(
                id: "cwgc_400002", sourceID: "cwgc",
                name: "E Cauldwell", surname: "Cauldwell", givenName: nil,
                detailURL: nil, rawFields: [:]
            ),
            dateOfDeath: "1 July 1916", deathYear: 1916
        ))
        let event = record.projectToLifeEvent(profileID: "profile-1")
        guard case .military(let details)? = event?.details else {
            Issue.record("expected military details on the projected LifeEvent")
            return
        }
        #expect(details.honours == nil)
        #expect(details.countryOfService == nil)
    }
}
