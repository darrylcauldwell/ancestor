import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Subject place model Slice 2 — the one place shape.
///
/// Slice 2's contract is narrow and worth stating plainly: `places` is
/// POPULATED and nothing reads it, so behaviour change is zero by construction.
/// These tests pin the two things Slice 3 will lean on — that the collection
/// really does carry every place the five flattened fields carry (and the two
/// they drop), and that its ORDER reproduces today's precedence, because
/// `places.chapmanCodes.first` is what will replace `homeChapmanCode`.
@MainActor
struct PlaceRefTests {

    // MARK: - Fixtures

    private func profile(
        birth: String? = nil, birthCode: String? = nil,
        death: String? = nil, deathCode: String? = nil
    ) -> Profile {
        Profile(id: "subject", firstName: "Test", lastName: "Person", gender: .male,
                birthDate: GenealogicalDate(parsing: "1861"),
                birthLocation: birth, birthLocationCode: birthCode,
                deathDate: GenealogicalDate(parsing: "1921"),
                deathLocation: death, deathLocationCode: deathCode,
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func subject(
        _ p: Profile, events: [LifeEvent] = [], relationships: [Relationship] = [],
        projectHome: String = ""
    ) -> ResearchSubject {
        let snapshot = FamilyGraphSnapshot(
            profiles: [p.id: p], relationships: relationships, lifeEvents: [p.id: events])
        return ResearchSubject.fromProfile(p, snapshot: snapshot, homeChapmanCode: projectHome)
    }

    private func event(
        _ type: LifeEventType, _ place: String, code: String? = nil, year: Int,
        sensitive: Bool = false
    ) -> LifeEvent {
        var e = LifeEvent(id: UUID(), profileID: "subject", type: type,
                          date: GenealogicalDate(parsing: String(year)),
                          location: place, locationCode: code)
        e.sensitive = sensitive
        return e
    }

    // MARK: - Every place lands, including the two nothing carries today

    @Test func birthAndDeathBothBecomePlaces() {
        let s = subject(profile(birth: "Wirksworth, Derbyshire", death: "Leek, Staffordshire"))
        #expect(s.places.of(.birth).first?.text == "Wirksworth, Derbyshire")
        #expect(s.places.of(.death).first?.text == "Leek, Staffordshire")
    }

    /// The gap that started this spec. A census location is stored identically
    /// to a residence — same `location`, same `locationCode`, same type — and
    /// today produces no axis anywhere. Here it is simply a place.
    @Test func aCensusLocationIsAPlace() {
        let s = subject(profile(), events: [event(.census, "Leek, Staffordshire", year: 1891)])
        #expect(s.places.of(.census).map(\.text) == ["Leek, Staffordshire"])
        #expect(s.places.of(.census).first?.chapmanCode == "STS")
        #expect(s.residenceAxes.isEmpty, "…while the flattened field still shows nothing")
    }

    /// A marriage place is the fourth `(location, code)` storage site and the
    /// only one no flattened subject field represents at all.
    @Test func aMarriagePlaceIsCarried() {
        let edge = Relationship(
            id: UUID(), from: "subject", to: "spouse", type: .spouse,
            role: nil, subtype: .biological,
            marriageDate: GenealogicalDate(parsing: "1885"),
            marriageLocation: "Bakewell, Derbyshire",
            divorceDate: nil)
        let s = subject(profile(), relationships: [edge])
        #expect(s.places.of(PlaceRef.Kind.marriage).map(\PlaceRef.text) == ["Bakewell, Derbyshire"])
    }

    @Test func aResidenceIsAPlaceAndStillAnAxis() {
        let s = subject(profile(birth: "Wirksworth, Derbyshire"),
                        events: [event(.residence, "Leek, Staffordshire", year: 1881)])
        #expect(s.places.of(.residence).map(\.text) == ["Leek, Staffordshire"])
        #expect(s.residenceAxes.count == 1, "Slice 2 adds; it does not replace")
    }

    // MARK: - Sensitive places are carried, not destroyed

    /// `residenceAxes` filters `!event.sensitive` at derivation, which destroys
    /// the information that a place was withheld. The collection keeps it and
    /// excludes it at the accessor, so no consumer sees a change.
    @Test func aSensitivePlaceIsExcludedByDefaultButNotLost() {
        let s = subject(profile(),
                        events: [event(.residence, "Leek, Staffordshire", year: 1881,
                                       sensitive: true)])
        #expect(s.residenceAxes.isEmpty, "today's behaviour is unchanged")
        #expect(s.places.of(.residence).isEmpty, "and the accessor matches it by default")
        #expect(s.places.of(.residence, includingSensitive: true).count == 1,
                "but the place survives, flagged, for a consumer that may ask")
        #expect(s.places.first?.sensitive == true)
    }

    // MARK: - Order is the contract

    /// `places.chapmanCodes.first` must be the county `homeChapmanCode` derives,
    /// because that is what Slice 3 replaces it with. Birth outranks death.
    @Test func theFirstCountyMatchesTheAnchorWhenBirthIsKnown() {
        let s = subject(profile(birth: "Wirksworth, Derbyshire", death: "Leek, Staffordshire"))
        #expect(s.homeChapmanCode == "DBY")
        #expect(s.places.chapmanCodes.first == "DBY")
        #expect(s.places.chapmanCodes == ["DBY", "STS"], "both counties, best-evidenced first")
    }

    @Test func theFirstCountyMatchesTheAnchorWhenOnlyDeathIsKnown() {
        let s = subject(profile(death: "Leek, Staffordshire"), projectHome: "DBY")
        #expect(s.homeChapmanCode == "STS")
        #expect(s.places.chapmanCodes.first == "STS")
    }

    /// The project fallback is NOT a place of this person's, so it is absent —
    /// which is exactly why an anchor-less subject must stay anchor-less rather
    /// than acquire a manufactured one.
    @Test func theProjectFallbackIsNotAPlace() {
        let s = subject(profile(), projectHome: "DBY")
        #expect(s.homeChapmanCode == "DBY", "the flattened field still takes the fallback")
        #expect(s.places.isEmpty, "but the person has no place of their own")
        #expect(s.places.chapmanCodes.isEmpty)
    }

    /// A coded place outranks its own text, uniformly, via one derivation
    /// instead of the longhand repeated at each call site.
    @Test func aCodeOutranksItsText() {
        let s = subject(profile(birth: "Leek, Staffordshire", birthCode: "DBY:Wirksworth"))
        #expect(s.places.of(.birth).first?.chapmanCode == "DBY")
        #expect(s.homeChapmanCode == "DBY", "matching the flattened derivation")
    }

    @Test func kindPrecedenceIsStableRegardlessOfEventOrder() {
        let events = [
            event(.census, "Leek, Staffordshire", year: 1891),
            event(.residence, "Matlock, Derbyshire", year: 1881),
            event(.burial, "Youlgreave, Derbyshire", year: 1921),
        ]
        let forward = subject(profile(birth: "Wirksworth, Derbyshire"), events: events)
        let backward = subject(profile(birth: "Wirksworth, Derbyshire"),
                               events: events.reversed())
        #expect(forward.places == backward.places)
        #expect(forward.places.map(\.kind) == [.birth, .burial, .residence, .census])
    }

    // MARK: - The year question, asked once

    @Test func anOpenEndedResidenceAppliesForever() {
        let ref = PlaceRef(text: "Leek", kind: .residence, yearFrom: 1930)
        #expect(ref.applies(to: 1935))
        #expect(ref.applies(to: 1930))
        #expect(!ref.applies(to: 1929))
    }

    @Test func anOpenStartResidenceAppliesBackwards() {
        let ref = PlaceRef(text: "Leek", kind: .residence, yearTo: 1930)
        #expect(ref.applies(to: 1800))
        #expect(!ref.applies(to: 1931))
    }

    /// A caller with no year is asking "could this be relevant" — and the
    /// answer is yes. A nil year must never silently exclude places.
    @Test func aNilYearMatchesEverything() {
        #expect(PlaceRef(text: "Leek", kind: .residence, yearFrom: 1930, yearTo: 1940)
            .applies(to: nil))
    }

    @Test func filteringByYearSelectsTheRightResidence() {
        let s = subject(profile(), events: [
            event(.residence, "Matlock, Derbyshire", year: 1881),
            event(.residence, "Leek, Staffordshire", year: 1891),
        ])
        #expect(s.places.of(.residence, in: 1881).map(\.text) == ["Matlock, Derbyshire"],
                "the 1891 residence has not started yet in 1881")
    }

    // MARK: - chapmanCodes

    @Test func chapmanCodesDeduplicatesAndKeepsFirstSeenOrder() {
        let s = subject(profile(birth: "Wirksworth, Derbyshire",
                                death: "Bakewell, Derbyshire"),
                        events: [event(.residence, "Leek, Staffordshire", year: 1881)])
        #expect(s.places.chapmanCodes == ["DBY", "STS"], "DBY once, and first")
    }

    /// Sorting would destroy the precedence the order exists to express — the
    /// county a one-axis source should take is the best-evidenced one, not the
    /// alphabetically first.
    @Test func chapmanCodesIsNotSorted() {
        let s = subject(profile(birth: "Leek, Staffordshire"),
                        events: [event(.residence, "Matlock, Derbyshire", year: 1881)])
        #expect(s.places.chapmanCodes == ["STS", "DBY"])
    }

    @Test func anUnresolvableePlaceContributesNoCounty() {
        let s = subject(profile(birth: "Shining Row"))
        #expect(s.places.count == 1, "the place is still carried…")
        #expect(s.places.chapmanCodes.isEmpty, "…it just yields no county")
    }
}
