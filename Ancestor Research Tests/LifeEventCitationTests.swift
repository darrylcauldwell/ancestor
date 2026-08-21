import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// An accepted event-shaped fact landed a life event with no citation on it.
///
/// `applyPendingFactAsLifeEvent` built its `LifeEvent` without touching
/// `sources`, which defaults to `[]`. The submission's title and URL were in
/// scope at the accept site the whole time — they went to the profile's
/// `field_sources` row and nowhere else.
///
/// That row is filed under a FIELD name ("residence"), so once a profile holds
/// several residences nothing says which citation backs which event. Live case
/// 2026-08-21: six Thompson-line ancestors took fifteen FamilySearch census
/// events — John William Thompson alone got 1871, 1881, 1901 and 1911 — and
/// every event row read `sources: []` while four distinct arks sat on the
/// profile with no way to pair them up. An event that reads as uncited is an
/// event a reader cannot check.
@MainActor
struct LifeEventCitationTests {

    private func makeDB() throws -> ProjectDatabase {
        let db = try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
        _ = try db.addProfile(
            Profile(id: "@P1@", firstName: "John", lastName: "Thompson", gender: .male,
                    birthDate: GenealogicalDate(parsing: "1853"),
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        return db
    }

    private let ark = "https://www.familysearch.org/ark:/61903/1:1:X7TG-JLP"

    private func payload(date: String, location: String) -> String {
        #"{"event_date":"\#(date)","event_location":"\#(location)"}"#
    }

    /// The live regression, end to end.
    @Test func anAcceptedCensusResidenceCarriesItsArkOnTheEventRow() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "residence",
            value: "Age 57, dairy farmer, head of household",
            payloadJSON: payload(date: "1911", location: "Wirksworth, Derbyshire"),
            sourceTitle: "1911 census: John Thompson household, Wirksworth",
            sourceURL: ark)

        let events = try db.loadLifeEvents(profileID: "@P1@")
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.type == .residence)
        #expect(event.date?.bestYear == 1911)
        #expect(event.location == "Wirksworth, Derbyshire")
        #expect(event.sources.count == 1, "the event must carry its own citation")
        #expect(event.sources.first?.citation?.url == ark)
        #expect(event.sources.first?.origin.identifier == "field-researcher")
    }

    /// Every event-shaped field routes through the same builder, so the
    /// citation must ride on all of them — occupation was the other field the
    /// six ancestors received.
    @Test func everyEventShapedFieldLandsCited() throws {
        for field in ["occupation", "residence", "census", "baptism", "burial", "probate"] {
            let db = try makeDB()
            try db.applyAcceptedPendingFact(
                profileID: "@P1@", field: field, value: "value for \(field)",
                payloadJSON: payload(date: "1881", location: "Youlgreave"),
                sourceTitle: "1881 census", sourceURL: ark)

            let events = try db.loadLifeEvents(profileID: "@P1@")
            #expect(events.count == 1, "\(field) should land exactly one event")
            #expect(events.first?.sources.first?.citation?.url == ark,
                    "\(field) landed uncited")
        }
    }

    /// A submission with a title but no URL is still worth citing — a GRO index
    /// reference or a parish register page has no link.
    @Test func aTitleWithoutAURLStillCites() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "occupation", value: "Farmer of 280 acres",
            payloadJSON: nil, sourceTitle: "RG11 piece 3448, folio 63, page 5",
            sourceURL: nil)

        let source = try #require(try db.loadLifeEvents(profileID: "@P1@").first?.sources.first)
        #expect(source.citation?.title == "RG11 piece 3448, folio 63, page 5")
        #expect(source.citation?.url == nil)
    }

    /// No provenance at all must leave `sources` empty rather than attach a
    /// blank citation. An empty citation is worse than none: it renders as a
    /// source badge on a fact nobody can trace.
    @Test func anUnsourcedSubmissionGetsNoFabricatedCitation() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "occupation", value: "Farmer",
            payloadJSON: nil, sourceTitle: "  ", sourceURL: "")

        #expect(try db.loadLifeEvents(profileID: "@P1@").first?.sources.isEmpty == true)
        #expect(ProjectDatabase.pendingFactEventSource(title: nil, url: nil) == nil)
        #expect(ProjectDatabase.pendingFactEventSource(title: "", url: "  ") == nil)
    }

    /// The deterministic event id still prevents duplicates, and re-accepting
    /// must not stack a second copy of the same citation onto the one event.
    @Test func reAcceptingDuplicatesNeitherEventNorCitation() throws {
        let db = try makeDB()
        for _ in 0..<3 {
            try db.applyAcceptedPendingFact(
                profileID: "@P1@", field: "residence", value: "Age 57, dairy farmer",
                payloadJSON: payload(date: "1911", location: "Wirksworth"),
                sourceTitle: "1911 census", sourceURL: ark)
        }

        let events = try db.loadLifeEvents(profileID: "@P1@")
        #expect(events.count == 1)
        #expect(events.first?.sources.count == 1, "the same citation must not stack")
    }

    /// A resubmission that ADDS provenance to an event accepted without any
    /// must attach it. `addLifeEventIfAbsent` no-ops on the existing row, so
    /// without the append the correction would be silently discarded — the
    /// same "reported success, changed nothing" class this path already fixed
    /// once for unsupported fields.
    @Test func aLaterCitationAttachesToAnAlreadyUncitedEvent() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "residence", value: "Age 57, dairy farmer",
            payloadJSON: payload(date: "1911", location: "Wirksworth"),
            sourceTitle: nil, sourceURL: nil)
        #expect(try db.loadLifeEvents(profileID: "@P1@").first?.sources.isEmpty == true)

        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "residence", value: "Age 57, dairy farmer",
            payloadJSON: payload(date: "1911", location: "Wirksworth"),
            sourceTitle: "1911 census", sourceURL: ark)

        let events = try db.loadLifeEvents(profileID: "@P1@")
        #expect(events.count == 1, "the citation must attach, not mint a second event")
        #expect(events.first?.sources.first?.citation?.url == ark)
    }

    /// A genuinely different citation for the same event — a second record
    /// corroborating it — is additive, not a duplicate.
    @Test func aDifferentCitationForTheSameEventIsAdded() throws {
        let db = try makeDB()
        let other = "https://www.freecen.org.uk/search_records/abc/john-thompson-1911"
        for url in [ark, other] {
            try db.applyAcceptedPendingFact(
                profileID: "@P1@", field: "residence", value: "Age 57, dairy farmer",
                payloadJSON: payload(date: "1911", location: "Wirksworth"),
                sourceTitle: "1911 census", sourceURL: url)
        }

        let sources = try #require(try db.loadLifeEvents(profileID: "@P1@").first?.sources)
        #expect(Set(sources.compactMap { $0.citation?.url }) == [ark, other])
    }

    /// The profile-column half of the same defect: `addFieldResearcherProvenance`
    /// wrote a title glued into `raw` and left `citation_json` null, so an
    /// accepted fact looked sourced but linked to nothing.
    @Test func profileFieldProvenanceCarriesACitationURL() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "birthLocation", value: "Middleton, Derbyshire")
        try db.addAcceptedFactProvenance(
            profileID: "@P1@", field: "birthLocation", value: "Middleton, Derbyshire",
            sourceTitle: "1871 census", sourceURL: ark)

        let sources = try #require(try db.loadProfile(id: "@P1@")?.sources[.birthLocation])
        let researcher = try #require(sources.first { $0.origin.identifier == "field-researcher" })
        #expect(researcher.citation?.url == ark)
        #expect(researcher.citation?.title == "1871 census")
    }

    /// The provenance must name the PRODUCER that submitted the fact.
    ///
    /// `'field-researcher'` was a string literal in the INSERT, so every
    /// accepted pending fact wore that badge whatever wrote it — the app's own
    /// `research-run`, `subject-spouse-marriage`, `subject-self-narrowing` and
    /// `prose-extractor:<corpus>` detectors all included.
    ///
    /// Live case 2026-08-21: a death date of 1929 produced by the app's own
    /// research pipeline (agent `research-run`, run 679B3504) displayed on the
    /// profile as field-researcher, so the owner reasonably concluded the
    /// assistant had submitted it. Misattribution doesn't merely mislabel a
    /// row — it sends the human to the wrong place to fix the cause.
    @Test func provenanceNamesTheProducerNotAlwaysFieldResearcher() throws {
        for agent in ["research-run", "subject-spouse-marriage",
                      "subject-self-narrowing", "prose-extractor:corpus-7",
                      "field-researcher", "claude-code"] {
            let db = try makeDB()
            try db.addAcceptedFactProvenance(
                profileID: "@P1@", field: "birthLocation", value: "Middleton",
                sourceTitle: "1871 census", sourceURL: ark, origin: agent)

            let sources = try #require(try db.loadProfile(id: "@P1@")?.sources[.birthLocation])
            #expect(sources.contains { $0.origin.identifier == agent },
                    "expected origin \(agent), got \(sources.map(\.origin.identifier))")
        }
    }

    /// An in-app producer must NOT be attributed to the MCP agent — the
    /// specific misattribution the owner hit.
    @Test func anInAppPipelineFactIsNotBadgedAsFieldResearcher() throws {
        let db = try makeDB()
        try db.addAcceptedFactProvenance(
            profileID: "@P1@", field: "deathDate", value: "1929",
            sourceTitle: "freebmd", origin: "research-run")

        let sources = try #require(try db.loadProfile(id: "@P1@")?.sources[.deathDate])
        #expect(sources.contains { $0.origin.identifier == "research-run" })
        #expect(!sources.contains { $0.origin.identifier == "field-researcher" },
                "the app's own pipeline output must not wear the MCP agent's badge")
    }

    /// A blank agent id must fall back rather than write an empty origin — an
    /// unattributed row is worse than a generically attributed one.
    @Test func aBlankAgentIDFallsBackRatherThanWritingNothing() throws {
        for blank in ["", "   "] {
            let db = try makeDB()
            try db.addAcceptedFactProvenance(
                profileID: "@P1@", field: "birthLocation", value: "Middleton",
                sourceTitle: "1871 census", origin: blank)

            let sources = try #require(try db.loadProfile(id: "@P1@")?.sources[.birthLocation])
            #expect(sources.contains { $0.origin.identifier == "field-researcher" })
            #expect(!sources.contains { $0.origin.identifier.isEmpty })
        }
    }

    /// Omitting the URL stays valid — the pre-existing callers pass only a
    /// title, and they must keep working rather than start throwing.
    @Test func provenanceWithoutAURLStillWrites() throws {
        let db = try makeDB()
        try db.addAcceptedFactProvenance(
            profileID: "@P1@", field: "birthLocation", value: "Middleton, Derbyshire",
            sourceTitle: "1871 census")

        let sources = try #require(try db.loadProfile(id: "@P1@")?.sources[.birthLocation])
        let researcher = try #require(sources.first { $0.origin.identifier == "field-researcher" })
        #expect(researcher.citation?.title == "1871 census")
        #expect(researcher.citation?.url == nil)
    }
}
