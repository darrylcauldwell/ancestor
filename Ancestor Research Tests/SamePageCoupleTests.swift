import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `SamePageCouplePairing` (the pure pairing helper) and the
/// `RecordScorer` family-context gate's response to a recovered partner
/// surname. Anchored to the George H Brooks × Ida Louisa Land Dec 1911
/// Belper 7b/1397 case: pre-Sep-1912 FreeBMD marriage entries lack the
/// spouse-surname column, but both sides of the marriage are registered
/// on the same `(vol, page)` so a separately-fetched spouse-side query
/// reunites them.
struct SamePageCoupleTests {

    // MARK: - referenceKey

    @Test func referenceKeyIsEqualForTwoEntriesAtSameVolumeAndPage() {
        let brooks = marriage(surname: "BROOKS", givenName: "GEORGE H",
                              year: 1911, quarter: "Dec", district: "Belper",
                              volume: "7b", page: "1397", spouseName: nil)
        let land = marriage(surname: "LAND", givenName: "IDA LOUISA",
                            year: 1911, quarter: "Dec", district: "Belper",
                            volume: "7b", page: "1397", spouseName: nil)
        let keyBrooks = SamePageCouplePairing.referenceKey(brooks)
        let keyLand = SamePageCouplePairing.referenceKey(land)
        #expect(keyBrooks != nil)
        #expect(keyBrooks == keyLand,
                "Same (year, quarter, district, vol, page) must produce identical reference keys")
    }

    @Test func referenceKeyDiffersWhenPageDiffers() {
        let a = marriage(surname: "BROOKS", givenName: "GEORGE",
                         year: 1911, quarter: "Dec", district: "Belper",
                         volume: "7b", page: "1397", spouseName: nil)
        let b = marriage(surname: "LAND", givenName: "IDA",
                         year: 1911, quarter: "Dec", district: "Belper",
                         volume: "7b", page: "1398", spouseName: nil)
        #expect(SamePageCouplePairing.referenceKey(a) != SamePageCouplePairing.referenceKey(b))
    }

    @Test func referenceKeyReturnsNilWhenVolumeMissing() {
        let m = marriage(surname: "BROOKS", givenName: "GEORGE",
                         year: 1911, quarter: "Dec", district: "Belper",
                         volume: nil, page: "1397", spouseName: nil)
        #expect(SamePageCouplePairing.referenceKey(m) == nil)
    }

    @Test func referenceKeyReturnsNilWhenPageMissing() {
        let m = marriage(surname: "BROOKS", givenName: "GEORGE",
                         year: 1911, quarter: "Dec", district: "Belper",
                         volume: "7b", page: nil, spouseName: nil)
        #expect(SamePageCouplePairing.referenceKey(m) == nil)
    }

    @Test func referenceKeyNormalisesCaseAndWhitespace() {
        let upper = marriage(surname: "BROOKS", givenName: "GEORGE",
                             year: 1911, quarter: "Dec", district: "BELPER",
                             volume: "7B", page: "1397", spouseName: nil)
        let lower = marriage(surname: "Land", givenName: "Ida",
                             year: 1911, quarter: " dec ", district: " belper ",
                             volume: " 7b ", page: " 1397 ", spouseName: nil)
        #expect(SamePageCouplePairing.referenceKey(upper) == SamePageCouplePairing.referenceKey(lower),
                "Case + whitespace must not break pairing — the BMD reference is the same marriage")
    }

    // MARK: - annotate

    @Test func annotateAttachesPartnerSurnameOnPre1912MarriageWhenSpouseSideAtSamePage() {
        // Pre-Sep-1912 case: both sides have spouseName=nil (the BMD column
        // doesn't exist yet) but they share (vol, page). Pairing must
        // recover the partner surname.
        let brooks = marriage(surname: "BROOKS", givenName: "GEORGE H",
                              year: 1911, quarter: "Dec", district: "Belper",
                              volume: "7b", page: "1397", spouseName: nil)
        let land = marriageRaw(surname: "LAND", givenName: "IDA LOUISA",
                               year: 1911, quarter: "Dec", district: "Belper",
                               volume: "7b", page: "1397", spouseName: nil)
        let (annotated, count) = SamePageCouplePairing.annotate(
            subjectSideRecords: [.marriage(brooks)],
            spouseSideMarriages: [land]
        )
        #expect(count == 1)
        guard case .marriage(let result) = annotated.first else {
            Issue.record("expected a marriage record back")
            return
        }
        #expect(result.partnerSurnameFromSamePage == "LAND")
    }

    @Test func annotateDoesNotPairWhenPagesDiffer() {
        let brooks = marriage(surname: "BROOKS", givenName: "GEORGE",
                              year: 1911, quarter: "Dec", district: "Belper",
                              volume: "7b", page: "1397", spouseName: nil)
        let landDifferentPage = marriageRaw(surname: "LAND", givenName: "IDA",
                                            year: 1911, quarter: "Dec", district: "Belper",
                                            volume: "7b", page: "1398", spouseName: nil)
        let (annotated, count) = SamePageCouplePairing.annotate(
            subjectSideRecords: [.marriage(brooks)],
            spouseSideMarriages: [landDifferentPage]
        )
        #expect(count == 0)
        guard case .marriage(let result) = annotated.first else {
            Issue.record("expected a marriage record back")
            return
        }
        #expect(result.partnerSurnameFromSamePage == nil)
    }

    @Test func annotateSkipsRecordsAlreadyAnnotated() {
        let brooksAlready = MarriageRecord(
            common: commonFields("brooks-already", surname: "BROOKS", givenName: "GEORGE"),
            marriageYear: 1911, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "1397",
            spouseName: nil,
            partnerSurnameFromSamePage: "EXISTING"
        )
        let landCompeting = marriageRaw(surname: "OTHER", givenName: "X",
                                        year: 1911, quarter: "Dec", district: "Belper",
                                        volume: "7b", page: "1397", spouseName: nil)
        let (annotated, count) = SamePageCouplePairing.annotate(
            subjectSideRecords: [.marriage(brooksAlready)],
            spouseSideMarriages: [landCompeting]
        )
        #expect(count == 0)
        guard case .marriage(let result) = annotated.first else {
            Issue.record("expected a marriage record back")
            return
        }
        #expect(result.partnerSurnameFromSamePage == "EXISTING",
                "Existing annotation must not be overwritten by the pairing pass")
    }

    // MARK: - annotate collision handling (#CPC-Change1, spec Decision 13)

    @Test func annotateCollapsesIdenticalDuplicateSpouseSideEntries() {
        // The pipeline feeds annotate from two fetch paths with no
        // cross-path dedup — the same partner row arriving twice at one key
        // is the NORMAL case and must still annotate.
        let brooks = marriage(surname: "BROOKS", givenName: "GEORGE H",
                              year: 1911, quarter: "Dec", district: "Belper",
                              volume: "7b", page: "1397", spouseName: nil)
        let land = marriageRaw(surname: "LAND", givenName: "IDA LOUISA",
                               year: 1911, quarter: "Dec", district: "Belper",
                               volume: "7b", page: "1397", spouseName: nil)
        let (annotated, count) = SamePageCouplePairing.annotate(
            subjectSideRecords: [.marriage(brooks)],
            spouseSideMarriages: [land, land]
        )
        #expect(count == 1)
        guard case .marriage(let result) = annotated.first else {
            Issue.record("expected a marriage record back")
            return
        }
        #expect(result.partnerSurnameFromSamePage == "LAND")
    }

    @Test func annotateCollapsesTranscriptionVariantsOfOneLine() {
        // FreeBMD holds multiple volunteer transcriptions of one index line
        // under distinct row ids — same surname at one key must collapse,
        // not be mistaken for ambiguity.
        let brooks = marriage(surname: "BROOKS", givenName: "GEORGE H",
                              year: 1911, quarter: "Dec", district: "Belper",
                              volume: "7b", page: "1397", spouseName: nil)
        let landA = marriageRaw(surname: "LAND", givenName: "IDA LOUISA",
                                year: 1911, quarter: "Dec", district: "Belper",
                                volume: "7b", page: "1397", spouseName: nil)
        let landB = MarriageRecord(
            common: commonFields("land-transcription-2", surname: "LAND", givenName: "IDA L"),
            marriageYear: 1911, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "1397",
            spouseName: nil
        )
        let (annotated, count) = SamePageCouplePairing.annotate(
            subjectSideRecords: [.marriage(brooks)],
            spouseSideMarriages: [landA, landB]
        )
        #expect(count == 1)
        guard case .marriage(let result) = annotated.first else {
            Issue.record("expected a marriage record back")
            return
        }
        #expect(result.partnerSurnameFromSamePage == "LAND")
    }

    @Test func annotateDropsKeyOnConflictingPartnerSurnames() {
        // Two DIFFERENT surnames at one key — which entry is the partner?
        // The old dict build silently kept the last write; the key must now
        // drop entirely (when in doubt, split).
        let brooks = marriage(surname: "BROOKS", givenName: "GEORGE H",
                              year: 1911, quarter: "Dec", district: "Belper",
                              volume: "7b", page: "1397", spouseName: nil)
        let land = marriageRaw(surname: "LAND", givenName: "IDA",
                               year: 1911, quarter: "Dec", district: "Belper",
                               volume: "7b", page: "1397", spouseName: nil)
        let smith = marriageRaw(surname: "SMITH", givenName: "ANN",
                                year: 1911, quarter: "Dec", district: "Belper",
                                volume: "7b", page: "1397", spouseName: nil)
        let (annotated, count) = SamePageCouplePairing.annotate(
            subjectSideRecords: [.marriage(brooks)],
            spouseSideMarriages: [land, smith]
        )
        #expect(count == 0)
        guard case .marriage(let result) = annotated.first else {
            Issue.record("expected a marriage record back")
            return
        }
        #expect(result.partnerSurnameFromSamePage == nil,
                "conflicting partner surnames at one key must not annotate")
    }

    @Test func annotatePassesThroughNonMarriageRecords() {
        let nonMarriage = SourceRecord.birth(BirthRecord(
            common: commonFields("birth-1", surname: "BROOKS", givenName: "GEORGE"),
            birthYear: 1880, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "Belper", volume: "7b", page: "100",
            mothersMaidenName: nil
        ))
        let (annotated, count) = SamePageCouplePairing.annotate(
            subjectSideRecords: [nonMarriage],
            spouseSideMarriages: []
        )
        #expect(count == 0)
        #expect(annotated.count == 1)
        if case .birth = annotated[0] { /* ok */ } else {
            Issue.record("non-marriage record must pass through unchanged")
        }
    }

    // MARK: - RecordScorer family-context gate

    @Test func familyContextGatePassesWhenPartnerSurnameMatchesSpouseSurname() {
        // Pre-1912 marriage: spouseName=nil but pairing recovered "LAND".
        // Subject George Brooks's familyContext.spouseSurname == "Land".
        let brooks = MarriageRecord(
            common: commonFields("brooks-paired", surname: "BROOKS", givenName: "GEORGE H"),
            marriageYear: 1911, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "1397",
            spouseName: nil,
            partnerSurnameFromSamePage: "LAND"
        )
        let subject = subjectGeorgeBrooks(spouseSurname: "Land", spouseFatherSurname: nil)
        let result = RecordScorer.classify(record: .marriage(brooks), subject: subject, searchType: .marriage)
        let fcGate = result.gates.first { $0.gate == .familyContext }
        #expect(fcGate?.outcome == .pass,
                "Family-context gate must pass on a paired pre-1912 marriage when partner matches spouseSurname — got \(String(describing: fcGate?.outcome))")
    }

    @Test func familyContextGatePassesOnInvertedImportViaSpouseFatherSurname() {
        // Inverted-import case: subject's wife is recorded under her
        // married surname (familyContext.spouseSurname = "Cauldwell")
        // but her true maiden is "Ward" via her father. Recovered
        // partner "WARD" must still pass via the spouseFatherSurname axis.
        let cauldwell = MarriageRecord(
            common: commonFields("cauldwell-paired", surname: "CAULDWELL", givenName: "ERNEST"),
            marriageYear: 1910, marriageDate: nil, marriagePlace: nil,
            quarter: "Jun", district: "Belper", volume: "7b", page: "850",
            spouseName: nil,
            partnerSurnameFromSamePage: "WARD"
        )
        let subject = subjectGeorgeBrooks(
            surname: "Cauldwell",
            spouseSurname: "Cauldwell",       // inverted — wife stored under married name
            spouseFatherSurname: "Ward"       // true maiden recovered via wife's father
        )
        let result = RecordScorer.classify(record: .marriage(cauldwell), subject: subject, searchType: .marriage)
        let fcGate = result.gates.first { $0.gate == .familyContext }
        #expect(fcGate?.outcome == .pass)
    }

    @Test func familyContextGateDoesNotPassWhenPartnerSurnameDiffers() {
        let brooks = MarriageRecord(
            common: commonFields("brooks-wrong", surname: "BROOKS", givenName: "GEORGE"),
            marriageYear: 1911, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "1397",
            spouseName: nil,
            partnerSurnameFromSamePage: "SMITH"   // wrong partner
        )
        let subject = subjectGeorgeBrooks(spouseSurname: "Land", spouseFatherSurname: nil)
        let result = RecordScorer.classify(record: .marriage(brooks), subject: subject, searchType: .marriage)
        let fcGate = result.gates.first { $0.gate == .familyContext }
        // Not .pass — either .skip or .softFail; the gate just shouldn't
        // accept a wrong-partner pairing.
        #expect(fcGate?.outcome != .pass)
    }

    // MARK: - Fixtures

    private func marriage(
        surname: String, givenName: String,
        year: Int, quarter: String?, district: String?,
        volume: String?, page: String?, spouseName: String?
    ) -> MarriageRecord {
        MarriageRecord(
            common: commonFields("m-\(surname)-\(givenName)-\(volume ?? "x")-\(page ?? "x")",
                                 surname: surname, givenName: givenName),
            marriageYear: year, marriageDate: nil, marriagePlace: nil,
            quarter: quarter, district: district, volume: volume, page: page,
            spouseName: spouseName
        )
    }

    /// Returns the same shape as `marriage` but is named so the test reads
    /// "spouse-side raw record" rather than reusing the subject-side fixture.
    private func marriageRaw(
        surname: String, givenName: String,
        year: Int, quarter: String?, district: String?,
        volume: String?, page: String?, spouseName: String?
    ) -> MarriageRecord {
        marriage(surname: surname, givenName: givenName, year: year,
                 quarter: quarter, district: district, volume: volume, page: page,
                 spouseName: spouseName)
    }

    private func commonFields(_ id: String, surname: String, givenName: String) -> RecordCommon {
        RecordCommon(
            id: id, sourceID: "freebmd",
            name: nil, surname: surname, givenName: givenName,
            detailURL: nil, rawFields: [:]
        )
    }

    private func subjectGeorgeBrooks(
        surname: String = "Brooks",
        spouseSurname: String?,
        spouseFatherSurname: String?
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: "George",
            middleName: "H",
            birthYearFrom: 1885,
            birthYearTo: 1890,
            gender: .male,
            region: .englandAndWales,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: spouseSurname.map { "Ida \($0)" },
                spouseSurname: spouseSurname,
                spouseGivenName: "Ida",
                spouseFatherSurname: spouseFatherSurname,
                childNames: [],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil
            )
        )
    }
}
