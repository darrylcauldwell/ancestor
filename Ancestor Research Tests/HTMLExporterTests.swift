import Testing
import Foundation
@testable import Ancestor_Research

struct HTMLExporterTests {

    // MARK: - Fixture helpers

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        birthDate: String? = nil,
        deathDate: String? = nil,
        privacy: Privacy = .normal,
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            attributes: PersonAttributes(
                nameStatus: .known,
                lifeStatus: .normal,
                privacy: privacy
            ),
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: sources,
            disputes: [:]
        )
    }

    private func snapshot(profiles: [Profile], relationships: [Relationship] = []) -> FamilyGraphSnapshot {
        var dict: [String: Profile] = [:]
        for p in profiles { dict[p.id] = p }
        return FamilyGraphSnapshot(profiles: dict, relationships: relationships)
    }

    private func request(
        snapshot: FamilyGraphSnapshot,
        lifeEvents: [LifeEvent] = [],
        excludeLiving: Bool = false,
        excludeSensitive: Bool = false,
        projectName: String = "Test Tree"
    ) -> HTMLExporter.ExportRequest {
        HTMLExporter.ExportRequest(
            snapshot: snapshot,
            lifeEvents: lifeEvents,
            projectName: projectName,
            excludeLiving: excludeLiving,
            excludeSensitive: excludeSensitive
        )
    }

    // MARK: - Tests

    @Test func exportProducesIndexAndOneProfilePagePerProfile() {
        let p1 = makeProfile(id: "A", firstName: "Alice", lastName: "Adams")
        let p2 = makeProfile(id: "B", firstName: "Bob", lastName: "Brown")
        let p3 = makeProfile(id: "C", firstName: "Carol", lastName: "Clarke")
        let snap = snapshot(profiles: [p1, p2, p3])
        let result = HTMLExporter.export(request(snapshot: snap))

        let paths = result.files.map(\.relativePath)
        #expect(paths.contains("index.html"))
        #expect(paths.contains("style.css"))
        #expect(paths.contains("profile-A.html"))
        #expect(paths.contains("profile-B.html"))
        #expect(paths.contains("profile-C.html"))
        // index + style.css + 3 profile pages = 5 total
        #expect(result.files.count == 5)
    }

    @Test func exportEscapesHTMLEntitiesInValues() {
        let profile = makeProfile(id: "X", firstName: "Mary <Bob>", lastName: "& Co")
        let snap = snapshot(profiles: [profile])
        let result = HTMLExporter.export(request(snapshot: snap))

        let profilePage = result.files.first { $0.relativePath == "profile-X.html" }
        #expect(profilePage != nil)
        let html = profilePage?.contents ?? ""
        // Escaped form must be present
        #expect(html.contains("&lt;Bob&gt;"))
        #expect(html.contains("&amp; Co"))
        // Raw form must NOT appear in user-rendered text. The string "<Bob>"
        // must never occur because every value passes through `escape`.
        #expect(!html.contains("<Bob>"))

        // The index page must also be escaped.
        let index = result.files.first { $0.relativePath == "index.html" }?.contents ?? ""
        #expect(index.contains("&lt;Bob&gt;"))
        #expect(!index.contains("<Bob>"))
    }

    @Test func exportRespectsExcludeLivingWhenSet() {
        let dead = makeProfile(id: "D", firstName: "Dorothy", lastName: "Doe", birthDate: "1850", deathDate: "1920")
        let living = makeProfile(
            id: "L",
            firstName: "Liam",
            lastName: "Living",
            birthDate: "1990",
            privacy: .livingPrivate
        )
        let snap = snapshot(profiles: [dead, living])
        let result = HTMLExporter.export(request(snapshot: snap, excludeLiving: true))

        let paths = result.files.map(\.relativePath)
        // Living person's page should not exist at all.
        #expect(!paths.contains("profile-L.html"))
        #expect(paths.contains("profile-D.html"))

        // Index should not mention the living person's name.
        let index = result.files.first { $0.relativePath == "index.html" }?.contents ?? ""
        #expect(!index.contains("Liam"))
        #expect(index.contains("Dorothy"))
    }

    @Test func exportRespectsExcludeSensitiveForLifeEvents() {
        let profile = makeProfile(id: "E", firstName: "Edward", lastName: "Eve")
        let snap = snapshot(profiles: [profile])

        let normalEvent = LifeEvent(
            id: UUID(),
            profileID: "E",
            type: .occupation,
            date: GenealogicalDate(parsing: "1880"),
            location: "Derby",
            description: "Framework knitter",
            sensitive: false
        )
        let sensitiveEvent = LifeEvent(
            id: UUID(),
            profileID: "E",
            type: .residence,
            date: GenealogicalDate(parsing: "1885"),
            location: "Belper",
            description: "PRIVATE_ADDRESS_42",
            sensitive: true
        )

        // With excludeSensitive=true the sensitive event must not appear.
        let filtered = HTMLExporter.export(
            request(snapshot: snap, lifeEvents: [normalEvent, sensitiveEvent], excludeSensitive: true)
        )
        let filteredPage = filtered.files.first { $0.relativePath == "profile-E.html" }?.contents ?? ""
        #expect(filteredPage.contains("Framework knitter"))
        #expect(!filteredPage.contains("PRIVATE_ADDRESS_42"))

        // With excludeSensitive=false both events must appear.
        let unfiltered = HTMLExporter.export(
            request(snapshot: snap, lifeEvents: [normalEvent, sensitiveEvent], excludeSensitive: false)
        )
        let unfilteredPage = unfiltered.files.first { $0.relativePath == "profile-E.html" }?.contents ?? ""
        #expect(unfilteredPage.contains("Framework knitter"))
        #expect(unfilteredPage.contains("PRIVATE_ADDRESS_42"))
    }

    @Test func exportProducesNonEmptyStyleCSS() {
        let profile = makeProfile(id: "S", firstName: "Sam", lastName: "Smith")
        let snap = snapshot(profiles: [profile])
        let result = HTMLExporter.export(request(snapshot: snap))

        let css = result.files.first { $0.relativePath == "style.css" }?.contents ?? ""
        #expect(!css.isEmpty)
        // Sanity: our stylesheet declares some recognisable selectors.
        #expect(css.contains("body"))
        #expect(css.contains("font-family"))

        // index.html must reference style.css so the styling actually applies.
        let index = result.files.first { $0.relativePath == "index.html" }?.contents ?? ""
        #expect(index.contains("href=\"style.css\""))
    }

    @Test func exportLinksProfilesViaTheirIDs() {
        let alice = makeProfile(id: "A", firstName: "Alice", lastName: "Adams")
        let bob = makeProfile(id: "B", firstName: "Bob", lastName: "Brown")
        let spouseRel = Relationship(
            id: UUID(),
            from: "A",
            to: "B",
            type: .spouse,
            role: nil,
            subtype: .unknown,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )
        let snap = snapshot(profiles: [alice, bob], relationships: [spouseRel])
        let result = HTMLExporter.export(request(snapshot: snap))

        let aPage = result.files.first { $0.relativePath == "profile-A.html" }?.contents ?? ""
        let bPage = result.files.first { $0.relativePath == "profile-B.html" }?.contents ?? ""

        // A's page should link to B's page, and vice versa.
        #expect(aPage.contains("profile-B.html"))
        #expect(bPage.contains("profile-A.html"))

        // The link should appear in the family section, with B's name visible.
        #expect(aPage.contains("Bob"))
        #expect(bPage.contains("Alice"))
    }
}
