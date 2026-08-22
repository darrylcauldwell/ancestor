import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// A baptism's parents must reach the family offer, and a record the app
/// cannot read must not go quiet.
///
/// Owner dogfood 2026-08-22. Jacob Holmes's applied 1817 Youlgreave baptism
/// names **John HOLMES** and **Sophia**. The card rendered both; the
/// `familyContext` gate scored with them. Yet no "add his parents" offer
/// appeared on the profile *or* in the Health sweep — because both read
/// `parishFamilyProposal`, which required a typed `detail`, and FreeREG
/// results-table rows carry only the flat `fatherName`/`motherName`
/// projection.
///
/// Two fixes, pinned here:
///  1. synthesize the baptism detail from the flat parents, so the offer forms
///  2. a Health finding when kin ARE named and no offer can be built — the net
///     under the offers, so silence is never the failure mode
@MainActor
struct ParishKinReadabilityTests {

    private func makeAppState() throws -> AppState {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        let appState = AppState()
        appState.currentDatabase = db
        return appState
    }

    /// Jacob's baptism exactly as FreeREG returns it from a results-table row:
    /// flat parents, NO typed detail.
    private func jacobBaptism(
        id: String = "bapt",
        father: String? = "John HOLMES",
        mother: String? = "Sophia",
        eventType: String = "baptism"
    ) -> ParishRecord {
        ParishRecord(
            common: RecordCommon(id: id, sourceID: "freereg", name: "Jacob HOLMES",
                                 surname: "HOLMES", givenName: "Jacob",
                                 detailURL: "https://freereg/\(id)", rawFields: [:]),
            eventType: eventType, eventDate: "10 Aug 1817", eventYear: 1817,
            parish: "Youlgreave", county: "Derbyshire",
            fatherName: father, motherName: mother, detail: nil)
    }

    private func jacob() -> Profile {
        Profile(id: "jacob", firstName: "Jacob", lastName: "Holmes",
                gender: .male, isDeleted: false, sources: [:], disputes: [:])
    }

    // MARK: - The synthesis

    /// THE SPECIMEN: flat parents, no detail → a baptism detail is synthesized.
    @Test func flatParentsOnABaptismSynthesizeADetail() throws {
        let detail = try #require(
            AppState.baptismDetailFromFlatParents(record: jacobBaptism()),
            "a baptism naming both parents must yield a detail even with no typed payload")
        guard case .baptism(let bap) = detail.event else {
            Issue.record("expected a baptism event"); return
        }
        #expect(bap.father?.forename == "John")
        #expect(bap.father?.surname == "HOLMES")
        #expect(bap.mother?.person.forename == "Sophia")
        #expect(bap.mother?.person.surname == nil, "a bare forename must not invent a maiden surname")
    }

    /// And that detail must produce BOTH parent links.
    @Test func theSynthesizedDetailYieldsBothParents() throws {
        let detail = try #require(AppState.baptismDetailFromFlatParents(record: jacobBaptism()))
        let (links, kind) = AppState.parishFamilyLinks(
            subject: jacob(), record: jacobBaptism(), detail: detail)
        #expect(kind == .baptism)
        #expect(links.count == 2, "John and Sophia — got \(links.map { $0.given ?? "?" })")
        #expect(links.allSatisfy { $0.relation == .parent })
        #expect(links.contains { $0.given == "John" && $0.gender == .male })
        #expect(links.contains { $0.given == "Sophia" && $0.gender == .female })
    }

    /// A mother with no surname of her own inherits the child's as her MARRIED
    /// name — never as a maiden name we don't have.
    @Test func aSurnamelessMotherTakesTheChildsSurnameAsMarriedOnly() throws {
        let detail = try #require(AppState.baptismDetailFromFlatParents(record: jacobBaptism()))
        let links = AppState.parishFamilyLinks(
            subject: jacob(), record: jacobBaptism(), detail: detail).0
        let mother = try #require(links.first { $0.gender == .female })
        #expect(mother.birthSurname == nil, "no evidence of her maiden name — must stay blank")
        #expect(mother.marriedSurname == "Holmes")
    }

    /// Only baptisms. A marriage keeps its own (co-persons) path, and a record
    /// naming nobody yields nothing.
    @Test func synthesisIsScopedToBaptismsThatNameSomeone() {
        #expect(AppState.baptismDetailFromFlatParents(
            record: jacobBaptism(eventType: "marriage")) == nil)
        #expect(AppState.baptismDetailFromFlatParents(
            record: jacobBaptism(father: nil, mother: nil)) == nil)
        #expect(AppState.baptismDetailFromFlatParents(
            record: jacobBaptism(father: "John HOLMES", mother: nil)) != nil,
            "one named parent is still worth an offer")
    }

    /// "Christening" is the same event under another label.
    @Test func christeningCountsAsBaptism() {
        #expect(AppState.baptismDetailFromFlatParents(
            record: jacobBaptism(eventType: "Christening")) != nil)
    }

    // MARK: - Name splitting

    @Test func flatNamesSplitIntoForenameAndSurname() {
        #expect(AppState.parishPerson(fromFlatName: "John HOLMES")?.surname == "HOLMES")
        #expect(AppState.parishPerson(fromFlatName: "John HOLMES")?.forename == "John")
        #expect(AppState.parishPerson(fromFlatName: "Sophia")?.forename == "Sophia")
        #expect(AppState.parishPerson(fromFlatName: "Sophia")?.surname == nil)
        #expect(AppState.parishPerson(fromFlatName: "Mary Ann STEPHENSON")?.forename == "Mary Ann")
        #expect(AppState.parishPerson(fromFlatName: "   ") == nil)
        #expect(AppState.parishPerson(fromFlatName: nil) == nil)
    }

    // MARK: - The Health net

    /// A record whose kin CAN now be read produces no "unreadable" finding —
    /// it goes to the ordinary absorption offer instead.
    @Test func aReadableBaptismRaisesNoUnreadableFinding() throws {
        let appState = try makeAppState()
        let db = try #require(appState.currentDatabase)
        _ = try db.addProfile(jacob(), source: .gedcom)
        let scored = ScoredRecord(id: "bapt", record: .parish(jacobBaptism()),
                                  verdict: .fact, gates: [], summary: "")
        try db.saveEvidence(profileID: "jacob", scored: scored,
                            citationFull: "Youlgreave Parish Register, baptism of Jacob HOLMES, 1817.",
                            citationURL: "https://freereg/bapt")
        try db.updateEvidenceUserStatus(profileID: "jacob", sourceRecordIDs: ["bapt"], status: .savedAsLead)
        appState.snapshot = try db.buildSnapshot()

        #expect(appState.parishKinUnreadableFindings().isEmpty,
                "the synthesis handles this one — it must not ALSO be reported as unreadable")
    }

    /// A record that names kin the app genuinely cannot lift DOES raise one —
    /// silence is never the failure mode. Here: a burial naming a relative with
    /// no parent relationship word, so no link can be derived.
    @Test func namedKinThatCannotBeLiftedBecomesAFinding() throws {
        let appState = try makeAppState()
        let db = try #require(appState.currentDatabase)
        _ = try db.addProfile(jacob(), source: .gedcom)
        // A burial with a flat father name — burials take their relative from
        // typed detail only, so nothing can be lifted from the flat field.
        let record = ParishRecord(
            common: RecordCommon(id: "bur", sourceID: "freereg", name: "Jacob HOLMES",
                                 surname: "HOLMES", givenName: "Jacob",
                                 detailURL: "https://freereg/bur", rawFields: [:]),
            eventType: "burial", eventDate: "19 Mar 1870", eventYear: 1870,
            parish: "Youlgreave", county: "Derbyshire",
            fatherName: "John HOLMES", motherName: nil, detail: nil)
        let scored = ScoredRecord(id: "bur", record: .parish(record),
                                  verdict: .fact, gates: [], summary: "")
        try db.saveEvidence(profileID: "jacob", scored: scored,
                            citationFull: "Youlgreave Parish Register, burial of Jacob HOLMES, 1870.",
                            citationURL: "https://freereg/bur")
        try db.updateEvidenceUserStatus(profileID: "jacob", sourceRecordIDs: ["bur"], status: .savedAsLead)
        appState.snapshot = try db.buildSnapshot()

        let findings = appState.parishKinUnreadableFindings()
        #expect(findings.count == 1, "a named relative the app can't lift must be a visible work item")
        let finding = try #require(findings.first)
        #expect(finding.ruleID == "parishKinUnreadable")
        #expect(finding.message.contains("John HOLMES"), "the finding must NAME who was missed")
        #expect(finding.severity == .warning)
    }

    /// An UNREVIEWED record raises nothing — the sweep is about applied
    /// evidence, not about every candidate the pipeline ever scored.
    @Test func unappliedRecordsRaiseNoFinding() throws {
        let appState = try makeAppState()
        let db = try #require(appState.currentDatabase)
        _ = try db.addProfile(jacob(), source: .gedcom)
        let record = ParishRecord(
            common: RecordCommon(id: "bur", sourceID: "freereg", name: "Jacob HOLMES",
                                 surname: "HOLMES", givenName: "Jacob",
                                 detailURL: "https://freereg/bur", rawFields: [:]),
            eventType: "burial", eventYear: 1870,
            fatherName: "John HOLMES", detail: nil)
        try db.saveEvidence(profileID: "jacob",
                            scored: ScoredRecord(id: "bur", record: .parish(record),
                                                 verdict: .lead, gates: [], summary: ""),
                            citationFull: "…", citationURL: "https://freereg/bur")
        appState.snapshot = try db.buildSnapshot()

        #expect(appState.parishKinUnreadableFindings().isEmpty)
    }

    /// A record naming nobody is not a gap.
    @Test func aRecordNamingNoKinRaisesNoFinding() {
        #expect(AppState.parishNamedKin(in: jacobBaptism(father: nil, mother: nil)).isEmpty)
        #expect(AppState.parishNamedKin(in: jacobBaptism()) == ["John HOLMES", "Sophia"])
    }

    /// Co-persons (a marriage's other party) count as named kin too.
    @Test func coPersonsCountAsNamedKin() {
        let record = ParishRecord(
            common: RecordCommon(id: "m", sourceID: "freereg", name: "Jacob HOLMES",
                                 surname: "HOLMES", givenName: "Jacob", detailURL: nil,
                                 rawFields: ["co_persons": "Mary STEVENSON; James BIRDS"]),
            eventType: "marriage", eventYear: 1846)
        #expect(AppState.parishNamedKin(in: record) == ["Mary STEVENSON", "James BIRDS"])
    }
}
