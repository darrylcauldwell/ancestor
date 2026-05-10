import Testing
import Foundation
@testable import Ancestor_Research

/// Covers the M10 narrative composer and renderer (DESIGN.md §7.9.4).
/// Tests focus on the composer because it owns all of the conditional
/// logic; the SwiftUI page is exercised indirectly by markdown round-trips.
struct NarrativeReportTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String = UUID().uuidString,
        firstName: String? = "Thomas",
        lastName: String? = "Land",
        gender: Gender? = .male,
        birthDate: String? = nil,
        birthLocation: String? = nil,
        deathDate: String? = nil,
        deathLocation: String? = nil,
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: gender,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            bio: nil, isDeleted: false,
            sources: sources, disputes: [:]
        )
    }

    private func parentEdge(parent: String, child: String, role: ParentRole = .unspecified) -> Relationship {
        Relationship(
            id: UUID(),
            from: parent,
            to: child,
            type: .parent,
            role: role,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )
    }

    private func spouseEdge(
        a: String,
        b: String,
        marriageYear: Int? = nil,
        marriageLocation: String? = nil
    ) -> Relationship {
        Relationship(
            id: UUID(),
            from: a,
            to: b,
            type: .spouse,
            role: nil,
            subtype: .biological,
            marriageDate: marriageYear.map { GenealogicalDate(parsing: "\($0)") },
            marriageLocation: marriageLocation,
            divorceDate: nil
        )
    }

    private func citation(collection: String, page: String? = nil) -> Citation {
        Citation(repository: nil, collection: collection, title: nil, page: page,
                 url: nil, dateAccessed: nil, notes: nil)
    }

    private func sourceWithCitation(_ value: String, collection: String, page: String? = nil) -> FieldSource {
        FieldSource(
            origin: .freebmd,
            raw: value,
            addedAt: Date(),
            citation: citation(collection: collection, page: page),
            quality: nil
        )
    }

    // MARK: - Tests

    @Test func profileWithAllFieldsEmitsAllParagraphs() {
        // Subject: 1834-1875, two parents (married 1832), one spouse (1858), four children.
        let subjectID = "subject"
        let fatherID = "father"
        let motherID = "mother"
        let spouseID = "spouse"
        let child1 = "c1"
        let child2 = "c2"

        let subject = makeProfile(
            id: subjectID,
            firstName: "Thomas", lastName: "Land", gender: .male,
            birthDate: "1834", birthLocation: "Belper",
            deathDate: "1875", deathLocation: "Belper",
            sources: [
                .birthDate: [sourceWithCitation("1834", collection: "FreeBMD Birth Index", page: "v7b p213")],
                .deathDate: [sourceWithCitation("1875", collection: "FreeBMD Death Index")]
            ]
        )
        let father = makeProfile(id: fatherID, firstName: "William", lastName: "Land")
        let mother = makeProfile(id: motherID, firstName: "Mary", lastName: "Slater", gender: .female)
        let spouse = makeProfile(id: spouseID, firstName: "Sarah", lastName: "Wood", gender: .female)
        let c1 = makeProfile(id: child1, firstName: "Anne", lastName: "Land", gender: .female, birthDate: "1860")
        let c2 = makeProfile(id: child2, firstName: "John", lastName: "Land", gender: .male, birthDate: "1862")

        let snapshot = FamilyGraphSnapshot(
            profiles: [subjectID: subject, fatherID: father, motherID: mother,
                       spouseID: spouse, child1: c1, child2: c2],
            relationships: [
                parentEdge(parent: fatherID, child: subjectID, role: .father),
                parentEdge(parent: motherID, child: subjectID, role: .mother),
                spouseEdge(a: fatherID, b: motherID, marriageYear: 1832, marriageLocation: "Belper"),
                spouseEdge(a: subjectID, b: spouseID, marriageYear: 1858, marriageLocation: "Belper"),
                parentEdge(parent: subjectID, child: child1),
                parentEdge(parent: subjectID, child: child2)
            ]
        )

        let doc = NarrativeComposer.compose(
            profile: subject, snapshot: snapshot,
            notes: [], hypotheses: [], questions: []
        )

        // Birth, parents, marriage, children, death = 5 paragraphs.
        #expect(doc.paragraphs.count == 5)
        #expect(doc.paragraphs[0].contains("Thomas Land was born"))
        #expect(doc.paragraphs[0].contains("1834"))
        #expect(doc.paragraphs[0].contains("Belper"))
        #expect(doc.paragraphs[1].contains("William Land"))
        #expect(doc.paragraphs[1].contains("Mary Slater"))
        #expect(doc.paragraphs[1].contains("married"))
        #expect(doc.paragraphs[2].contains("married Sarah Wood"))
        #expect(doc.paragraphs[3].contains("had two children"))
        #expect(doc.paragraphs[4].contains("died"))
        #expect(doc.paragraphs[4].contains("1875"))
    }

    @Test func profileMissingParentsOmitsParentsParagraph() {
        let subjectID = "subject"
        let subject = makeProfile(id: subjectID, birthDate: "1834", deathDate: "1875")
        let snapshot = FamilyGraphSnapshot(
            profiles: [subjectID: subject], relationships: []
        )
        let doc = NarrativeComposer.compose(
            profile: subject, snapshot: snapshot,
            notes: [], hypotheses: [], questions: []
        )
        // Only birth + death.
        #expect(doc.paragraphs.count == 2)
        for p in doc.paragraphs {
            #expect(!p.contains("child of"))
        }
    }

    @Test func profileWithNoChildrenOmitsChildrenParagraph() {
        let subjectID = "subject"
        let spouseID = "spouse"
        let subject = makeProfile(id: subjectID, birthDate: "1834")
        let spouse = makeProfile(id: spouseID, firstName: "Sarah", lastName: "Wood", gender: .female)
        let snapshot = FamilyGraphSnapshot(
            profiles: [subjectID: subject, spouseID: spouse],
            relationships: [spouseEdge(a: subjectID, b: spouseID, marriageYear: 1858)]
        )
        let doc = NarrativeComposer.compose(
            profile: subject, snapshot: snapshot,
            notes: [], hypotheses: [], questions: []
        )
        // Birth + marriage; no children, no parents, no death.
        #expect(doc.paragraphs.count == 2)
        for p in doc.paragraphs {
            #expect(!p.contains("had"))
        }
    }

    @Test func footnoteNumberingIncrementsAcrossParagraphs() {
        let subjectID = "subject"
        let subject = makeProfile(
            id: subjectID,
            birthDate: "1834", birthLocation: "Belper",
            deathDate: "1875", deathLocation: "Belper",
            sources: [
                .birthDate: [sourceWithCitation("1834", collection: "FreeBMD Birth")],
                .deathDate: [sourceWithCitation("1875", collection: "FreeBMD Death")]
            ]
        )
        let snapshot = FamilyGraphSnapshot(profiles: [subjectID: subject], relationships: [])
        let doc = NarrativeComposer.compose(
            profile: subject, snapshot: snapshot,
            notes: [], hypotheses: [], questions: []
        )
        #expect(doc.footnotes.count == 2)
        #expect(doc.footnotes[0].contains("FreeBMD Birth"))
        #expect(doc.footnotes[1].contains("FreeBMD Death"))
        // Birth paragraph references ¹, death references ².
        #expect(doc.paragraphs[0].contains("\u{00B9}"))
        #expect(doc.paragraphs.last?.contains("\u{00B2}") == true)
    }

    @Test func pronounSelectionMale() {
        let p = makeProfile(gender: .male, birthDate: "1834", deathDate: "1875")
        let snap = FamilyGraphSnapshot(profiles: [p.id: p], relationships: [])
        let doc = NarrativeComposer.compose(
            profile: p, snapshot: snap, notes: [], hypotheses: [], questions: []
        )
        // Death paragraph uses "He".
        #expect(doc.paragraphs.last?.hasPrefix("He died") == true)
    }

    @Test func pronounSelectionFemale() {
        let p = makeProfile(gender: .female, birthDate: "1834", deathDate: "1875")
        let snap = FamilyGraphSnapshot(profiles: [p.id: p], relationships: [])
        let doc = NarrativeComposer.compose(
            profile: p, snapshot: snap, notes: [], hypotheses: [], questions: []
        )
        #expect(doc.paragraphs.last?.hasPrefix("She died") == true)
    }

    @Test func pronounSelectionOther() {
        let p = makeProfile(gender: .other, birthDate: "1834", deathDate: "1875")
        let snap = FamilyGraphSnapshot(profiles: [p.id: p], relationships: [])
        let doc = NarrativeComposer.compose(
            profile: p, snapshot: snap, notes: [], hypotheses: [], questions: []
        )
        #expect(doc.paragraphs.last?.hasPrefix("They died") == true)
    }

    @Test func pronounSelectionNil() {
        let p = makeProfile(gender: nil, birthDate: "1834", deathDate: "1875")
        let snap = FamilyGraphSnapshot(profiles: [p.id: p], relationships: [])
        let doc = NarrativeComposer.compose(
            profile: p, snapshot: snap, notes: [], hypotheses: [], questions: []
        )
        #expect(doc.paragraphs.last?.hasPrefix("They died") == true)
    }

    @Test func markdownOutputBeginsWithTitleAndIncludesFootnoteSyntax() {
        let subjectID = "subject"
        let subject = makeProfile(
            id: subjectID,
            firstName: "Thomas", lastName: "Land",
            birthDate: "1834", birthLocation: "Belper",
            sources: [
                .birthDate: [sourceWithCitation("1834", collection: "FreeBMD Birth Index")]
            ]
        )
        let snapshot = FamilyGraphSnapshot(profiles: [subjectID: subject], relationships: [])
        let md = NarrativeReport.renderMarkdown(
            profileID: subjectID, snapshot: snapshot,
            notes: [], hypotheses: [], questions: []
        )
        #expect(md.hasPrefix("# Narrative — Thomas Land"))
        #expect(md.contains("[^1]"))
        #expect(md.contains("[^1]: "))
        #expect(md.contains("FreeBMD Birth Index"))
    }

    @Test func multipleMarriagesEachGetTheirOwnClause() {
        let subjectID = "subject"
        let spouse1 = "spouse1"
        let spouse2 = "spouse2"
        let subject = makeProfile(id: subjectID, gender: .male)
        let s1 = makeProfile(id: spouse1, firstName: "Mary", lastName: "Slater", gender: .female)
        let s2 = makeProfile(id: spouse2, firstName: "Jane", lastName: "Doe", gender: .female)
        let snapshot = FamilyGraphSnapshot(
            profiles: [subjectID: subject, spouse1: s1, spouse2: s2],
            relationships: [
                spouseEdge(a: subjectID, b: spouse1, marriageYear: 1858, marriageLocation: "Belper"),
                spouseEdge(a: subjectID, b: spouse2, marriageYear: 1870, marriageLocation: "Derby")
            ]
        )
        let doc = NarrativeComposer.compose(
            profile: subject, snapshot: snapshot,
            notes: [], hypotheses: [], questions: []
        )
        // Two marriage paragraphs, ordered by year.
        #expect(doc.paragraphs.count == 2)
        #expect(doc.paragraphs[0].contains("Mary Slater"))
        #expect(doc.paragraphs[0].contains("1858"))
        #expect(doc.paragraphs[0].contains("Belper"))
        #expect(doc.paragraphs[1].contains("Jane Doe"))
        #expect(doc.paragraphs[1].contains("1870"))
        #expect(doc.paragraphs[1].contains("Derby"))
    }

    @Test func singleChildUsesSonOrDaughterPhrasing() {
        let subjectID = "subject"
        let childID = "child"
        let subject = makeProfile(id: subjectID, gender: .male)
        let child = makeProfile(id: childID, firstName: "Anne", lastName: "Land", gender: .female, birthDate: "1860")
        let snapshot = FamilyGraphSnapshot(
            profiles: [subjectID: subject, childID: child],
            relationships: [parentEdge(parent: subjectID, child: childID)]
        )
        let doc = NarrativeComposer.compose(
            profile: subject, snapshot: snapshot,
            notes: [], hypotheses: [], questions: []
        )
        #expect(doc.paragraphs.count == 1)
        #expect(doc.paragraphs[0].contains("a daughter"))
        #expect(doc.paragraphs[0].contains("Anne Land"))
        #expect(doc.paragraphs[0].contains("1860"))
    }

    @Test func researchContextAppendedFromAttachedNotes() {
        let subjectID = "subject"
        let subject = makeProfile(id: subjectID, birthDate: "1834")
        let snapshot = FamilyGraphSnapshot(profiles: [subjectID: subject], relationships: [])
        let note = WorkbenchNote(
            id: UUID(),
            content: "Need to verify with parish records — found possible match in Belper baptisms.",
            tag: .todo,
            attachedTo: .profile(id: subjectID),
            createdAt: Date(),
            updatedAt: Date()
        )
        let doc = NarrativeComposer.compose(
            profile: subject, snapshot: snapshot,
            notes: [note], hypotheses: [], questions: []
        )
        #expect(doc.paragraphs.last?.hasPrefix("Research notes:") == true)
        #expect(doc.paragraphs.last?.contains("Todo") == true)
    }
}
