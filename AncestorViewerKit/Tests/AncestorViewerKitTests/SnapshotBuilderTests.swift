import Testing
import Foundation
import AncestorKit
@testable import AncestorViewerKit

struct SnapshotBuilderTests {

    private var manifest: ManifestRow {
        ManifestRow(id: "M1", generation: 3, rootPerson: "P1",
                    personCount: 2, relationshipCount: 1)
    }

    private var ernest: PersonRow {
        PersonRow(id: "P1", manifestID: "M1", displayName: "Ernest Cauldwell",
                  givenName: "Ernest", familyName: "Cauldwell", genderRaw: "male",
                  birthOriginal: "ABT 1887", birthEarliest: 1882, birthLatest: 1892,
                  birthQualifierRaw: "about", birthIsApproximate: true,
                  birthPlace: "Crich, Derbyshire",
                  deathOriginal: "1953", deathEarliest: 1953, deathLatest: 1953,
                  deathQualifierRaw: "yearOnly", deathIsApproximate: false,
                  bioText: "Ernest was a framework knitter.",
                  citationsJSON: #"[{"field":"birthDate","source":"FreeBMD Birth Index","url":"https://www.freebmd.org.uk/x","trustTier":2}]"#,
                  badgesJSON: #"{"completenessScore":5,"completenessMax":7,"convergence":"confirmed"}"#)
    }

    private var redactedMary: PersonRow {
        PersonRow(id: "P2", manifestID: "M1", displayName: "Mary Cauldwell",
                  citationsJSON: "[]", badgesJSON: "{}", isRedacted: true)
    }

    @Test func fullPersonMapsToProfileWithDatesAndBio() {
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [ernest], relationships: [], events: [], media: [])
        let profile = try! #require(tree.snapshot.profiles["P1"])
        #expect(profile.displayName == "Ernest Cauldwell")
        #expect(profile.gender == .male)
        #expect(profile.birthDate?.original == "ABT 1887")
        #expect(profile.birthDate?.earliest == 1882)
        #expect(profile.birthDate?.qualifier == .about)
        #expect(profile.birthDate?.isApproximate == true)
        #expect(profile.deathDate?.bestYear == 1953)
        #expect(profile.birthLocation == "Crich, Derbyshire")
        #expect(profile.bio == "Ernest was a framework knitter.")
    }

    @Test func annotationsCarryBadgesAndCitations() {
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [ernest], relationships: [], events: [], media: [])
        let notes = try! #require(tree.annotations["P1"])
        #expect(notes.badges?.completenessScore == 5)
        #expect(notes.badges?.convergence == "confirmed")
        #expect(notes.citations.count == 1)
        #expect(notes.citations.first?.trustTier == 2)
    }

    @Test func redactedPersonIsNameOnly() {
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [redactedMary], relationships: [], events: [], media: [])
        let profile = try! #require(tree.snapshot.profiles["P2"])
        #expect(profile.displayName == "Mary Cauldwell")
        #expect(profile.birthDate == nil)
        #expect(profile.deathDate == nil)
        #expect(profile.bio == nil)
        let notes = try! #require(tree.annotations["P2"])
        #expect(notes.isRedacted == true)
        #expect(notes.badges == nil)   // "{}" decodes to no badges (missing keys)
        #expect(notes.citations.isEmpty)
    }

    @Test func displayNameFidelityWinsOverNameParts() {
        // givenName carries a middle name the publisher folded in —
        // recomposition matches, parts are kept.
        let folded = PersonRow(id: "P3", manifestID: "M1",
                               displayName: "John Robert Smith",
                               givenName: "John Robert", familyName: "Smith")
        // Parts that DON'T recompose to displayName — displayName rides whole.
        let odd = PersonRow(id: "P4", manifestID: "M1",
                            displayName: "Mary Smith (Polly)",
                            givenName: "Mary", familyName: "Smith")
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [folded, odd], relationships: [], events: [], media: [])
        #expect(tree.snapshot.profiles["P3"]?.displayName == "John Robert Smith")
        #expect(tree.snapshot.profiles["P3"]?.lastName == "Smith")
        #expect(tree.snapshot.profiles["P4"]?.displayName == "Mary Smith (Polly)")
        #expect(tree.snapshot.profiles["P4"]?.lastName == nil)
    }

    @Test func spouseEdgeCarriesMarriageAndTraverses() {
        let rel = RelationshipRow(id: UUID().uuidString, fromPersonID: "P1", toPersonID: "P2",
                                  typeRaw: "spouse", subtypeRaw: "unknown",
                                  marriageOriginal: "1912", marriageEarliest: 1912,
                                  marriageLatest: 1912, marriageQualifierRaw: "yearOnly",
                                  marriageIsApproximate: false, marriageLocation: "Belper")
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [ernest, redactedMary],
            relationships: [rel], events: [], media: [])
        #expect(tree.snapshot.spousesOf("P1").map(\.id) == ["P2"])
        #expect(tree.snapshot.relationships.first?.marriageDate?.bestYear == 1912)
        #expect(tree.snapshot.relationships.first?.marriageLocation == "Belper")
    }

    @Test func edgesToMissingPersonsAndUnknownTypesAreDropped() {
        let dangling = RelationshipRow(id: "R9", fromPersonID: "P1", toPersonID: "GONE",
                                       typeRaw: "spouse")
        let future = RelationshipRow(id: "R10", fromPersonID: "P1", toPersonID: "P2",
                                     typeRaw: "guardian")
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [ernest, redactedMary],
            relationships: [dangling, future], events: [], media: [])
        #expect(tree.snapshot.relationships.isEmpty)
    }

    @Test func parentEdgeBuildsGenerations() {
        let child = PersonRow(id: "P5", manifestID: "M1", displayName: "Helen Cauldwell",
                              givenName: "Helen", familyName: "Cauldwell")
        let rel = RelationshipRow(id: "R2", fromPersonID: "P1", toPersonID: "P5",
                                  typeRaw: "parent", roleRaw: "father",
                                  subtypeRaw: "biological")
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [ernest, child],
            relationships: [rel], events: [], media: [])
        #expect(tree.snapshot.childrenOf("P1").map(\.id) == ["P5"])
        #expect(tree.snapshot.parentsOf("P5").map(\.id) == ["P1"])
        #expect(tree.snapshot.relationships.first?.role == .father)
    }

    @Test func eventsGroupSortAndTypeMap() {
        let census = EventRow(id: UUID().uuidString, personID: "P1", kindRaw: "census",
                              dateOriginal: "1911", dateEarliest: 1911, dateLatest: 1911,
                              dateQualifierRaw: "yearOnly", dateIsApproximate: false,
                              location: "Crich")
        let earlier = EventRow(id: UUID().uuidString, personID: "P1", kindRaw: "baptism",
                               dateEarliest: 1887, dateLatest: 1887)
        let unknownKind = EventRow(id: UUID().uuidString, personID: "P1", kindRaw: "spaceflight")
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [ernest], relationships: [],
            events: [census, earlier, unknownKind], media: [])
        let events = try! #require(tree.events["P1"])
        #expect(events.count == 3)
        #expect(events[0].type == .baptism)      // 1887 sorts first
        #expect(events[1].type == .census)
        #expect(events[2].type == .other)        // unknown kind degrades, never drops
    }

    @Test func mediaSortsPortraitsFirst() {
        let doc = MediaRow(id: "MD1", personID: "P1", kind: "document", relativePath: "d.pdf")
        let portrait = MediaRow(id: "MD2", personID: "P1", kind: "portrait", relativePath: "p.jpg")
        let tree = SnapshotBuilder.build(
            manifest: manifest, persons: [ernest], relationships: [],
            events: [], media: [doc, portrait])
        #expect(tree.media["P1"]?.first?.kind == "portrait")
    }

    @Test func suggestedRootPrefersManifestThenConnectivity() {
        // Manifest root present in the published set → wins.
        let withRoot = SnapshotBuilder.build(
            manifest: manifest, persons: [ernest, redactedMary], relationships: [], events: [], media: [])
        #expect(withRoot.suggestedRootID == "P1")

        // Rootless manifest → best-connected person, never an isolated one.
        let rootless = ManifestRow(id: "M2")
        let isolated = PersonRow(id: "A0", manifestID: "M2", displayName: "Aaaa Alone")
        let child = PersonRow(id: "P5", manifestID: "M2", displayName: "Helen Cauldwell",
                              givenName: "Helen", familyName: "Cauldwell")
        let rels = [
            RelationshipRow(id: "R1", fromPersonID: "P1", toPersonID: "P2", typeRaw: "spouse"),
            RelationshipRow(id: "R2", fromPersonID: "P1", toPersonID: "P5", typeRaw: "parent")
        ]
        let tree = SnapshotBuilder.build(
            manifest: rootless, persons: [isolated, ernest, redactedMary, child],
            relationships: rels, events: [], media: [])
        #expect(tree.suggestedRootID == "P1")   // degree 2 beats everyone; never "A0"
    }

    @Test func schemaVersionGuardFlags() {
        let futureManifest = ManifestRow(id: "M9", schemaVersion: ViewerSchema.supportedVersion + 1)
        let current = SnapshotBuilder.build(
            manifest: manifest, persons: [], relationships: [], events: [], media: [])
        let future = SnapshotBuilder.build(
            manifest: futureManifest, persons: [], relationships: [], events: [], media: [])
        #expect(current.schemaExceedsSupported == false)
        #expect(future.schemaExceedsSupported == true)
    }
}
