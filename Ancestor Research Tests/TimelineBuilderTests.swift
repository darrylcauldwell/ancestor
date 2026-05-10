import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for M9 TimelineBuilder — pure transformation from snapshot + workbench
/// data into derived timeline events (DESIGN.md §7.8).
struct TimelineBuilderTests {

    // MARK: - Fixtures

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        birthDate: String? = nil,
        birthLocation: String? = nil,
        deathDate: String? = nil,
        deathLocation: String? = nil,
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: nil,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: birthLocation,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: deathLocation,
            bio: nil,
            isDeleted: false,
            sources: sources,
            disputes: [:]
        )
    }

    private func spouseEdge(
        _ a: String, _ b: String,
        marriageDate: String? = nil,
        marriageLocation: String? = nil,
        divorceDate: String? = nil
    ) -> Relationship {
        Relationship(
            id: UUID(), from: a, to: b,
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: marriageDate.map { GenealogicalDate(parsing: $0) },
            marriageLocation: marriageLocation,
            divorceDate: divorceDate.map { GenealogicalDate(parsing: $0) }
        )
    }

    private func note(
        _ content: String,
        attachedTo: NoteAttachment,
        tag: NoteTag = .observation,
        createdAt: Date = Date()
    ) -> WorkbenchNote {
        WorkbenchNote(
            id: UUID(),
            content: content,
            tag: tag,
            attachedTo: attachedTo,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func hypothesis(
        profileID: String,
        field: ProfileField,
        value: String
    ) -> Hypothesis {
        Hypothesis(
            id: UUID(),
            claim: .fieldValue(profileID: profileID, field: field, value: value),
            confidence: .working,
            reasoning: "",
            supportingEvidence: [],
            contradictingEvidence: [],
            status: .active,
            createdAt: Date(),
            resolvedAt: nil,
            dismissalReason: nil
        )
    }

    private func question(
        text: String,
        profileIDs: [String]
    ) -> OpenQuestion {
        OpenQuestion(
            id: UUID(),
            text: text,
            profileIDs: profileIDs,
            priority: .medium,
            status: .open,
            triedSources: nil,
            promotedFrom: nil,
            createdAt: Date(),
            resolvedAt: nil,
            resolution: nil
        )
    }

    // MARK: - Birth + death

    @Test func birthAndDeathEventsEmittedFromProfileFields() {
        let citation = Citation(
            repository: nil, collection: "FreeBMD",
            title: nil, page: nil, url: nil, dateAccessed: nil, notes: nil
        )
        let source = FieldSource(
            origin: .freebmd, raw: "FreeBMD",
            addedAt: Date(), citation: citation, quality: .primary
        )
        let profile = makeProfile(
            id: "p1",
            firstName: "Thomas", lastName: "Land",
            birthDate: "1834", birthLocation: "Belper, Derbyshire",
            deathDate: "1875", deathLocation: "Belper",
            sources: [.birthDate: [source]]
        )
        let snap = FamilyGraphSnapshot(profiles: ["p1": profile], relationships: [])

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [], hypotheses: [], questions: []
        )

        #expect(events.count == 2)
        #expect(events[0].kind == .birth)
        #expect(events[0].title == "Born")
        #expect(events[0].description == "Belper, Derbyshire")
        #expect(events[0].date?.bestYear == 1834)
        #expect(events[0].sources.count == 1)
        #expect(events[1].kind == .death)
        #expect(events[1].date?.bestYear == 1875)
    }

    // MARK: - Marriage

    @Test func marriageEventsEmittedForSpouseRelationships() {
        let p1 = makeProfile(id: "p1", firstName: "Thomas", lastName: "Land")
        let p2 = makeProfile(id: "p2", firstName: "Mary", lastName: "Slater")
        let snap = FamilyGraphSnapshot(
            profiles: ["p1": p1, "p2": p2],
            relationships: [
                spouseEdge("p1", "p2", marriageDate: "1858", marriageLocation: "Belper"),
            ]
        )

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [], hypotheses: [], questions: []
        )

        let marriages = events.filter { $0.kind == .marriage }
        #expect(marriages.count == 1)
        #expect(marriages.first?.title == "Married Mary Slater")
        #expect(marriages.first?.description == "Belper")
        #expect(marriages.first?.date?.bestYear == 1858)
    }

    @Test func marriageDetectedWhenProfileIsRelationshipTarget() {
        // Edge stored as p2 -> p1 still surfaces a marriage row for p1.
        let p1 = makeProfile(id: "p1", firstName: "Thomas", lastName: "Land")
        let p2 = makeProfile(id: "p2", firstName: "Mary", lastName: "Slater")
        let snap = FamilyGraphSnapshot(
            profiles: ["p1": p1, "p2": p2],
            relationships: [
                spouseEdge("p2", "p1", marriageDate: "1858"),
            ]
        )

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [], hypotheses: [], questions: []
        )

        #expect(events.contains { $0.kind == .marriage && $0.title == "Married Mary Slater" })
    }

    // MARK: - Workbench notes

    @Test func notesAttachedToProfileBecomeNoteEvents_yearFromContent() {
        let profile = makeProfile(id: "p1")
        let snap = FamilyGraphSnapshot(profiles: ["p1": profile], relationships: [])
        let n = note(
            "Family bible confirms January 1834 entry.",
            attachedTo: .profile(id: "p1")
        )

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [n], hypotheses: [], questions: []
        )

        let noteEvents = events.filter { $0.kind == .note }
        #expect(noteEvents.count == 1)
        #expect(noteEvents.first?.date?.bestYear == 1834)
        #expect(noteEvents.first?.attachedNoteCount == 1)
    }

    @Test func noteWithoutYearMentionFallsBackToCreatedAtYear() {
        let profile = makeProfile(id: "p1")
        let snap = FamilyGraphSnapshot(profiles: ["p1": profile], relationships: [])

        // Note with no year in content — anchor on createdAt year.
        let comps = DateComponents(year: 2024, month: 6, day: 15)
        let createdAt = Calendar.current.date(from: comps)!
        let n = note(
            "Need to check parish register.",
            attachedTo: .profile(id: "p1"),
            tag: .todo,
            createdAt: createdAt
        )

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [n], hypotheses: [], questions: []
        )

        let noteEvents = events.filter { $0.kind == .note }
        #expect(noteEvents.count == 1)
        #expect(noteEvents.first?.date?.bestYear == 2024)
    }

    @Test func notesAttachedToOtherProfilesAreIgnored() {
        let profile = makeProfile(id: "p1")
        let snap = FamilyGraphSnapshot(profiles: ["p1": profile], relationships: [])
        let n = note("1850 census check", attachedTo: .profile(id: "other"))

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [n], hypotheses: [], questions: []
        )

        #expect(!events.contains { $0.kind == .note })
    }

    // MARK: - Hypotheses

    @Test func fieldValueHypothesesBecomeHypotheticalEvents() {
        let profile = makeProfile(id: "p1")
        let snap = FamilyGraphSnapshot(profiles: ["p1": profile], relationships: [])
        let h = hypothesis(profileID: "p1", field: .birthDate, value: "1834")

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [], hypotheses: [h], questions: []
        )

        let hypoEvents = events.filter { $0.kind == .hypothesis }
        #expect(hypoEvents.count == 1)
        #expect(hypoEvents.first?.isHypothetical == true)
        #expect(hypoEvents.first?.description == "1834")
        #expect(hypoEvents.first?.date?.bestYear == 1834)
    }

    @Test func hypothesesForOtherProfilesAreIgnored() {
        let profile = makeProfile(id: "p1")
        let snap = FamilyGraphSnapshot(profiles: ["p1": profile], relationships: [])
        let h = hypothesis(profileID: "other", field: .birthDate, value: "1900")

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [], hypotheses: [h], questions: []
        )

        #expect(!events.contains { $0.kind == .hypothesis })
    }

    // MARK: - Open questions

    @Test func openQuestionsReferencingProfileBecomeEvents() {
        let profile = makeProfile(id: "p1")
        let snap = FamilyGraphSnapshot(profiles: ["p1": profile], relationships: [])
        let q = question(
            text: "Was this at St Peter's or All Saints?",
            profileIDs: ["p1"]
        )

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [], hypotheses: [], questions: [q]
        )

        let qEvents = events.filter { $0.kind == .openQuestion }
        #expect(qEvents.count == 1)
        #expect(qEvents.first?.openQuestionCount == 1)
        #expect(qEvents.first?.description == "Was this at St Peter's or All Saints?")
    }

    @Test func openQuestionsForOtherProfilesAreIgnored() {
        let profile = makeProfile(id: "p1")
        let snap = FamilyGraphSnapshot(profiles: ["p1": profile], relationships: [])
        let q = question(text: "Some other question", profileIDs: ["other"])

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [], hypotheses: [], questions: [q]
        )

        #expect(!events.contains { $0.kind == .openQuestion })
    }

    // MARK: - Sorting

    @Test func eventsSortedAscendingWithUndatedAtBottom() {
        let profile = makeProfile(
            id: "p1",
            birthDate: "1834", birthLocation: "Belper",
            deathDate: "1875", deathLocation: "Belper"
        )
        let p2 = makeProfile(id: "p2", firstName: "Mary", lastName: "Slater")
        let snap = FamilyGraphSnapshot(
            profiles: ["p1": profile, "p2": p2],
            relationships: [
                spouseEdge("p1", "p2", marriageDate: "1858"),
            ]
        )
        let q = question(text: "Open question", profileIDs: ["p1"])

        let events = TimelineBuilder.build(
            profileID: "p1", snapshot: snap,
            notes: [], hypotheses: [], questions: [q]
        )

        // Dated events first (ascending), then the undated open question.
        #expect(events.count == 4)
        #expect(events[0].kind == .birth)
        #expect(events[1].kind == .marriage)
        #expect(events[2].kind == .death)
        #expect(events[3].kind == .openQuestion)
        #expect(events[3].date == nil)
    }

    // MARK: - Profile not found

    @Test func unknownProfileReturnsEmptyArray() {
        let snap = FamilyGraphSnapshot.empty
        let events = TimelineBuilder.build(
            profileID: "ghost", snapshot: snap,
            notes: [], hypotheses: [], questions: []
        )
        #expect(events.isEmpty)
    }
}
