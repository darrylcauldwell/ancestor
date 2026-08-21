import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Accepting a pending fact used to change nothing for most fields.
///
/// `applyAcceptedPendingFact` mapped four fields and its default arm simply
/// `return`ed — the comment said so: *"Narrative-only fields (occupation/
/// address) have no profile column"*. Meanwhile `submit_evidence` advertised
/// `occupation`, the accept flow marked the fact accepted, wrote provenance
/// into `field_sources`, and reported success. The profile never changed.
///
/// Same shape as the applied marriage that wrote no spouse: the action says it
/// worked, the data says otherwise, and nothing complains. Every column the
/// profiles table actually has is mapped now, event-shaped fields become life
/// events, and anything genuinely unsupported THROWS.
@MainActor
struct PendingFactFieldCoverageTests {

    private func makeDB() throws -> ProjectDatabase {
        let db = try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
        _ = try db.addProfile(
            Profile(id: "@P1@", firstName: "George", lastName: "Land", gender: .male,
                    birthDate: GenealogicalDate(parsing: "1864"),
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        return db
    }

    // MARK: - Profile columns that used to silently no-op

    /// The one that would have fixed Eve Land without inventing a spouse.
    @Test func marriedSurnameLandsOnTheProfile() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "marriedSurname", value: "Gould")
        #expect(try db.loadProfile(id: "@P1@")?.marriedSurname == "Gould")
    }

    @Test func mothersMaidenNameLandsOnTheProfile() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "mothersMaidenName", value: "Hodgkinson")
        #expect(try db.loadProfile(id: "@P1@")?.mothersMaidenName == "Hodgkinson")
    }

    @Test func namePartsLandOnTheProfile() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(profileID: "@P1@", field: "middleName", value: "William")
        try db.applyAcceptedPendingFact(profileID: "@P1@", field: "firstName", value: "Geo")
        let p = try db.loadProfile(id: "@P1@")
        #expect(p?.middleName == "William")
        #expect(p?.firstName == "Geo")
    }

    /// The four that always worked must keep working.
    @Test func theOriginalFourStillLand() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "birthLocation", value: "Wirksworth, Derbyshire")
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "deathDate", value: "Mar 1942")
        let p = try db.loadProfile(id: "@P1@")
        #expect(p?.birthLocation == "Wirksworth, Derbyshire")
        #expect(p?.deathDate?.bestYear == 1942)
    }

    // MARK: - Event-shaped fields become life events

    /// George's 1901 occupation — the specimen. It reported success and did
    /// nothing before.
    @Test func occupationBecomesADatedLifeEvent() throws {
        let db = try makeDB()
        let payload = #"{"event_date":"1901","event_location":"Wirksworth, Derbyshire"}"#
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "occupation",
            value: "Lime stone quarry labourer", payloadJSON: payload)

        let events = try db.loadAllLifeEvents().filter { $0.profileID == "@P1@" }
        #expect(events.count == 1)
        #expect(events.first?.type == .occupation)
        #expect(events.first?.description == "Lime stone quarry labourer")
        #expect(events.first?.date?.bestYear == 1901)
        #expect(events.first?.location == "Wirksworth, Derbyshire")
    }

    @Test func residenceAndCensusAlsoBecomeEvents() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "residence", value: "Bolehill",
            payloadJSON: #"{"event_date":"1901"}"#)
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "census", value: "1901 census, Wirksworth",
            payloadJSON: #"{"event_date":"1901"}"#)

        let types = Set(try db.loadAllLifeEvents()
            .filter { $0.profileID == "@P1@" }.map(\.type))
        #expect(types == [.residence, .census])
    }

    /// An undated occupation is still a true statement worth holding. The
    /// alternative — inventing a year so the row looks complete — is worse.
    @Test func anUndatedEventIsStillRecorded() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "occupation", value: "Lead miner")
        let events = try db.loadAllLifeEvents().filter { $0.profileID == "@P1@" }
        #expect(events.count == 1)
        #expect(events.first?.date == nil)
    }

    /// Accepting the same fact twice — or a resubmission upsert — must not
    /// mint a second event. The id is a fingerprint of what the event IS.
    @Test func acceptingTheSameEventTwiceDoesNotDuplicateIt() throws {
        let db = try makeDB()
        let payload = #"{"event_date":"1901"}"#
        for _ in 0..<3 {
            try db.applyAcceptedPendingFact(
                profileID: "@P1@", field: "occupation",
                value: "Lime stone quarry labourer", payloadJSON: payload)
        }
        #expect(try db.loadAllLifeEvents().filter { $0.profileID == "@P1@" }.count == 1)
    }

    /// A different year is a different event, not a duplicate.
    @Test func theSameOccupationInADifferentYearIsASeparateEvent() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "occupation", value: "Lead miner",
            payloadJSON: #"{"event_date":"1891"}"#)
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "occupation", value: "Lead miner",
            payloadJSON: #"{"event_date":"1901"}"#)
        #expect(try db.loadAllLifeEvents().filter { $0.profileID == "@P1@" }.count == 2)
    }

    // MARK: - Anything else refuses, loudly

    @Test func anUnsupportedFieldThrowsRatherThanSilentlyDoingNothing() throws {
        let db = try makeDB()
        #expect(throws: ProjectDatabase.UnsupportedPendingFactField.self) {
            try db.applyAcceptedPendingFact(
                profileID: "@P1@", field: "favouriteColour", value: "blue")
        }
    }

    /// The refusal has to say what happened, since it surfaces to the user.
    @Test func theRefusalNamesTheFieldAndExplainsItself() throws {
        let error = ProjectDatabase.UnsupportedPendingFactField(field: "favouriteColour")
        #expect(error.errorDescription?.contains("favouriteColour") == true)
        #expect(error.errorDescription?.contains("nothing would change") == true)
    }

    /// A refused field must leave the profile and the events untouched — no
    /// partial write.
    @Test func aRefusedFieldChangesNothing() throws {
        let db = try makeDB()
        let before = try db.loadProfile(id: "@P1@")
        try? db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "favouriteColour", value: "blue")
        #expect(try db.loadProfile(id: "@P1@")?.firstName == before?.firstName)
        #expect(try db.loadAllLifeEvents().filter { $0.profileID == "@P1@" }.isEmpty)
    }

    // MARK: - The two routing tables agree

    /// Every event-shaped field must resolve to a life-event type, and no
    /// profile-column field may also be treated as an event.
    @Test func fieldRoutingIsUnambiguous() {
        for field in ["occupation", "residence", "census", "baptism", "burial",
                      "probate", "military", "education", "religion",
                      "immigration", "emigration", "address"] {
            #expect(ProjectDatabase.lifeEventType(forPendingFactField: field) != nil,
                    "event field with no life-event type would be refused")
        }
        for field in ["birthDate", "deathDate", "birthLocation", "deathLocation",
                      "firstName", "lastName", "marriedSurname", "mothersMaidenName"] {
            #expect(ProjectDatabase.lifeEventType(forPendingFactField: field) == nil,
                    "\(field) is a profile column and must not also route to an event")
        }
    }

    /// THE CONTRACT. This is the canonical vocabulary the accept path can
    /// land, and `MCPServer.submit_evidence`'s `validFields` must mirror it
    /// exactly. The two had drifted apart in BOTH directions: `residence` was
    /// refused at submission while the app could land it, and
    /// `marriageDate`/`marriageLocation` were accepted at submission while the
    /// app could never land them — marriage data lives on the spouse EDGE, not
    /// a profile column, so they silently did nothing.
    ///
    /// Anything added here must be added there, and vice versa.
    @Test func everySupportedFieldActuallyLands() throws {
        let profileFields = [
            "birthDate", "deathDate", "baptismDate", "burialDate",
            "birthLocation", "deathLocation", "birthLocationCode", "deathLocationCode",
            "firstName", "givenName", "middleName", "lastName", "surname",
            "nickName", "gender", "marriedSurname", "mothersMaidenName", "bio",
        ]
        let eventFields = [
            "occupation", "residence", "address", "census",
            "baptism", "christening", "burial", "probate",
            "military", "militaryService", "education", "religion",
            "immigration", "emigration",
        ]
        for field in profileFields + eventFields {
            let db = try makeDB()
            #expect(throws: Never.self, "\(field) is advertised but cannot be landed") {
                try db.applyAcceptedPendingFact(
                    profileID: "@P1@", field: field, value: "x",
                    payloadJSON: #"{"event_date":"1901"}"#)
            }
        }
    }

    /// Marriage belongs to the relationship edge. It must NOT quietly pass —
    /// it was accepted at submission for months and did nothing on accept.
    @Test func marriageFieldsAreRefusedRatherThanSilentlyIgnored() throws {
        let db = try makeDB()
        for field in ["marriageDate", "marriageLocation"] {
            #expect(throws: ProjectDatabase.UnsupportedPendingFactField.self) {
                try db.applyAcceptedPendingFact(
                    profileID: "@P1@", field: field, value: "Sep 1882")
            }
        }
    }

    /// `baptismDate`/`burialDate` are DATE fields on the profile, distinct from
    /// the `baptism`/`burial` EVENTS. Easy to conflate; pinned.
    @Test func baptismDateIsAProfileDateNotAnEvent() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "@P1@", field: "baptismDate", value: "12 Mar 1848")
        #expect(try db.loadProfile(id: "@P1@")?.birthDate?.bestYear == 1848)
        #expect(try db.loadAllLifeEvents().filter { $0.profileID == "@P1@" }.isEmpty)
    }
}
