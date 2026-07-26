import Testing
import Foundation
@testable import Ancestor_Research

/// #CPC-Change1 acceptance tests (`AncestorApp/CROSS_PROFILE_CORROBORATION_SPEC.md`
/// Change 1). Anchored to the live demonstrator: Mary Ellen Thompson ×
/// William Holmes, FreeBMD marriage Dec 1915 Bakewell 7b/2130a, son
/// Reginald b. 1916, William d. 1919.
///
/// Purity (criterion 11): `SpousePairCorroborator` is exercised here with no
/// database, no network, and no model — everything is passed in as data; its
/// compilation unit imports Foundation only.
struct CrossProfileCorroboratorTests {

    // MARK: - Criterion 1: demonstrator → reciprocal tier, weak anchor

    @Test func demonstratorFindsReciprocalTierWithWeakAnchor() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .found(let f) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(f.tier == .reciprocal)
        #expect(f.anchor == .weak("death-year precedence (@WILLIAM@ d.1919)"))
        #expect(f.proposedEarliestYear == 1915)
        #expect(f.proposedLatestYear == 1915)
        #expect(f.registrationLabel == "registered Dec quarter 1915")
        #expect(f.proposedLocation == "BAKEWELL")
        #expect(f.subjectRecordID == "mary-2130a")
        #expect(f.partnerRecordID == "william-2130a")
        #expect(f.edgeID == "edge-1")
    }

    @Test func marchQuarterWidensEarliestIntoPriorYear() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "s", record: marriage("s", surname: "THOMPSON", givenName: "MARY",
                                                          year: 1915, quarter: "Mar", spouseName: "Holmes"))],
            partnerMarriages: [(id: "p", record: marriage("p", surname: "HOLMES", givenName: "WILLIAM",
                                                          year: 1915, quarter: "Mar", spouseName: "Thompson"))],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .found(let f) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(f.proposedEarliestYear == 1914, "late clergy returns: a Mar-quarter registration can record a prior-year marriage")
        #expect(f.proposedLatestYear == 1915)
    }

    // MARK: - Criterion 2: child-MMN strong anchor

    @Test func childMMNMatchingMaidenSideUniquelyIsStrongAnchor() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: mary(deathYear: nil), partner: william(deathYear: nil),
            childMMNAnchors: [.init(mothersMaidenName: "Thompson", birthYear: 1916)],
            edgeID: "edge-1"
        )
        guard case .found(let f) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(f.anchor == .strong("child-MMN(Thompson)"))
    }

    @Test func childMMNMatchingBothSurnameSetsIsNotAnAnchor() {
        // MMN "Holmes" matches Mary's married-name set AND William's own
        // surname — it does not uniquely identify the maiden side.
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: mary(deathYear: nil), partner: william(deathYear: nil),
            childMMNAnchors: [.init(mothersMaidenName: "Holmes", birthYear: 1916)],
            edgeID: "edge-1"
        )
        guard case .found(let f) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(f.anchor == Anchor.none)
    }

    @Test func childBornBeforeMarriageIsNotAnMMNAnchor() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: mary(deathYear: nil), partner: william(deathYear: nil),
            childMMNAnchors: [.init(mothersMaidenName: "Thompson", birthYear: 1910)],
            edgeID: "edge-1"
        )
        guard case .found(let f) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(f.anchor == Anchor.none)
    }

    // MARK: - Criterion 3: doubly-thin pair → found, anchor .none

    @Test func doublyThinPairFindsWithNoAnchor() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: mary(deathYear: nil), partner: william(deathYear: nil),
            edgeID: "edge-1"
        )
        guard case .found(let f) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(f.anchor == Anchor.none, "sweep-emittable, never elevation-grade")
    }

    // MARK: - Criterion 4: tier assignment

    @Test func absentSpouseColumnOnOneSideIsSamePagePrior() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "mary-2130a", record: marriage("mary-2130a", surname: "THOMPSON",
                                                                   givenName: "MARY ELLEN", year: 1915,
                                                                   quarter: "Dec", spouseName: nil))],
            partnerMarriages: [williamRecord()],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .found(let f) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(f.tier == .samePagePrior)
    }

    @Test func presentButContradictingSpouseColumnRefuses() {
        // A present column naming a third party is a contradiction, never a
        // downgrade to same-page-prior.
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "mary-2130a", record: marriage("mary-2130a", surname: "THOMPSON",
                                                                   givenName: "MARY ELLEN", year: 1915,
                                                                   quarter: "Dec", spouseName: "Smith"))],
            partnerMarriages: [williamRecord()],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .none = outcome else {
            Issue.record("expected .none, got \(outcome)")
            return
        }
    }

    @Test func contradictingSamePageInferredPartnerRefuses() {
        var record = marriage("mary-2130a", surname: "THOMPSON", givenName: "MARY ELLEN",
                              year: 1915, quarter: "Dec", spouseName: nil)
        record = MarriageRecord(
            common: record.common, marriageYear: record.marriageYear,
            marriageDate: nil, marriagePlace: nil,
            quarter: record.quarter, district: record.district,
            volume: record.volume, page: record.page,
            spouseName: nil, partnerSurnameFromSamePage: "SMITH"
        )
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "mary-2130a", record: record)],
            partnerMarriages: [williamRecord()],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .none = outcome else {
            Issue.record("expected .none, got \(outcome)")
            return
        }
    }

    // MARK: - Criterion 5: page-mates naming third parties

    @Test func pageMatesEachNamingThirdPartiesRefuse() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "s", record: marriage("s", surname: "THOMPSON", givenName: "MARY",
                                                          year: 1915, quarter: "Dec", spouseName: "Baker"))],
            partnerMarriages: [(id: "p", record: marriage("p", surname: "HOLMES", givenName: "WILLIAM",
                                                          year: 1915, quarter: "Dec", spouseName: "Clark"))],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .none = outcome else {
            Issue.record("expected .none, got \(outcome)")
            return
        }
    }

    // MARK: - Criterion 6: two shared keys → ambiguous

    @Test func twoDistinctSharedKeysAreAmbiguous() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [
                maryRecord(),
                (id: "mary-other", record: marriage("mary-other", surname: "THOMPSON", givenName: "MARY ELLEN",
                                                    year: 1915, quarter: "Dec", volume: "7b", page: "999",
                                                    spouseName: "Holmes")),
            ],
            partnerMarriages: [
                williamRecord(),
                (id: "william-other", record: marriage("william-other", surname: "HOLMES", givenName: "WILLIAM",
                                                       year: 1915, quarter: "Dec", volume: "7b", page: "999",
                                                       spouseName: "Thompson")),
            ],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .ambiguous = outcome else {
            Issue.record("expected .ambiguous, got \(outcome)")
            return
        }
    }

    // MARK: - Criterion 7: collision triptych (corroborator side)

    @Test func identicalDuplicateEntriesCollapseAndMatch() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord(), williamRecord()],   // same row twice
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .found = outcome else {
            Issue.record("duplicate identical entries are the NORMAL case and must collapse, got \(outcome)")
            return
        }
    }

    @Test func sameLineUnderTwoTranscriptionRowIDsCollapsesAndMatches() {
        let variant = (id: "william-2130a-v2",
                       record: marriage("william-2130a-v2", surname: "HOLMES", givenName: "WILLIAM",
                                        year: 1915, quarter: "Dec", spouseName: "Thompson"))
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord(), variant],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .found = outcome else {
            Issue.record("two transcriptions of one index line must collapse, got \(outcome)")
            return
        }
    }

    @Test func conflictingIdentitiesAtOneKeyDropTheKey() {
        // A page-mate BAKER line inside William's own evidence at the same
        // key: which entry is William's? Drop the key (when in doubt, split).
        let pageMate = (id: "baker-2130a",
                        record: marriage("baker-2130a", surname: "BAKER", givenName: "ARTHUR",
                                         year: 1915, quarter: "Dec", spouseName: nil))
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord(), pageMate],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .none = outcome else {
            Issue.record("expected .none after key drop, got \(outcome)")
            return
        }
    }

    @Test func twoSistersLinesOnSubjectSideDropTheKey() {
        let sister = (id: "sarah-2130a",
                      record: marriage("sarah-2130a", surname: "THOMPSON", givenName: "SARAH",
                                       year: 1915, quarter: "Dec", spouseName: "Clark"))
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord(), sister],
            partnerMarriages: [williamRecord()],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .none = outcome else {
            Issue.record("expected .none after same-side identity conflict, got \(outcome)")
            return
        }
    }

    // MARK: - Criterion 8: district drift and near-miss

    @Test func districtDriftJoinsViaCanonicalResolver() {
        let resolver: (String) -> String? = { raw in
            ["CHAPEL LE F.", "CHAPEL EN LE FRITH"].contains(raw) ? "Chapel en le Frith" : nil
        }
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "s", record: marriage("s", surname: "THOMPSON", givenName: "MARY",
                                                          year: 1915, quarter: "Dec",
                                                          district: "Chapel le F.", spouseName: "Holmes"))],
            partnerMarriages: [(id: "p", record: marriage("p", surname: "HOLMES", givenName: "WILLIAM",
                                                          year: 1915, quarter: "Dec",
                                                          district: "Chapel en le Frith", spouseName: "Thompson"))],
            subject: mary(), partner: william(),
            edgeID: "edge-1",
            districtResolver: resolver
        )
        guard case .found(let f) = outcome else {
            Issue.record("transcriber district variants must join via the canonical resolver, got \(outcome)")
            return
        }
        #expect(f.proposedLocation == "CHAPEL EN LE FRITH")
    }

    @Test func districtConflictIsNearMissNotJoin() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "s", record: marriage("s", surname: "THOMPSON", givenName: "MARY",
                                                          year: 1915, quarter: "Dec",
                                                          district: "Bakewell", spouseName: "Holmes"))],
            partnerMarriages: [(id: "p", record: marriage("p", surname: "HOLMES", givenName: "WILLIAM",
                                                          year: 1915, quarter: "Dec",
                                                          district: "Chesterfield", spouseName: "Thompson"))],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .none(let reason) = outcome else {
            Issue.record("expected .none near-miss, got \(outcome)")
            return
        }
        #expect(reason.hasPrefix("near-miss:"), "district drift must be observable, never auto-joined — got \(reason)")
    }

    @Test func leadingZerosAndCaseDoNotBreakTheJoin() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "s", record: marriage("s", surname: "THOMPSON", givenName: "MARY",
                                                          year: 1915, quarter: "DEC", volume: "7B",
                                                          page: "2130A", spouseName: "Holmes"))],
            partnerMarriages: [(id: "p", record: marriage("p", surname: "HOLMES", givenName: "WILLIAM",
                                                          year: 1915, quarter: " dec ", volume: " 7b",
                                                          page: "02130a", spouseName: "Thompson"))],
            subject: mary(), partner: william(),
            edgeID: "edge-1"
        )
        guard case .found = outcome else {
            Issue.record("case/whitespace/leading-zero variance must not break the join, got \(outcome)")
            return
        }
    }

    // MARK: - Criterion 9: married-surname-stored wife

    @Test func marriedSurnameStoredWifeJoinsViaSurnameSet() {
        // Mary stored under her married surname HOLMES; the caller-derived
        // maiden THOMPSON rides the surname set, so William's spouse column
        // "Thompson" still matches.
        let storedUnderMarried = SpousePairCorroborator.PairMember(
            profileID: "@MARY@", surnames: ["Holmes", "Thompson"]
        )
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: storedUnderMarried, partner: william(),
            edgeID: "edge-1"
        )
        guard case .found = outcome else {
            Issue.record("surname set must carry the derived maiden, got \(outcome)")
            return
        }

        // Without the derived maiden in the set, the reciprocal check
        // correctly refuses — the set is load-bearing.
        let withoutMaiden = SpousePairCorroborator.PairMember(
            profileID: "@MARY@", surnames: ["Holmes"]
        )
        let refused = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: withoutMaiden, partner: william(),
            edgeID: "edge-1"
        )
        guard case .none = refused else {
            Issue.record("expected refusal without the maiden surname, got \(refused)")
            return
        }
    }

    // MARK: - Criterion 10: year-sanity guards

    @Test func marriageAfterAPartysDeathRefuses() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [(id: "s", record: marriage("s", surname: "THOMPSON", givenName: "MARY",
                                                          year: 1925, quarter: "Dec", spouseName: "Holmes"))],
            partnerMarriages: [(id: "p", record: marriage("p", surname: "HOLMES", givenName: "WILLIAM",
                                                          year: 1925, quarter: "Dec", spouseName: "Thompson"))],
            subject: mary(), partner: william(),   // William d.1919
            edgeID: "edge-1"
        )
        guard case .none = outcome else {
            Issue.record("marriage after a party's death must refuse, got \(outcome)")
            return
        }
    }

    @Test func marriageBeforeMinimumAgeRefuses() {
        let bornTooLate = SpousePairCorroborator.PairMember(
            profileID: "@MARY@", surnames: ["Thompson", "Holmes"],
            recordedBirthYearRange: 1905...1905
        )
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: bornTooLate, partner: william(),
            edgeID: "edge-1"
        )
        guard case .none = outcome else {
            Issue.record("a ten-year-old cannot marry — must refuse, got \(outcome)")
            return
        }
    }

    @Test func legalVictorianMarriageAtFifteenIsNotRefused() {
        // Pre-1929 minimum was 14 — a refusal guard must not manufacture
        // false negatives on legal marriages (spec Decision 12).
        let bornNineteenHundred = SpousePairCorroborator.PairMember(
            profileID: "@MARY@", surnames: ["Thompson", "Holmes"],
            recordedBirthYearRange: 1900...1900
        )
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: bornNineteenHundred, partner: william(),
            edgeID: "edge-1"
        )
        guard case .found(let f) = outcome else {
            Issue.record("an age-15 marriage is legal pre-1929 and must not refuse, got \(outcome)")
            return
        }
        #expect(f.anchor == .strong("birth-window(@MARY@)"))
    }

    @Test func marriageBeyondPlausibleAdultSpanRefuses() {
        let bornLongBefore = SpousePairCorroborator.PairMember(
            profileID: "@MARY@", surnames: ["Thompson", "Holmes"],
            recordedBirthYearRange: 1800...1800
        )
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: bornLongBefore, partner: william(),
            edgeID: "edge-1"
        )
        guard case .none = outcome else {
            Issue.record("marriage at 115 must refuse, got \(outcome)")
            return
        }
    }

    // MARK: - Exclusions (rejection memory + CL6 parity as data)

    @Test func excludedPartnerRecordPreventsTheJoin() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: mary(), partner: william(),
            edgeID: "edge-1",
            exclusions: .init(excludedSubjectRecordIDs: [],
                              excludedPartnerRecordIDs: ["william-2130a"],
                              hasOpenDispute: false)
        )
        guard case .none = outcome else {
            Issue.record("a discarded/dismissed partner record must not corroborate, got \(outcome)")
            return
        }
    }

    @Test func openDisputeRefusesOutright() {
        let outcome = SpousePairCorroborator.corroborate(
            subjectMarriages: [maryRecord()],
            partnerMarriages: [williamRecord()],
            subject: mary(), partner: william(),
            edgeID: "edge-1",
            exclusions: .init(excludedSubjectRecordIDs: [], excludedPartnerRecordIDs: [],
                              hasOpenDispute: true)
        )
        guard case .none = outcome else {
            Issue.record("detection never argues with an open dispute, got \(outcome)")
            return
        }
    }

    // MARK: - Fixtures

    private typealias Anchor = SpousePairCorroborator.Anchor

    private func mary(deathYear: Int? = nil) -> SpousePairCorroborator.PairMember {
        SpousePairCorroborator.PairMember(
            profileID: "@MARY@",
            surnames: ["Thompson", "Holmes"],
            recordedBirthYearRange: nil,
            deathYear: deathYear
        )
    }

    private func william(deathYear: Int? = 1919) -> SpousePairCorroborator.PairMember {
        SpousePairCorroborator.PairMember(
            profileID: "@WILLIAM@",
            surnames: ["Holmes"],
            recordedBirthYearRange: nil,
            deathYear: deathYear
        )
    }

    private func maryRecord() -> (id: String, record: MarriageRecord) {
        (id: "mary-2130a",
         record: marriage("mary-2130a", surname: "THOMPSON", givenName: "MARY ELLEN",
                          year: 1915, quarter: "Dec", spouseName: "Holmes"))
    }

    private func williamRecord() -> (id: String, record: MarriageRecord) {
        (id: "william-2130a",
         record: marriage("william-2130a", surname: "HOLMES", givenName: "WILLIAM",
                          year: 1915, quarter: "Dec", spouseName: "Thompson"))
    }

    private func marriage(
        _ id: String, surname: String, givenName: String,
        year: Int, quarter: String?, district: String? = "Bakewell",
        volume: String? = "7b", page: String? = "2130a",
        spouseName: String?
    ) -> MarriageRecord {
        MarriageRecord(
            common: RecordCommon(
                id: id, sourceID: "freebmd",
                name: nil, surname: surname, givenName: givenName,
                detailURL: nil, rawFields: [:]
            ),
            marriageYear: year, marriageDate: nil, marriagePlace: nil,
            quarter: quarter, district: district, volume: volume, page: page,
            spouseName: spouseName
        )
    }
}
