import Testing
import Foundation
@testable import AncestorKit
@testable import Ancestor_Research

/// Unit tests for the E2 typed repeatable name forms
/// (MODEL_EVOLUTION_SPEC §Change2 / ADR-004 E2). Pure value-type logic — no
/// database (migration/persistence is pinned separately in
/// `MigrationV35NameFormsTests`).
///
/// The load-bearing property of E2 is *containment*: `nameForms` is an additive
/// sidecar and NOTHING downstream re-derives names. So the bulk of these tests
/// prove non-change — `displayName` is byte-identical, the flat search keys are
/// unchanged, and Hashable-on-id is unaffected — while a smaller set proves the
/// new capability (a twice-married woman is representable; WikiTree
/// `LastNameOther` survives).
nonisolated struct NameFormTests {

    // MARK: - displayName is byte-identical (AC 3)

    /// A battery of fixtures covering the shapes the spec calls out
    /// (birth-name-only, married woman, nickname, missing parts). For each we
    /// assert `displayName` equals the exact string the pre-E2 implementation
    /// produced — `[firstName, middleName, lastName]` joined by spaces — and
    /// that adding name forms does not perturb it.
    @Test func displayNameByteIdenticalAcrossFixtureBattery() {
        struct Fixture {
            let first: String?; let middle: String?; let last: String?
            let expected: String
        }
        let fixtures: [Fixture] = [
            .init(first: "John", middle: "Robert", last: "Smith", expected: "John Robert Smith"),
            .init(first: "John", middle: nil, last: "Smith", expected: "John Smith"),
            // Legacy shape: full given string in firstName, middleName nil.
            .init(first: "John Robert", middle: nil, last: "Smith", expected: "John Robert Smith"),
            .init(first: "Jane", middle: nil, last: "Doe", expected: "Jane Doe"),
            .init(first: nil, middle: nil, last: "Smith", expected: "Smith"),
            .init(first: "Mary", middle: nil, last: nil, expected: "Mary"),
            .init(first: nil, middle: nil, last: nil, expected: ""),
            .init(first: "Anne", middle: "Elizabeth", last: nil, expected: "Anne Elizabeth"),
        ]
        for f in fixtures {
            // Without name forms.
            let bare = Profile(
                id: "p", firstName: f.first, middleName: f.middle, lastName: f.last,
                isDeleted: false, sources: [:], disputes: [:])
            #expect(bare.displayName == f.expected)

            // With a rich set of name forms attached — displayName must not move.
            let withForms = Profile(
                id: "p", firstName: f.first, middleName: f.middle, lastName: f.last,
                marriedSurname: "Jones", nickName: "Nick",
                nameForms: [
                    NameForm(type: .birth, fullText: f.expected, given: f.first, surname: f.last),
                    NameForm(type: .married, fullText: "Married Name", surname: "Jones"),
                    NameForm(type: .alsoKnownAs, fullText: "AKA", surname: "Aka"),
                ],
                isDeleted: false, sources: [:], disputes: [:])
            #expect(withForms.displayName == f.expected)
            // displayName reads only the flat given/surname fields.
            #expect(withForms.displayName == bare.displayName)
        }
    }

    /// displayName is computed only from firstName/middleName/lastName — a
    /// married surname, nickname, or mother's maiden name never leaks into it,
    /// with or without corresponding name forms.
    @Test func displayNameIgnoresNonDisplayNameFieldsAndForms() {
        let p = Profile(
            id: "p", firstName: "Alice", lastName: "Baker",
            marriedSurname: "Carpenter", nickName: "Ally", mothersMaidenName: "Draper",
            nameForms: [NameForm(type: .married, fullText: "Alice Carpenter", surname: "Carpenter")],
            isDeleted: false, sources: [:], disputes: [:])
        #expect(p.displayName == "Alice Baker")
    }

    // MARK: - Flat search keys unchanged (search-axis equivalence)

    /// The flat fields the scorer/dispatch read (lastName=maiden, marriedSurname,
    /// nickName, mothersMaidenName) return exactly the stored value regardless of
    /// what name forms are present — proving the search axes resolve identically.
    @Test func flatSearchKeysUnaffectedByNameForms() {
        let p = Profile(
            id: "p", firstName: "Grace", lastName: "Land",
            marriedSurname: "Brooks", nickName: "Gracie", mothersMaidenName: "Wain",
            nameForms: [
                NameForm(type: .birth, fullText: "Grace Land", surname: "Land"),
                NameForm(type: .married, fullText: "Grace Brooks", surname: "Brooks"),
                NameForm(type: .married, fullText: "Grace Taylor", surname: "Taylor"),
                NameForm(type: .alsoKnownAs, fullText: "Amazing Grace", surname: "Grace"),
            ],
            isDeleted: false, sources: [:], disputes: [:])
        // Maiden axis.
        #expect(p.lastName == "Land")
        // Married axis — the flat field keeps the single search-key winner even
        // though two married forms exist.
        #expect(p.marriedSurname == "Brooks")
        // Nickname axis.
        #expect(p.nickName == "Gracie")
        // Mother's-maiden axis.
        #expect(p.mothersMaidenName == "Wain")
    }

    // MARK: - Twice-married woman is representable (AC 1)

    @Test func twiceMarriedWomanCarriesTwoMarriedFormsAndFlatWinner() {
        let p = Profile(
            id: "p", firstName: "Eleanor", lastName: "Vaughan",
            // Flat married surname holds the search-key "winner" (latest / chosen).
            marriedSurname: "Whitfield",
            nameForms: [
                NameForm(type: .birth, fullText: "Eleanor Vaughan", surname: "Vaughan"),
                NameForm(type: .married, fullText: "Eleanor Ashby", surname: "Ashby"),
                NameForm(type: .married, fullText: "Eleanor Whitfield", surname: "Whitfield"),
            ],
            isDeleted: false, sources: [:], disputes: [:])

        // Two married forms present.
        let married = p.nameForms.filter { $0.type == .married }
        #expect(married.count == 2)
        #expect(p.nameForms.marriedSurnames.sorted() == ["Ashby", "Whitfield"])
        // The married-surname search axis still resolves to the flat winner.
        #expect(p.marriedSurname == "Whitfield")
        // displayName is unaffected — still maiden convention.
        #expect(p.displayName == "Eleanor Vaughan")
    }

    // MARK: - Hashable-on-id pin (blast-radius contract)

    @Test func profilesDifferingOnlyInNameFormsRemainEqualAndHashEqual() {
        let a = Profile(id: "same", firstName: "Tom", lastName: "Hardy",
                        isDeleted: false, sources: [:], disputes: [:])
        let b = Profile(id: "same", firstName: "Tom", lastName: "Hardy",
                        nameForms: [NameForm(type: .alsoKnownAs, fullText: "Thomas", surname: "Hardy")],
                        isDeleted: false, sources: [:], disputes: [:])
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        var set: Set<Profile> = [a]
        #expect(set.insert(b).inserted == false)
    }

    // MARK: - Codable round-trips (back-compat, AC 3 baseline)

    @Test func nameFormCodableRoundTrips() throws {
        let original = NameForm(
            type: .married, fullText: "Ada King", lang: "en",
            given: "Ada", surname: "King", prefix: "Countess", suffix: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NameForm.self, from: data)
        #expect(decoded == original)
    }

    /// A Profile blob authored *before* E2 has no `nameForms` key. It must decode
    /// to an empty list and produce byte-identical projections (displayName,
    /// flat fields) as a same-data profile constructed with `nameForms: []`.
    @Test func profileDecodesLegacyBlobWithoutNameFormsKey() throws {
        let legacyBlob = """
        {"id":"p1","firstName":"John","lastName":"Smith","isDeleted":false,"externalIdentifiers":[]}
        """
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(legacyBlob.utf8))
        #expect(decoded.nameForms.isEmpty)
        #expect(decoded.displayName == "John Smith")
        #expect(decoded.lastName == "Smith")
    }

    @Test func profileEncodeThenDecodeRoundTripsNameForms() throws {
        let profile = Profile(
            id: "p1", firstName: "Grace", lastName: "Land", marriedSurname: "Brooks",
            nameForms: [
                NameForm(type: .birth, fullText: "Grace Land", given: "Grace", surname: "Land"),
                NameForm(type: .married, fullText: "Grace Brooks", given: "Grace", surname: "Brooks"),
            ],
            isDeleted: false, sources: [:], disputes: [:])
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded.nameForms.count == 2)
        #expect(decoded.nameForms == profile.nameForms)
        // Projections unchanged after a round-trip.
        #expect(decoded.displayName == profile.displayName)
        #expect(decoded.marriedSurname == "Brooks")
    }

    // MARK: - Backfill rule (shared by migration v35)

    /// The deterministic flat-fields → forms backfill used by migration v35.
    /// A legacy profile with only flat fields must produce a `.birth` form and,
    /// when a distinct married surname exists, a `.married` form — capturing the
    /// variants without changing what the flat fields resolve to.
    @Test func backfillFromFlatFieldsProducesBirthAndMarriedForms() {
        let forms = ProjectDatabase.backfilledNameForms(
            firstName: "Grace", middleName: nil, lastName: "Land",
            marriedSurname: "Brooks", nickName: "Gracie")
        #expect(forms.count == 2)
        let birth = forms.first { $0.type == .birth }
        #expect(birth?.surname == "Land")
        #expect(birth?.fullText == "Grace Land")
        let married = forms.first { $0.type == .married }
        #expect(married?.surname == "Brooks")
        #expect(married?.fullText == "Grace Brooks")
    }

    @Test func backfillWithNoMarriedSurnameProducesBirthFormOnly() {
        let forms = ProjectDatabase.backfilledNameForms(
            firstName: "John", middleName: "Robert", lastName: "Smith",
            marriedSurname: nil, nickName: nil)
        #expect(forms.count == 1)
        #expect(forms.first?.type == .birth)
        #expect(forms.first?.given == "John Robert")
        #expect(forms.first?.surname == "Smith")
    }

    @Test func backfillWithMarriedEqualToBirthSurnameSkipsMarriedForm() {
        // Same surname carries no marriage information — no redundant form.
        let forms = ProjectDatabase.backfilledNameForms(
            firstName: "Sam", middleName: nil, lastName: "Cauldwell",
            marriedSurname: "cauldwell", nickName: nil)
        #expect(forms.count == 1)
        #expect(forms.first?.type == .birth)
    }

    @Test func backfillWithNoNamePartsProducesEmptyList() {
        let forms = ProjectDatabase.backfilledNameForms(
            firstName: nil, middleName: nil, lastName: nil,
            marriedSurname: nil, nickName: nil)
        #expect(forms.isEmpty)
    }

    // MARK: - ProfileField.nameForms provenance case (AC 5)

    @Test func profileFieldNameFormsCaseExistsAndIsCodable() {
        #expect(ProfileField(rawValue: "nameForms") == .nameForms)
        #expect(ProfileField.nameForms.rawValue == "nameForms")
        // It is a member of allCases (so provenance tooling that iterates fields
        // sees it) but is not a scalar-string projection.
        #expect(ProfileField.allCases.contains(.nameForms))
    }
}
