import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

// PUBLISHER_SPEC Change 6 acceptance — bios from committed facts only,
// snapshot-tested prose, and the relative-redaction rules exercised with
// the spec's canonical scenario: a deceased subject with one living
// spouse and one omitted child.
struct PublishBioTests {

    // MARK: - Fixtures

    private func makeProfile(
        id: String, first: String? = nil, last: String? = nil,
        birth: String? = nil, death: String? = nil,
        birthLocation: String? = nil, deathLocation: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, lastName: last,
            birthDate: birth.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: death.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private var george: Profile {
        makeProfile(id: "@G@", first: "George", last: "Brooks",
                    birth: "1883", death: "1946",
                    birthLocation: "Belper", deathLocation: "Derby")
    }

    private func spouseEdge(_ a: String, _ b: String, year: String? = "1912",
                            location: String? = "Belper") -> Relationship {
        Relationship(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
            from: a, to: b, type: .spouse, role: nil, subtype: .biological,
            marriageDate: year.map { GenealogicalDate(parsing: $0) },
            marriageLocation: location, divorceDate: nil)
    }

    private func parentEdge(_ parent: String, _ child: String, uuid: String) -> Relationship {
        Relationship(
            id: UUID(uuidString: uuid)!,
            from: parent, to: child, type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    // MARK: - Snapshot prose (deceased subject, full relatives)

    @Test func fullFamilyBioSnapshot() {
        let ida = makeProfile(id: "@I@", first: "Ida", last: "Brooks",
                              birth: "1888", death: "1970")
        let ada = makeProfile(id: "@A@", first: "Ada", last: "Brooks",
                              birth: "1912", death: "1998")
        let snapshot = FamilyGraphSnapshot(
            profiles: ["@G@": george, "@I@": ida, "@A@": ada],
            relationships: [
                spouseEdge("@G@", "@I@"),
                parentEdge("@G@", "@A@", uuid: "00000000-0000-0000-0000-00000000000B"),
            ])
        let census = LifeEvent(
            id: UUID(), profileID: "@G@", type: .census,
            date: GenealogicalDate(parsing: "1911"), location: "Belper")
        let resolved: [String: ResolvedPublishPolicy] = ["@G@": .full, "@I@": .full, "@A@": .full]

        let bio = PublishBioBuilder.bio(
            for: george, lifeEvents: [census], snapshot: snapshot, resolved: resolved)
        #expect(bio == """
            George Brooks was born in 1883 in Belper. George married Ida Brooks in 1912. \
            George appears in the 1911 census. George died in 1946 in Derby. \
            George's children: Ada Brooks (b. 1912).
            """)
    }

    // MARK: - Relative redaction (the spec's canonical scenario)

    @Test func livingSpouseAppearsNameOnlyAndOmittedChildVanishes() {
        let lily = makeProfile(id: "@L@", first: "Lily", last: "Brooks", birth: "1990")
        let ada = makeProfile(id: "@A@", first: "Ada", last: "Brooks", birth: "1912", death: "1998")
        let hidden = makeProfile(id: "@H@", first: "Harold", last: "Brooks", birth: "1915", death: "1990")
        let snapshot = FamilyGraphSnapshot(
            profiles: ["@G@": george, "@L@": lily, "@A@": ada, "@H@": hidden],
            relationships: [
                spouseEdge("@G@", "@L@"),
                parentEdge("@G@", "@A@", uuid: "00000000-0000-0000-0000-00000000000B"),
                parentEdge("@G@", "@H@", uuid: "00000000-0000-0000-0000-00000000000C"),
            ])
        let resolved: [String: ResolvedPublishPolicy] = [
            "@G@": .full, "@L@": .nameOnly, "@A@": .full, "@H@": .omit,
        ]

        let bio = PublishBioBuilder.bio(
            for: george, lifeEvents: [], snapshot: snapshot, resolved: resolved)
        #expect(bio.contains("George married Lily Brooks."),
                "nameOnly spouse: name yes, marriage year no")
        #expect(!bio.contains("1912") || bio.contains("Ada"),
                "the only 1912 allowed is Ada's birth year, never the marriage year")
        #expect(!bio.contains("Harold"), "omitted child absent from prose")
        #expect(bio.contains("Ada Brooks (b. 1912)"), "full child keeps birth year")
    }

    @Test func omittedSpouseProducesNoMarriageSentence() {
        let ida = makeProfile(id: "@I@", first: "Ida", last: "Brooks", birth: "1888", death: "1970")
        let snapshot = FamilyGraphSnapshot(
            profiles: ["@G@": george, "@I@": ida],
            relationships: [spouseEdge("@G@", "@I@")])
        let bio = PublishBioBuilder.bio(
            for: george, lifeEvents: [], snapshot: snapshot,
            resolved: ["@G@": .full, "@I@": .omit])
        #expect(!bio.contains("married"))
        #expect(!bio.contains("Ida"))
    }

    @Test func sensitiveCensusEventExcludedFromProse() {
        let snapshot = FamilyGraphSnapshot(profiles: ["@G@": george], relationships: [])
        let sensitive = LifeEvent(
            id: UUID(), profileID: "@G@", type: .census,
            date: GenealogicalDate(parsing: "1911"), location: "Belper", sensitive: true)
        let bio = PublishBioBuilder.bio(
            for: george, lifeEvents: [sensitive], snapshot: snapshot,
            resolved: ["@G@": .full])
        #expect(!bio.contains("census"))
    }

    // MARK: - Projection integration

    @Test func projectionFillsBioForFullAndKeepsNameOnlyEmpty() {
        let lily = makeProfile(id: "@L@", first: "Lily", last: "Brooks", birth: "1990")
        let snapshot = FamilyGraphSnapshot(
            profiles: ["@G@": george, "@L@": lily],
            relationships: [spouseEdge("@G@", "@L@")])
        let inputs = PublishedTree.Inputs(
            snapshot: snapshot, lifeEvents: [], attachments: [],
            policies: [:], mediaOptIns: [], convergenceByProfile: [:],
            rootProfileID: nil, currentYear: 2026, generation: 1,
            publishedAtISO: "2026-07-05T00:00:00Z")
        var identity = PublishedIdentity(mint: { "U" + UUID().uuidString })
        let tree = PublishedTree.project(inputs, identity: &identity)

        let full = tree.persons.first { !$0.isRedacted }!
        let redacted = tree.persons.first { $0.isRedacted }!
        #expect(full.bioText.contains("George Brooks was born in 1883"))
        #expect(full.bioText.contains("George married Lily Brooks."),
                "living spouse name-only in the published bio")
        #expect(redacted.bioText.isEmpty, "§5 zero-leakage holds")
    }
}
