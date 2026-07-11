import Testing
import Foundation
@testable import AncestorKit
@testable import Ancestor_Research

/// Pins the E2 WikiTree name-variant capture (MODEL_EVOLUTION_SPEC §Change2
/// AC 2): a WikiTree profile carrying `LastNameOther` / `LastNameCurrent`
/// ingests those as typed name forms — the motivating data-loss fix — while the
/// flat name fields (the search keys) are unchanged.
///
/// `WikiTreeClient.convertProfile` is a pure static over the raw
/// `[String: Any]` API payload, so these tests exercise the exact mapping the
/// live importer uses without any network.
nonisolated struct WikiTreeNameFormIngestTests {

    // MARK: - LastNameOther is captured (was silently dropped before E2)

    @Test func lastNameOtherIngestsAsAlsoKnownAsForm() throws {
        let data: [String: Any] = [
            "Name": "Smith-123",
            "FirstName": "John",
            "LastNameAtBirth": "Smith",
            "LastNameOther": "Smythe",
            "Gender": "Male",
        ]
        let profile = try #require(WikiTreeClient.convertProfile(data))
        // Flat fields unchanged — still the maiden/birth surname.
        #expect(profile.firstName == "John")
        #expect(profile.lastName == "Smith")
        // The variant is now present as an also-known-as form.
        #expect(profile.nameForms.contains { $0.type == .alsoKnownAs && $0.surname == "Smythe" })
    }

    // MARK: - LastNameCurrent → married form only when it differs

    @Test func lastNameCurrentDifferingFromBirthIngestsAsMarriedForm() throws {
        let data: [String: Any] = [
            "Name": "Land-9",
            "FirstName": "Grace",
            "LastNameAtBirth": "Land",
            "LastNameCurrent": "Brooks",
            "Gender": "Female",
        ]
        let profile = try #require(WikiTreeClient.convertProfile(data))
        #expect(profile.lastName == "Land")
        #expect(profile.nameForms.contains { $0.type == .married && $0.surname == "Brooks" })
        #expect(profile.nameForms.contains { $0.type == .birth && $0.surname == "Land" })
    }

    @Test func lastNameCurrentEqualToBirthDoesNotCreateMarriedForm() throws {
        let data: [String: Any] = [
            "Name": "Smith-1",
            "FirstName": "John",
            "LastNameAtBirth": "Smith",
            "LastNameCurrent": "Smith",
            "Gender": "Male",
        ]
        let profile = try #require(WikiTreeClient.convertProfile(data))
        #expect(profile.nameForms.contains { $0.type == .married } == false)
        // A birth form is still recorded.
        #expect(profile.nameForms.contains { $0.type == .birth && $0.surname == "Smith" })
    }

    // MARK: - No loss, all three variants together

    @Test func allNameVariantsIngestTogetherWithoutLoss() throws {
        let data: [String: Any] = [
            "Name": "Vaughan-2",
            "FirstName": "Eleanor",
            "MiddleName": "Mae",
            "LastNameAtBirth": "Vaughan",
            "LastNameCurrent": "Whitfield",
            "LastNameOther": "Ashby",
            "Gender": "Female",
        ]
        let profile = try #require(WikiTreeClient.convertProfile(data))
        // Flat search keys untouched (middleName still not flat-mapped, per the
        // pre-E2 importer's behaviour).
        #expect(profile.firstName == "Eleanor")
        #expect(profile.lastName == "Vaughan")
        #expect(profile.middleName == nil)
        // Three typed forms captured; the given parts feed each form.
        #expect(profile.nameForms.count == 3)
        let birth = profile.nameForms.first { $0.type == .birth }
        #expect(birth?.given == "Eleanor Mae")
        #expect(birth?.surname == "Vaughan")
        #expect(profile.nameForms.contains { $0.type == .married && $0.surname == "Whitfield" })
        #expect(profile.nameForms.contains { $0.type == .alsoKnownAs && $0.surname == "Ashby" })
    }

    // MARK: - A profile with no variants gets just a birth form

    @Test func profileWithoutVariantsGetsBirthFormOnly() throws {
        let data: [String: Any] = [
            "Name": "Doe-1",
            "FirstName": "Jane",
            "LastNameAtBirth": "Doe",
            "Gender": "Female",
        ]
        let profile = try #require(WikiTreeClient.convertProfile(data))
        #expect(profile.nameForms.count == 1)
        #expect(profile.nameForms.first?.type == .birth)
        #expect(profile.displayName == "Jane Doe")
    }
}
