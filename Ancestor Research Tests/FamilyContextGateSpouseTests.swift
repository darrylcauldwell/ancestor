import Testing
import Foundation
@testable import AncestorKit
@testable import Ancestor_Research

/// EV25 (2026-08-26) — the family-context gate reported "no known family
/// members in household" over the 1861 Gladwin household, which holds Hannah's
/// own linked husband on the Head row and her linked daughter on an
/// abbreviated "Daur" row.
///
/// Two independent mechanisms produced that:
///  1. THE ROLE FILTER. Roster roles are recorded relative to the HEAD, so a
///     husband on his own schedule is "Head", never "Husband". The gate's
///     hand-rolled `contains("wife") || contains("husband")` therefore filtered
///     her linked spouse out before any name was compared. The child arm had
///     the same shape and missed the FreeCen abbreviations Dau/Daur/Daug.
///  2. THE MAIDEN-NAME BUG (EV23's, in the scorer). `spouseName` is the tree's
///     display form, which by convention carries a wife's MAIDEN surname while
///     every census indexes her under her MARRIED one.
///
/// The repair routes both through machinery AncestorKit already has and that
/// is already correct — `CensusFamilyLinker.category` for roster roles (it
/// already excludes grand-/step-/in-law and non-family rows) and
/// `RosterIdentity.knownSurnames` for the surname union. The whole defect
/// exists because the scorer re-derived by hand what AncestorKit already knew.
nonisolated struct FamilyContextGateSpouseTests {

    private func subject(given: String, surname: String, gender: Gender,
                         spouseName: String?, spouseGiven: String?, spouseSurname: String?,
                         spouseKnownSurnames: [String] = [], children: [String] = []) -> ResearchSubject {
        ResearchSubject(
            surname: surname, givenName: given,
            birthYearFrom: 1821, birthYearTo: 1825,
            gender: gender, region: .englandAndWales, mode: .extend,
            familyContext: FamilyContext(
                spouseName: spouseName, spouseSurname: spouseSurname,
                spouseGivenName: spouseGiven, spouseFatherSurname: nil,
                childNames: children,
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil,
                spouseKnownSurnames: spouseKnownSurnames))
    }

    private func census(_ rows: [(name: String, rel: String)]) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: "cen-1861", sourceID: "freecen", name: nil,
                                 surname: "Gladwin", givenName: "Hannah",
                                 detailURL: nil, rawFields: [:]),
            censusYear: 1861, age: 38, birthYear: 1823,
            birthPlace: nil, birthCounty: nil, relationship: nil,
            occupation: nil, address: nil, parish: nil, district: "Belper",
            household: rows.map { HouseholdMember(name: $0.name, relationship: $0.rel) }))
    }

    private var lowGreen1861: SourceRecord {
        census([("William Gladwin", "Head"), ("Hannah Gladwin", "Wife"), ("Emma Gladwin", "Daur")])
    }

    private func gate(_ record: SourceRecord, _ s: ResearchSubject) -> GateResult? {
        RecordScorer.classify(record: record, subject: s, searchType: .census)
            .gates.first { $0.gate == .familyContext }
    }

    private func hannah() -> ResearchSubject {
        subject(given: "Hannah", surname: "Hewkin", gender: .female,
                spouseName: "William Gladwin", spouseGiven: "William",
                spouseSurname: "Gladwin", spouseKnownSurnames: ["GLADWIN"])
    }

    /// THE defect. Subject is the WIFE; her linked husband is the Head row.
    @Test func linkedHusbandOnTheHeadRowEndorsesTheHousehold() {
        let g = gate(lowGreen1861, hannah())
        #expect(g?.outcome == .pass, "the Head row IS her husband — got \(String(describing: g?.reason))")
        #expect(g?.reason.contains("no known family members") != true)
    }

    /// EV23's half, in the scorer: the wife is stored under her maiden lastName,
    /// so spouseName is "Hannah Hewkin" while the roster says "Hannah Gladwin".
    @Test func maidenStoredWifeIsRecognisedUnderHerMarriedSurname() {
        let william = subject(given: "William", surname: "Gladwin", gender: .male,
                              spouseName: "Hannah Hewkin", spouseGiven: "Hannah",
                              spouseSurname: "Hewkin", spouseKnownSurnames: ["GLADWIN", "HEWKIN"])
        let g = gate(lowGreen1861, william)
        #expect(g?.outcome == .pass, "got \(String(describing: g?.reason))")
    }

    /// "Daur" is the FreeCen norm and contains neither "son" nor "daughter".
    /// The spouse here ("Mary") is absent from the roster, so only the child
    /// arm can pass.
    @Test func abbreviatedDaughterRowCorroboratesTheHousehold() {
        let william = subject(given: "William", surname: "Gladwin", gender: .male,
                              spouseName: "Mary Gladwin", spouseGiven: "Mary",
                              spouseSurname: "Gladwin", children: ["Emma Gladwin"])
        let g = gate(lowGreen1861, william)
        #expect(g?.outcome == .pass, "got \(String(describing: g?.reason))")
        #expect(g?.reason.contains("Emma") == true)
    }

    /// Negative control — the widening must not make every household match.
    @Test func aDifferentFamilysHouseholdStillReportsNoKnownMembers() {
        let g = gate(census([("Joseph Wheeldon", "Head"), ("Sarah Wheeldon", "Wife"),
                             ("Alice Wheeldon", "Daur")]), hannah())
        #expect(g?.outcome == .softFail)
        #expect(g?.reason == "no known family members in household")
    }

    /// DS-02 preserved on the newly-admitted Head row: a bare forename is a
    /// weak match, not an endorsement of any household with a William at its head.
    @Test func forenameOnlyHeadRowStillOnlySoftFails() {
        let g = gate(census([("William", "Head"), ("Ann", "Wife")]), hannah())
        #expect(g?.outcome == .softFail)
    }

    /// The spouse widening admits `.spouse` and `.head` ONLY. A co-resident
    /// carrying the linked spouse's exact name — a lodger, an in-law — is
    /// excluded by `CensusFamilyLinker.category` and by the hand-rolled tests
    /// alike, so the gate must not endorse the household on that row.
    @Test func aLodgerOrInLawNamedLikeTheSpouseIsNotAdmitted() {
        let lodger = gate(
            census([("Joseph Wheeldon", "Head"), ("William Gladwin", "Lodger")]), hannah())
        #expect(lodger?.outcome == .softFail, "got \(String(describing: lodger?.reason))")
        #expect(lodger?.reason == "no known family members in household")

        let inLaw = gate(
            census([("Joseph Wheeldon", "Head"), ("William Gladwin", "Son in law")]), hannah())
        #expect(inLaw?.outcome == .softFail, "got \(String(describing: inLaw?.reason))")
    }

    // MARK: - Review F04 (2026-08-26): the `.head` widening needs discriminators

    /// A roster row with the columns FreeCen actually transcribes — sex, and the
    /// "this is the person you searched for" marker. The EV25 fixtures above
    /// deliberately carry neither, which is why the widening looked safe.
    private struct RosterRow {
        let name: String
        let rel: String
        var sex: String?
        var isTarget: Bool?
        init(_ name: String, _ rel: String, sex: String? = nil, isTarget: Bool? = nil) {
            self.name = name; self.rel = rel; self.sex = sex; self.isTarget = isTarget
        }
    }

    /// A census record carrying the SUBJECT's own relationship-to-head
    /// (`CensusRecord.relationship` — FreeCen fills it from the target row).
    private func schedule(
        id: String, year: Int, surname: String, givenName: String,
        subjectRelationship: String?, _ rows: [RosterRow]
    ) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen", name: nil,
                                 surname: surname, givenName: givenName,
                                 detailURL: nil, rawFields: [:]),
            censusYear: year, age: nil, birthYear: nil,
            birthPlace: nil, birthCounty: nil, relationship: subjectRelationship,
            occupation: nil, address: nil, parish: nil, district: "Belper",
            household: rows.map {
                HouseholdMember(name: $0.name, relationship: $0.rel,
                                sex: $0.sex, isTarget: $0.isTarget)
            }))
    }

    /// THE F04 defect. John is a LODGER on a widow's schedule. Her name matches
    /// his wife's married form exactly, so the unguarded `.head` arm read the
    /// widow as his wife: `familyContext` passed, which is precisely
    /// `RecordScorer.isDiscriminated`, so the wrong household then won the
    /// census-1881 exclusivity slot and demoted John's true schedule.
    ///
    /// The schedule says where he sits in the dwelling and it is not "married to
    /// the Head" — that statement is the discriminator, not sex (the widow and
    /// John are already opposite sexes, so a sex rule alone cannot see this).
    @Test func aWidowHeadedHouseholdDoesNotEndorseALodgerSubject() {
        let john = subject(given: "John", surname: "Cauldwell", gender: .male,
                           spouseName: "Mary Smith", spouseGiven: "Mary",
                           spouseSurname: "Smith",
                           spouseKnownSurnames: ["CAULDWELL", "SMITH"])
        let record = schedule(
            id: "cen-1881-widow", year: 1881, surname: "Cauldwell", givenName: "John",
            subjectRelationship: "Lodger",
            [RosterRow("Mary Cauldwell", "Head", sex: "F"),
             RosterRow("Ann Cauldwell", "Daur", sex: "F"),
             RosterRow("John Cauldwell", "Lodger", sex: "M", isTarget: true)])

        let scored = RecordScorer.classify(record: record, subject: john, searchType: .census)
        let g = scored.gates.first { $0.gate == .familyContext }
        #expect(g?.outcome == .softFail,
                "a Head is nobody's wife when the subject's own row says Lodger — got \(String(describing: g?.reason))")
        #expect(!RecordScorer.isDiscriminated(scored),
                "a false family match becomes an exclusivity discriminator and demotes the TRUE census")
    }

    /// …and the same discriminator must NOT narrow EV25 in the shape FreeCen
    /// really returns. Every EV25 fixture above leaves `relationship` nil; this
    /// one fills it exactly as `FreeCenSource` does for a wife subject, so the
    /// Head row is still her husband and still endorses.
    @Test func aWifeSubjectsOwnRosterRoleStillAdmitsTheHeadRow() {
        let record = schedule(
            id: "cen-1861-gladwin", year: 1861, surname: "Gladwin", givenName: "Hannah",
            subjectRelationship: "Wife",
            [RosterRow("William Gladwin", "Head", sex: "M"),
             RosterRow("Hannah Gladwin", "Wife", sex: "F", isTarget: true),
             RosterRow("Emma Gladwin", "Daur", sex: "F")])
        let g = RecordScorer.classify(record: record, subject: hannah(), searchType: .census)
            .gates.first { $0.gate == .familyContext }
        #expect(g?.outcome == .pass, "got \(String(describing: g?.reason))")
    }

    /// A Head of the SAME sex as the subject cannot be their wife, however
    /// exactly the name matches. Evelyn was a men's name in the 19th century, so
    /// a male "Evelyn Land" heading an unrelated household is an exact-name
    /// collision with Joseph's wife — the one shape where the roster's own sex
    /// column is the only thing that can refuse.
    @Test func aSameSexHeadIsNotReadAsTheSubjectsWife() {
        let joseph = subject(given: "Joseph", surname: "Land", gender: .male,
                             spouseName: "Evelyn Land", spouseGiven: "Evelyn",
                             spouseSurname: "Land", spouseKnownSurnames: ["LAND"])
        let male = schedule(
            id: "cen-1881-land-m", year: 1881, surname: "Land", givenName: "Joseph",
            subjectRelationship: nil,
            [RosterRow("Evelyn Land", "Head", sex: "M"), RosterRow("Sarah Land", "Daur", sex: "F")])
        let g = RecordScorer.classify(record: male, subject: joseph, searchType: .census)
            .gates.first { $0.gate == .familyContext }
        #expect(g?.outcome == .softFail, "got \(String(describing: g?.reason))")

        // Refusal is on POSITIVE contradiction only: the same roster with the
        // Head transcribed female is the ordinary EV25 case and still endorses.
        let female = schedule(
            id: "cen-1881-land-f", year: 1881, surname: "Land", givenName: "Joseph",
            subjectRelationship: nil,
            [RosterRow("Evelyn Land", "Head", sex: "F"), RosterRow("Sarah Land", "Daur", sex: "F")])
        let g2 = RecordScorer.classify(record: female, subject: joseph, searchType: .census)
            .gates.first { $0.gate == .familyContext }
        #expect(g2?.outcome == .pass, "got \(String(describing: g2?.reason))")
    }

    /// You are never your own spouse. A merge artefact — a profile spouse-linked
    /// to their own same-named duplicate — otherwise let the subject's OWN
    /// roster row endorse the household as her husband's.
    @Test func theSubjectsOwnRosterRowNeverScoresAsTheirSpouse() {
        let mary = subject(given: "Mary", surname: "Cauldwell", gender: .female,
                           spouseName: "Mary Cauldwell", spouseGiven: "Mary",
                           spouseSurname: "Cauldwell", spouseKnownSurnames: ["CAULDWELL"])
        let record = schedule(
            id: "cen-1881-self", year: 1881, surname: "Cauldwell", givenName: "Mary",
            subjectRelationship: "Wife",
            [RosterRow("John Cauldwell", "Head"),
             RosterRow("Mary Cauldwell", "Wife", isTarget: true)])
        let g = RecordScorer.classify(record: record, subject: mary, searchType: .census)
            .gates.first { $0.gate == .familyContext }
        #expect(g?.outcome == .softFail,
                "the subject's own row endorsed the household as her spouse's — got \(String(describing: g?.reason))")
    }

    /// The classifier the gate now routes through is the one that already knew
    /// to EXCLUDE the modifier forms. Pinned at the primitive because the
    /// hand-rolled `contains` tests still sit beside it in the child arm —
    /// "grandson" contains "son", so that pre-existing hole is unchanged by
    /// EV25 (widening only) and must not be mistaken for something this fix
    /// introduced. Its own defect if the owner wants it closed.
    @Test func theRosterClassifierExcludesModifierForms() {
        #expect(CensusFamilyLinker.category(of: "Grandson") == nil)
        #expect(CensusFamilyLinker.category(of: "Granddaughter") == nil)
        #expect(CensusFamilyLinker.category(of: "Step son") == nil)
        #expect(CensusFamilyLinker.category(of: "Son in law") == nil)
        #expect(CensusFamilyLinker.category(of: "Lodger") == nil)
        #expect(CensusFamilyLinker.category(of: "Wife's sister") == nil)
        // …and it DOES know the forms the hand-rolled tests missed.
        #expect(CensusFamilyLinker.category(of: "Head") == .head)
        #expect(CensusFamilyLinker.category(of: "Hd") == .head)
        #expect(CensusFamilyLinker.category(of: "Daur") == .child)
        #expect(CensusFamilyLinker.category(of: "Daug") == .child)
    }
}
