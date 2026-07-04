import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

// PUBLISHER_SPEC Change 1 acceptance — the redaction rules are
// correctness-critical (a miss publishes third-party personal data), so
// every §5 branch gets a direct test against the pure projection.

struct PublishPolicyResolverTests {
    @Test func autoLivingResolvesNameOnly() {
        #expect(PublishPolicyResolver.resolve(override: .auto, potentiallyLiving: true) == .nameOnly)
    }

    @Test func autoDeceasedResolvesFull() {
        #expect(PublishPolicyResolver.resolve(override: .auto, potentiallyLiving: false) == .full)
    }

    @Test func explicitOverridesIgnoreHeuristic() {
        for living in [true, false] {
            #expect(PublishPolicyResolver.resolve(override: .full, potentiallyLiving: living) == .full)
            #expect(PublishPolicyResolver.resolve(override: .nameOnly, potentiallyLiving: living) == .nameOnly)
            #expect(PublishPolicyResolver.resolve(override: .omit, potentiallyLiving: living) == .omit)
        }
    }
}

struct PublishedIdentityTests {
    @Test func mintsOnceThenReuses() {
        var n = 0
        var identity = PublishedIdentity(mint: { n += 1; return "U\(n)" })
        let a = identity.uuid(kind: "person", canonicalID: "@I1@")
        let b = identity.uuid(kind: "person", canonicalID: "@I1@")
        let c = identity.uuid(kind: "person", canonicalID: "@I2@")
        #expect(a == "U1" && b == "U1" && c == "U2")
        #expect(identity.minted.count == 2)
    }

    @Test func existingMapReusedWithoutMinting() {
        var identity = PublishedIdentity(
            existing: [PublishedIdentity.key(kind: "person", canonicalID: "@I1@"): "STABLE"],
            mint: { "FRESH" }
        )
        #expect(identity.uuid(kind: "person", canonicalID: "@I1@") == "STABLE")
        #expect(identity.minted.isEmpty)
    }
}

struct PublisherProjectionTests {

    // MARK: - Fixtures

    private func makeProfile(
        id: String, first: String? = nil, last: String? = nil,
        gender: Gender? = nil, birth: String? = nil, death: String? = nil,
        birthLocation: String? = nil, deathLocation: String? = nil,
        isDeleted: Bool = false, sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, lastName: last,
            gender: gender,
            birthDate: birth.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: death.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            isDeleted: isDeleted, sources: sources, disputes: [:]
        )
    }

    /// Deceased Victorian fixture — resolves `full` under `auto`.
    private var george: Profile {
        makeProfile(id: "@G@", first: "George", last: "Brooks", gender: .male,
                    birth: "1883", death: "1946",
                    birthLocation: "Belper, Derbyshire", deathLocation: "Derby")
    }

    /// No death date, born recently — `potentiallyLiving` ⇒ `nameOnly` under `auto`.
    private var livingLily: Profile {
        makeProfile(id: "@L@", first: "Lily", last: "Brooks", gender: .female, birth: "1990",
                    birthLocation: "Derby")
    }

    private func project(
        profiles: [Profile], relationships: [Relationship] = [],
        events: [LifeEvent] = [], attachments: [AncestorKit.Attachment] = [],
        policies: [String: PublishPolicy] = [:], optIns: Set<UUID> = [],
        convergence: [String: String] = [:], root: String? = nil,
        currentYear: Int = 2026, identity: inout PublishedIdentity
    ) -> PublishedTree {
        let snapshot = FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }),
            relationships: relationships
        )
        let inputs = PublishedTree.Inputs(
            snapshot: snapshot, lifeEvents: events, attachments: attachments,
            policies: policies, mediaOptIns: optIns,
            convergenceByProfile: convergence, rootProfileID: root,
            currentYear: currentYear, generation: 1,
            publishedAtISO: "2026-07-04T00:00:00Z"
        )
        return PublishedTree.project(inputs, identity: &identity)
    }

    private func project(
        profiles: [Profile], relationships: [Relationship] = [],
        events: [LifeEvent] = [], attachments: [AncestorKit.Attachment] = [],
        policies: [String: PublishPolicy] = [:], optIns: Set<UUID> = [],
        convergence: [String: String] = [:], root: String? = nil,
        currentYear: Int = 2026
    ) -> PublishedTree {
        var identity = testIdentity()
        return project(profiles: profiles, relationships: relationships,
                       events: events, attachments: attachments,
                       policies: policies, optIns: optIns,
                       convergence: convergence, root: root,
                       currentYear: currentYear, identity: &identity)
    }

    private func testIdentity() -> PublishedIdentity {
        var n = 0
        return PublishedIdentity(mint: { n += 1; return "U\(n)" })
    }

    private func spouseEdge(_ a: String, _ b: String,
                            married: String? = "1912", location: String? = "Belper") -> Relationship {
        Relationship(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
            from: a, to: b, type: .spouse, role: nil, subtype: .biological,
            marriageDate: married.map { GenealogicalDate(parsing: $0) },
            marriageLocation: location, divorceDate: nil
        )
    }

    // MARK: - Person redaction (§5)

    @Test func deceasedPersonPublishesFull() {
        let tree = project(profiles: [george])
        let p = tree.persons[0]
        #expect(!p.isRedacted)
        #expect(p.givenName == "George" && p.familyName == "Brooks")
        #expect(p.birth?.earliest == 1883 && p.death?.earliest == 1946)
        #expect(p.birthPlace == "Belper, Derbyshire" && p.deathPlace == "Derby")
        #expect(p.genderRaw == "male")
    }

    @Test func livingPersonAutoRedactsToNameOnlyWithZeroLeakage() {
        let sources: [ProfileField: [FieldSource]] = [
            .birthDate: [FieldSource(origin: SourceOrigin(identifier: "freebmd"),
                                     raw: "1990", addedAt: Date(timeIntervalSince1970: 0))]
        ]
        let lily = makeProfile(id: "@L@", first: "Lily", last: "Brooks", gender: .female,
                               birth: "1990", birthLocation: "Derby", sources: sources)
        let event = LifeEvent(id: UUID(), profileID: "@L@", type: .residence,
                              date: GenealogicalDate(parsing: "2010"), location: "Derby")
        let tree = project(profiles: [lily], events: [event])
        let p = tree.persons[0]
        #expect(p.isRedacted)
        #expect(!p.displayName.isEmpty)
        #expect(p.givenName == nil && p.familyName == nil && p.genderRaw == nil)
        #expect(p.birth == nil && p.death == nil && p.birthPlace == nil && p.deathPlace == nil)
        #expect(p.citationsJSON == "[]" && p.badgesJSON == "{}" && p.bioText.isEmpty)
        #expect(tree.events.isEmpty, "nameOnly persons publish no life events")
    }

    @Test func deathEventWithoutDeathDateStillRedacts() {
        // The heuristic keys on profile.deathDate only — a death life-event
        // without a date does not flip it. Safe default: still nameOnly.
        let person = makeProfile(id: "@X@", first: "Ann", last: "Ward", birth: "1980")
        let deathEvent = LifeEvent(id: UUID(), profileID: "@X@", type: .burial)
        let tree = project(profiles: [person], events: [deathEvent])
        #expect(tree.persons[0].isRedacted)
        #expect(tree.events.isEmpty)
    }

    @Test func omittedPersonAbsentAndEdgesDropped() {
        let ida = makeProfile(id: "@I@", first: "Ida", last: "Land", birth: "1888", death: "1970")
        let tree = project(
            profiles: [george, ida],
            relationships: [spouseEdge("@G@", "@I@")],
            policies: ["@I@": .omit]
        )
        #expect(tree.persons.count == 1)
        #expect(tree.persons[0].displayName.contains("George"))
        #expect(tree.relationships.isEmpty, "edges touching an omitted person are dropped")
        #expect(tree.manifest.personCount == 1 && tree.manifest.relationshipCount == 0)
    }

    @Test func deletedProfileExcludedEntirely() {
        let ghost = makeProfile(id: "@D@", first: "Old", last: "Row", birth: "1800",
                                death: "1870", isDeleted: true)
        let tree = project(profiles: [george, ghost],
                           relationships: [spouseEdge("@G@", "@D@")])
        #expect(tree.persons.count == 1)
        #expect(tree.relationships.isEmpty)
    }

    // MARK: - Edge redaction (§5)

    @Test func nameOnlySpouseEdgePublishesBare() {
        let tree = project(profiles: [george, livingLily],
                           relationships: [spouseEdge("@G@", "@L@")])
        #expect(tree.relationships.count == 1)
        let edge = tree.relationships[0]
        #expect(edge.typeRaw == "spouse")
        #expect(edge.marriage == nil && edge.marriageLocation == nil && edge.divorce == nil,
                "marriage facts are facts about both parties — stripped when either is nameOnly")
    }

    @Test func fullFullSpouseEdgeKeepsMarriage() {
        let ida = makeProfile(id: "@I@", first: "Ida", last: "Land", birth: "1888", death: "1970")
        let tree = project(profiles: [george, ida],
                           relationships: [spouseEdge("@G@", "@I@")])
        let edge = tree.relationships[0]
        #expect(edge.marriage?.earliest == 1912)
        #expect(edge.marriageLocation == "Belper")
        #expect(edge.subtypeRaw == "biological")
    }

    // MARK: - Life events (§5)

    @Test func sensitiveEventExcludedRegardlessOfPolicy() {
        let event = LifeEvent(id: UUID(), profileID: "@G@", type: .residence,
                              date: GenealogicalDate(parsing: "1901"),
                              location: "Belper", sensitive: true)
        let tree = project(profiles: [george], events: [event])
        #expect(tree.events.isEmpty)
    }

    @Test func householdPublishesAtHundredYearBoundary() throws {
        let details = LifeEventDetails.census(CensusDetails(
            household: [HouseholdMember(name: "Ann Brooks", relationship: "Wife")]
        ))
        let event = LifeEvent(id: UUID(), profileID: "@G@", type: .census,
                              date: GenealogicalDate(parsing: "1926"), details: details)
        let tree = project(profiles: [george], events: [event], currentYear: 2026)
        let json = try #require(tree.events[0].detailsJSON)
        #expect(json.contains("Ann Brooks"), "event year 1926 ≤ 2026−100 publishes the roster")
    }

    @Test func householdStrippedWhenWithinHundredYears() throws {
        let details = LifeEventDetails.census(CensusDetails(
            household: [HouseholdMember(name: "Ann Brooks", relationship: "Wife")]
        ))
        let event = LifeEvent(id: UUID(), profileID: "@G@", type: .census,
                              date: GenealogicalDate(parsing: "1927"), details: details)
        let tree = project(profiles: [george], events: [event], currentYear: 2026)
        let json = try #require(tree.events[0].detailsJSON)
        #expect(!json.contains("Ann Brooks"), "event year 1927 > 2026−100 strips the roster")
    }

    @Test func householdStrippedWhenYearUnknown() throws {
        let details = LifeEventDetails.census(CensusDetails(
            household: [HouseholdMember(name: "Ann Brooks", relationship: "Wife")]
        ))
        let event = LifeEvent(id: UUID(), profileID: "@G@", type: .census, details: details)
        let tree = project(profiles: [george], events: [event], currentYear: 2026)
        let json = try #require(tree.events[0].detailsJSON)
        #expect(!json.contains("Ann Brooks"), "unknown event year strips the roster — safe default")
    }

    // MARK: - Provisional persons (§4.2)

    @Test func surnameOnlyPlaceholderIsProvisionalUnderExplicitFull() {
        // Under `auto`, a no-vitals placeholder resolves living ⇒ nameOnly.
        // Publishing it as a ghost card requires an explicit `full` override.
        let placeholder = makeProfile(id: "@P@", last: "Land")
        let tree = project(profiles: [placeholder], policies: ["@P@": .full])
        #expect(tree.persons[0].isProvisional)
    }

    @Test func autoPlaceholderRedactsRatherThanProvisional() {
        let placeholder = makeProfile(id: "@P@", last: "Land")
        let tree = project(profiles: [placeholder])
        #expect(tree.persons[0].isRedacted && !tree.persons[0].isProvisional)
    }

    // MARK: - Media (§4.2)

    private func photoAttachment(to personID: String, type: AttachmentType = .photo) -> AncestorKit.Attachment {
        AncestorKit.Attachment(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
                   filename: "portrait.jpg", mediaType: type, caption: "George, 1920",
                   relativePath: "portrait.jpg",
                   attachedTo: .profile(id: personID),
                   addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func mediaRequiresOptIn() {
        let attachment = photoAttachment(to: "@G@")
        let none = project(profiles: [george], attachments: [attachment])
        #expect(none.media.isEmpty)
        let opted = project(profiles: [george], attachments: [attachment],
                            optIns: [attachment.id])
        #expect(opted.media.count == 1)
        #expect(opted.media[0].kind == "portrait")
        #expect(opted.media[0].relativePath == "portrait.jpg")
    }

    @Test func transcriptionsNeverPublish() {
        let attachment = photoAttachment(to: "@G@", type: .transcription)
        let tree = project(profiles: [george], attachments: [attachment],
                           optIns: [attachment.id])
        #expect(tree.media.isEmpty)
    }

    @Test func mediaForRedactedPersonExcluded() {
        let attachment = photoAttachment(to: "@L@")
        let tree = project(profiles: [livingLily], attachments: [attachment],
                           optIns: [attachment.id])
        #expect(tree.media.isEmpty)
    }

    // MARK: - Field derivations (§4.2)

    @Test func citationsDeriveTierFromURLNeverFromOrigin() throws {
        let url = "https://www.freebmd.org.uk/cgi/information.pl?r=1"
        let cited = FieldSource(origin: SourceOrigin(identifier: "freebmd"),
                                raw: "1883", addedAt: Date(timeIntervalSince1970: 0),
                                citation: Citation(collection: "FreeBMD Birth Index", url: url))
        let uncited = FieldSource(origin: SourceOrigin(identifier: "gedcom"),
                                  raw: "1883", addedAt: Date(timeIntervalSince1970: 0))
        let profile = makeProfile(id: "@G@", first: "George", last: "Brooks",
                                  birth: "1883", death: "1946",
                                  sources: [.birthDate: [cited, uncited]])
        let tree = project(profiles: [profile])
        let json = try #require(tree.persons[0].citationsJSON.data(using: .utf8))
        let entries = try JSONDecoder().decode([PublishedCitation].self, from: json)
        #expect(entries.count == 2)
        let citedEntry = try #require(entries.first { $0.url != nil })
        #expect(citedEntry.source == "FreeBMD Birth Index")
        #expect(citedEntry.trustTier == SourceTierRegistry.lookup(url: url).trustTier.rawValue)
        let uncitedEntry = try #require(entries.first { $0.url == nil })
        #expect(uncitedEntry.source == "gedcom")
        #expect(uncitedEntry.trustTier == nil, "no URL ⇒ no trust tier — never from SourceOrigin.tier")
    }

    @Test func badgesCarryCompletenessAndOptionalConvergence() throws {
        let with = project(profiles: [george], convergence: ["@G@": "corroborated"])
        #expect(with.persons[0].badgesJSON.contains("corroborated"))
        let without = project(profiles: [george])
        #expect(!without.persons[0].badgesJSON.contains("convergence\":"))
        #expect(without.persons[0].badgesJSON.contains("completenessScore"))
    }

    // MARK: - Determinism, identity, manifest

    @Test func projectionIsDeterministicAndChecksumsAreSensitive() {
        let a = project(profiles: [george, livingLily],
                        relationships: [spouseEdge("@G@", "@L@")])
        let b = project(profiles: [george, livingLily],
                        relationships: [spouseEdge("@G@", "@L@")])
        #expect(PublishChecksum.checksum(a.persons[0]) == PublishChecksum.checksum(b.persons[0]))
        #expect(PublishChecksum.checksum(a.relationships[0]) == PublishChecksum.checksum(b.relationships[0]))

        let moved = makeProfile(id: "@G@", first: "George", last: "Brooks", gender: .male,
                                birth: "1883", death: "1946",
                                birthLocation: "Duffield, Derbyshire", deathLocation: "Derby")
        let c = project(profiles: [moved, livingLily],
                        relationships: [spouseEdge("@G@", "@L@")])
        #expect(PublishChecksum.checksum(a.persons[0]) != PublishChecksum.checksum(c.persons[0]))
    }

    @Test func identityStableAcrossRepublish() {
        var first = testIdentity()
        let treeA = project(profiles: [george, livingLily], identity: &first)

        // Simulate persisting published_ids and republishing later.
        let persisted = Dictionary(uniqueKeysWithValues: first.minted.map {
            (PublishedIdentity.key(kind: $0.kind, canonicalID: $0.canonicalID), $0.uuid)
        })
        var second = PublishedIdentity(existing: persisted, mint: { "SHOULD-NOT-MINT" })
        let treeB = project(profiles: [george, livingLily], identity: &second)

        #expect(treeA.persons.map(\.id) == treeB.persons.map(\.id))
        #expect(second.minted.isEmpty, "republish reuses every UUID — §4.1 permanence")
    }

    @Test func manifestCountsAndRootTrackPolicy() {
        let published = project(profiles: [george, livingLily], root: "@G@")
        #expect(published.manifest.rootPerson != nil)
        #expect(published.manifest.personCount == 2)

        let omittedRoot = project(profiles: [george, livingLily],
                                  policies: ["@G@": .omit], root: "@G@")
        #expect(omittedRoot.manifest.rootPerson == nil)
        #expect(omittedRoot.manifest.personCount == 1)
    }

    // MARK: - Heuristic alignment (decision log #6)

    @Test func livingHeuristicIsSharedWithCompleteness() {
        let currentYear = Calendar.current.component(.year, from: Date())
        let recent = makeProfile(id: "@R@", first: "A", last: "B", birth: "\(currentYear - 99)")
        let old = makeProfile(id: "@O@", first: "C", last: "D", birth: "\(currentYear - 101)")
        let snapshot = FamilyGraphSnapshot(
            profiles: ["@R@": recent, "@O@": old], relationships: []
        )
        #expect(snapshot.completeness(for: "@R@").potentiallyLiving)
        #expect(!snapshot.completeness(for: "@O@").potentiallyLiving,
                "publisher reuses the 100-year potentiallyLiving rule — one definition")
    }
}

struct PublisherMigrationTests {
    @Test func v30PublisherTablesExist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("publisher-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ProjectDatabase(path: dir.appendingPathComponent("test.sqlite").path)
        let tables = try db.dbQueue.read { database in
            try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name IN
                ('publish_policy', 'published_ids', 'published_state', 'publish_meta', 'publish_media')
                ORDER BY name
                """)
        }
        #expect(tables == ["publish_media", "publish_meta", "publish_policy", "published_ids", "published_state"])
    }
}
