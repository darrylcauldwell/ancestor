import Testing
import Foundation
@testable import Ancestor_Research

/// M10 Family Group Sheet renderer (DESIGN.md §7.9.3).
///
/// Covers:
///   - family-unit resolution rules (subject with spouse, with parents,
///     standalone)
///   - PDF render returns non-nil bytes
///   - Sources collection deduplicates citations across multiple field
///     sources
@MainActor
struct FamilyGroupSheetReportTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        gender: Gender? = .unknown,
        birthYear: Int? = nil,
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName,
            gender: gender, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: "\($0)") },
            birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: sources, disputes: [:]
        )
    }

    private func parentRel(from: String, to: String) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: nil, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func spouseRel(_ a: String, _ b: String, marriageDate: String? = nil, marriageLocation: String? = nil) -> Relationship {
        Relationship(
            id: UUID(), from: a, to: b,
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: marriageDate.map { GenealogicalDate(parsing: $0) },
            marriageLocation: marriageLocation,
            divorceDate: nil
        )
    }

    // MARK: - Resolution

    @Test func subjectWithSpouseAndChildren_resolvesAsCouple() {
        let husband = makeProfile(id: "h", firstName: "John", lastName: "Smith", gender: .male)
        let wife = makeProfile(id: "w", firstName: "Mary", lastName: "Jones", gender: .female)
        let child1 = makeProfile(id: "c1", firstName: "Alice", gender: .female, birthYear: 1860)
        let child2 = makeProfile(id: "c2", firstName: "Bob", gender: .male, birthYear: 1858)

        let marriage = spouseRel("h", "w", marriageDate: "1855", marriageLocation: "Belper")
        let rels: [Relationship] = [
            marriage,
            parentRel(from: "h", to: "c1"),
            parentRel(from: "w", to: "c1"),
            parentRel(from: "h", to: "c2"),
            parentRel(from: "w", to: "c2")
        ]

        let snap = FamilyGraphSnapshot(
            profiles: ["h": husband, "w": wife, "c1": child1, "c2": child2],
            relationships: rels
        )

        let unit = FamilyGroupSheetReport.family(forProfileID: "h", in: snap)
        #expect(unit != nil)
        #expect(unit?.father?.id == "h")
        #expect(unit?.mother?.id == "w")
        #expect(unit?.children.count == 2)
        // Sorted by birth year — Bob (1858) first, Alice (1860) second.
        #expect(unit?.children.first?.id == "c2")
        #expect(unit?.children.last?.id == "c1")
        #expect(unit?.marriage?.marriageLocation == "Belper")
    }

    @Test func subjectWithSpouse_resolvedFromWifeSide() {
        let husband = makeProfile(id: "h", firstName: "John", gender: .male)
        let wife = makeProfile(id: "w", firstName: "Mary", gender: .female)
        let snap = FamilyGraphSnapshot(
            profiles: ["h": husband, "w": wife],
            relationships: [spouseRel("h", "w")]
        )
        let unit = FamilyGroupSheetReport.family(forProfileID: "w", in: snap)
        #expect(unit?.father?.id == "h")
        #expect(unit?.mother?.id == "w")
    }

    @Test func subjectWithParentsButNoSpouse_resolvesParentsFamily() {
        let father = makeProfile(id: "f", firstName: "William", gender: .male)
        let mother = makeProfile(id: "m", firstName: "Sarah", gender: .female)
        let subject = makeProfile(id: "s", firstName: "Thomas", gender: .male, birthYear: 1834)
        let sibling = makeProfile(id: "sib", firstName: "Jane", gender: .female, birthYear: 1836)

        let rels: [Relationship] = [
            spouseRel("f", "m"),
            parentRel(from: "f", to: "s"),
            parentRel(from: "m", to: "s"),
            parentRel(from: "f", to: "sib"),
            parentRel(from: "m", to: "sib")
        ]
        let snap = FamilyGraphSnapshot(
            profiles: ["f": father, "m": mother, "s": subject, "sib": sibling],
            relationships: rels
        )
        let unit = FamilyGroupSheetReport.family(forProfileID: "s", in: snap)
        #expect(unit?.father?.id == "f")
        #expect(unit?.mother?.id == "m")
        // Subject is in the children list along with their sibling.
        let childIDs = Set((unit?.children ?? []).map(\.id))
        #expect(childIDs == ["s", "sib"])
    }

    @Test func orphanProfile_resolvesAsStandalone() {
        let lone = makeProfile(id: "lone", firstName: "Solo", lastName: "Person", gender: .male)
        let snap = FamilyGraphSnapshot(profiles: ["lone": lone], relationships: [])
        let unit = FamilyGroupSheetReport.family(forProfileID: "lone", in: snap)
        #expect(unit != nil)
        #expect(unit?.father?.id == "lone")
        #expect(unit?.mother == nil)
        #expect(unit?.children.isEmpty == true)
        #expect(unit?.marriage == nil)
    }

    @Test func unknownProfileID_returnsNil() {
        let snap = FamilyGraphSnapshot.empty
        let unit = FamilyGroupSheetReport.family(forProfileID: "missing", in: snap)
        #expect(unit == nil)
    }

    // MARK: - Render

    @Test func renderReturnsNonNilData() {
        let h = makeProfile(id: "h", firstName: "John", lastName: "Smith", gender: .male, birthYear: 1830)
        let w = makeProfile(id: "w", firstName: "Mary", lastName: "Jones", gender: .female, birthYear: 1832)
        let c = makeProfile(id: "c", firstName: "Alice", gender: .female, birthYear: 1860)
        let snap = FamilyGraphSnapshot(
            profiles: ["h": h, "w": w, "c": c],
            relationships: [
                spouseRel("h", "w", marriageDate: "1855", marriageLocation: "Belper"),
                parentRel(from: "h", to: "c"),
                parentRel(from: "w", to: "c")
            ]
        )
        let data = FamilyGroupSheetReport.renderPDF(
            profileID: "h",
            paperSize: .a4,
            snapshot: snap,
            notes: []
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test func renderUnknownProfileReturnsNil() {
        let snap = FamilyGraphSnapshot.empty
        let data = FamilyGroupSheetReport.renderPDF(
            profileID: "missing",
            paperSize: .a4,
            snapshot: snap,
            notes: []
        )
        #expect(data == nil)
    }

    // MARK: - Sources / notes

    @Test func sourcesCollectionDeduplicatesAcrossFields() {
        // Same citation attached to two different fields on the husband
        // and again to a field on the wife — should appear once.
        let shared = Citation(
            repository: "Derbyshire Record Office",
            collection: "Parish Register",
            title: "Marriage of John & Mary",
            page: nil,
            url: nil,
            dateAccessed: nil,
            notes: nil
        )
        let other = Citation(
            repository: nil,
            collection: "FreeBMD",
            title: "Birth Index",
            page: "Vol 7b p213",
            url: nil,
            dateAccessed: nil,
            notes: nil
        )

        let husbandSources: [ProfileField: [FieldSource]] = [
            .birthDate: [
                FieldSource(origin: .freebmd, raw: "freebmd:1", addedAt: Date(), citation: other)
            ],
            .firstName: [
                FieldSource(origin: .gedcom, raw: "ged:1", addedAt: Date(), citation: shared)
            ],
            .lastName: [
                FieldSource(origin: .gedcom, raw: "ged:2", addedAt: Date(), citation: shared)
            ]
        ]
        let wifeSources: [ProfileField: [FieldSource]] = [
            .firstName: [
                FieldSource(origin: .gedcom, raw: "ged:3", addedAt: Date(), citation: shared)
            ]
        ]

        let h = makeProfile(id: "h", firstName: "John", gender: .male, sources: husbandSources)
        let w = makeProfile(id: "w", firstName: "Mary", gender: .female, sources: wifeSources)
        let snap = FamilyGraphSnapshot(
            profiles: ["h": h, "w": w],
            relationships: [spouseRel("h", "w")]
        )

        let unit = FamilyGroupSheetReport.family(forProfileID: "h", in: snap)
        #expect(unit != nil)
        let citations = FamilyGroupSheetReport.collectCitations(for: unit!)
        #expect(citations.count == 2)
        #expect(citations.contains(shared))
        #expect(citations.contains(other))
    }

    @Test func emptyCitationsAreIgnored() {
        let empty = Citation()
        #expect(empty.isEmpty)
        let sources: [ProfileField: [FieldSource]] = [
            .birthDate: [FieldSource(origin: .manual, raw: "x", addedAt: Date(), citation: empty)]
        ]
        let p = makeProfile(id: "p", firstName: "Pat", gender: .male, sources: sources)
        let snap = FamilyGraphSnapshot(profiles: ["p": p], relationships: [])
        let unit = FamilyGroupSheetReport.family(forProfileID: "p", in: snap)
        let citations = FamilyGroupSheetReport.collectCitations(for: unit!)
        #expect(citations.isEmpty)
    }

    @Test func notesCollectionFiltersToFamilyMembers() {
        let h = makeProfile(id: "h", firstName: "John", gender: .male)
        let w = makeProfile(id: "w", firstName: "Mary", gender: .female)
        let outsider = makeProfile(id: "x", firstName: "Outsider", gender: .male)

        let snap = FamilyGraphSnapshot(
            profiles: ["h": h, "w": w, "x": outsider],
            relationships: [spouseRel("h", "w")]
        )

        let now = Date()
        let included = WorkbenchNote(
            id: UUID(), content: "Found marriage record",
            tag: .observation,
            attachedTo: .profile(id: "h"),
            createdAt: now, updatedAt: now
        )
        let excludedOutside = WorkbenchNote(
            id: UUID(), content: "Unrelated person",
            tag: .observation,
            attachedTo: .profile(id: "x"),
            createdAt: now, updatedAt: now
        )
        let excludedKind = WorkbenchNote(
            id: UUID(), content: "Project-wide note",
            tag: .meta,
            attachedTo: .project,
            createdAt: now, updatedAt: now
        )

        let unit = FamilyGroupSheetReport.family(forProfileID: "h", in: snap)
        let collected = FamilyGroupSheetReport.collectNotes(
            for: unit!,
            from: [included, excludedOutside, excludedKind]
        )
        #expect(collected.count == 1)
        #expect(collected.first?.id == included.id)
    }
}
