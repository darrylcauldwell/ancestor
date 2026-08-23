import Testing
import Foundation
@testable import Ancestor_Research

/// A bride must not fail the name gate on her own marriage.
///
/// A parish MARRIAGE row names both parties; the parser titles the record
/// after the FIRST — usually the groom — and keeps the other(s) in
/// rawFields["co_persons"] "for the scorer". The scorer never read it.
///
/// Owner dogfood 2026-08-23: Mary Stevenson's re-research fetched "Youlgreave
/// Parish Register, marriage of Jacob HOLMES, 1846" — the keystone record
/// naming BOTH fathers — because FreeREG matched HER as the bride. The name
/// gate compared "Jacob HOLMES" against Mary Stevenson, failed, and ruled her
/// own wedding .impossible. Any woman searching her own parish marriage
/// failed her own record unless she happened to be listed first.
@MainActor
struct CoPrincipalNameGateTests {

    /// The record exactly as the run persisted it: titled after the groom,
    /// bride in co_persons.
    private func marriageRow(coPersons: String?) -> SourceRecord {
        var raw: [String: String] = ["event_type": "marriage"]
        if let coPersons { raw["co_persons"] = coPersons }
        return .parish(ParishRecord(
            common: RecordCommon(id: "m", sourceID: "freereg", name: "Jacob HOLMES",
                                 surname: "HOLMES", givenName: "Jacob",
                                 detailURL: nil, rawFields: raw),
            eventType: "marriage", eventDate: "19 Jan 1846", eventYear: 1846,
            parish: "Youlgreave", county: "Derbyshire"))
    }

    private func mary() -> ResearchSubject {
        ResearchSubject(
            profileID: "mary", surname: "Stevenson", givenName: "Mary",
            birthYearFrom: 1824, birthYearTo: 1825,
            birthAnchorIsDerived: true,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .female, region: nil, mode: .adaptive,
            familyContext: nil, homeChapmanCode: "DBY")
    }

    /// THE SPECIMEN: her own wedding, titled after the groom, must survive as
    /// a reviewable lead — never .impossible.
    @Test func theBrideSurvivesHerOwnMarriage() {
        let scored = RecordScorer.classify(
            record: marriageRow(coPersons: "Mary STEVENSON"),
            subject: mary(), searchType: .parish)
        #expect(scored.verdict != .impossible,
                "her own wedding was ruled impossible: \(scored.gates)")
        let name = scored.gates.first { $0.gate == .name }
        #expect(name?.outcome == .softFail,
                "co-principal identity deserves review, not a silent pass: \(String(describing: name))")
        #expect(name?.reason.contains("co-principal") == true)
    }

    /// A variant-spelled bride works too — the co-principal check runs through
    /// nameSimilarity, so STEPHENSON reaches STEVENSON.
    @Test func aVariantSpelledBrideAlsoSurvives() {
        let scored = RecordScorer.classify(
            record: marriageRow(coPersons: "Mary STEPHENSON"),
            subject: mary(), searchType: .parish)
        #expect(scored.verdict != .impossible)
    }

    /// A marriage whose bride is someone ELSE stays impossible — the rescue
    /// must not wave every wedding through.
    @Test func anUnrelatedBrideStaysFailed() {
        let scored = RecordScorer.classify(
            record: marriageRow(coPersons: "Hannah SLANEY"),
            subject: mary(), searchType: .parish)
        let name = scored.gates.first { $0.gate == .name }
        #expect(name?.outcome == .fail,
                "Hannah Slaney's wedding is not Mary Stevenson's: \(String(describing: name))")
    }

    /// A right-surname, wrong-forename co-principal stays failed — surname
    /// alone is a family, not a person.
    @Test func aWrongForenameCoPrincipalStaysFailed() {
        let scored = RecordScorer.classify(
            record: marriageRow(coPersons: "Harriet STEVENSON"),
            subject: mary(), searchType: .parish)
        let name = scored.gates.first { $0.gate == .name }
        #expect(name?.outcome == .fail)
    }

    /// No co_persons at all → the plain mismatch fail, exactly as before.
    @Test func noCoPersonsMeansThePlainFail() {
        let scored = RecordScorer.classify(
            record: marriageRow(coPersons: nil),
            subject: mary(), searchType: .parish)
        let name = scored.gates.first { $0.gate == .name }
        #expect(name?.outcome == .fail)
        #expect(name?.reason.contains("surname mismatch") == true)
    }

    /// The GROOM's side is untouched: Jacob searching the same record still
    /// passes on the primary name without touching the rescue.
    @Test func theGroomStillPassesOnThePrimaryName() {
        let jacob = ResearchSubject(
            profileID: "jacob", surname: "Holmes", givenName: "Jacob",
            birthYearFrom: 1817, birthYearTo: 1817,
            deathYearFrom: 1870, deathYearTo: 1870,
            gender: .male, region: nil, mode: .adaptive,
            familyContext: nil, homeChapmanCode: "DBY")
        let scored = RecordScorer.classify(
            record: marriageRow(coPersons: "Mary STEVENSON"),
            subject: jacob, searchType: .parish)
        let name = scored.gates.first { $0.gate == .name }
        #expect(name?.outcome == .pass, Comment(rawValue: String(describing: name)))
    }
}
