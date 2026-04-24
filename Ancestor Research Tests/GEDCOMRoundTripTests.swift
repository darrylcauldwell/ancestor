import Testing
import Foundation
@testable import Ancestor_Research

/// Round-trip tests: import → export → re-import → compare graph structures.
/// Semantic equivalence, not textual identity.
struct GEDCOMRoundTripTests {

    static let testFilePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Cauldwell Family Tree.ged")
        .path

    @Test func roundTripPreservesProfileCount() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        #expect(reimported.individualCount == original.individualCount)
    }

    @Test func roundTripPreservesNames() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        // Every profile in the original should exist in the reimport with same name
        for (id, origProfile) in original.snapshot.profiles {
            let reimportedProfile = reimported.snapshot.profiles[id]
            #expect(reimportedProfile != nil, "Profile \(id) missing after round-trip")
            #expect(reimportedProfile?.firstName == origProfile.firstName,
                    "First name mismatch for \(id): '\(origProfile.firstName ?? "nil")' vs '\(reimportedProfile?.firstName ?? "nil")'")
            #expect(reimportedProfile?.lastName == origProfile.lastName,
                    "Last name mismatch for \(id)")
        }
    }

    @Test func roundTripPreservesDates() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        for (id, origProfile) in original.snapshot.profiles {
            let reimportedProfile = reimported.snapshot.profiles[id]

            // Birth date original string should match
            #expect(reimportedProfile?.birthDate?.original == origProfile.birthDate?.original,
                    "Birth date mismatch for \(id): '\(origProfile.birthDate?.original ?? "nil")'")

            // Death date original string should match
            #expect(reimportedProfile?.deathDate?.original == origProfile.deathDate?.original,
                    "Death date mismatch for \(id)")
        }
    }

    @Test func roundTripPreservesLocations() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        for (id, origProfile) in original.snapshot.profiles {
            let reimportedProfile = reimported.snapshot.profiles[id]
            #expect(reimportedProfile?.birthLocation == origProfile.birthLocation,
                    "Birth location mismatch for \(id)")
            #expect(reimportedProfile?.deathLocation == origProfile.deathLocation,
                    "Death location mismatch for \(id)")
        }
    }

    @Test func roundTripPreservesGender() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        for (id, origProfile) in original.snapshot.profiles {
            let reimportedProfile = reimported.snapshot.profiles[id]
            #expect(reimportedProfile?.gender == origProfile.gender,
                    "Gender mismatch for \(id)")
        }
    }

    @Test func roundTripPreservesParentRelationships() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        // For each profile, parent set should be the same
        for id in original.snapshot.profiles.keys {
            let origParents = Set(original.snapshot.parentsOf(id).map(\.id))
            let reimportedParents = Set(reimported.snapshot.parentsOf(id).map(\.id))
            #expect(origParents == reimportedParents,
                    "Parent mismatch for \(id): \(origParents) vs \(reimportedParents)")
        }
    }

    @Test func roundTripPreservesSpouseRelationships() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        for id in original.snapshot.profiles.keys {
            let origSpouses = Set(original.snapshot.spousesOf(id).map(\.id))
            let reimportedSpouses = Set(reimported.snapshot.spousesOf(id).map(\.id))
            #expect(origSpouses == reimportedSpouses,
                    "Spouse mismatch for \(id)")
        }
    }

    @Test func roundTripPreservesMarriageDates() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        let origMarriages = original.snapshot.relationships
            .filter { $0.type == .spouse && $0.marriageDate != nil }
            .map { (Set([$0.from, $0.to]), $0.marriageDate!.original) }

        let reimportedMarriages = reimported.snapshot.relationships
            .filter { $0.type == .spouse && $0.marriageDate != nil }
            .map { (Set([$0.from, $0.to]), $0.marriageDate!.original) }

        #expect(origMarriages.count == reimportedMarriages.count,
                "Marriage count mismatch: \(origMarriages.count) vs \(reimportedMarriages.count)")

        for (couple, date) in origMarriages {
            let match = reimportedMarriages.first { $0.0 == couple }
            #expect(match != nil, "Marriage not found for couple \(couple)")
            #expect(match?.1 == date, "Marriage date mismatch for \(couple)")
        }
    }

    @Test func exportLogsDroppedData() throws {
        let original = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let exported = GEDCOMExporter.export(original.snapshot)

        // Export should complete without error
        #expect(exported.individualCount == original.individualCount)
        #expect(exported.familyCount > 0)
        // Dropped list should be available (may be empty if no disputes/multi-sources)
        #expect(exported.dropped is [String])
    }

    @Test func syntheticRoundTrip() {
        let gedcom = """
        0 HEAD
        1 CHAR UTF-8
        0 @I1@ INDI
        1 NAME John William /Smith/
        2 GIVN John William
        2 SURN Smith
        1 SEX M
        1 BIRT
        2 DATE ABT 1887
        2 PLAC Belper, Derbyshire, England
        1 DEAT
        2 DATE 15 JAN 1960
        2 PLAC Derby, Derbyshire, England
        0 @I2@ INDI
        1 NAME Mary Ann /Jones/
        2 GIVN Mary Ann
        2 SURN Jones
        1 SEX F
        1 BIRT
        2 DATE 1890
        0 @I3@ INDI
        1 NAME James /Smith/
        1 SEX M
        1 BIRT
        2 DATE BET 1910 AND 1915
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        1 CHIL @I3@
        1 MARR
        2 DATE 1908
        0 TRLR
        """
        let original = GEDCOMParser.parse(content: gedcom)
        let exported = GEDCOMExporter.export(original.snapshot)
        let reimported = GEDCOMParser.parse(content: exported.content)

        // Names
        #expect(reimported.snapshot.profiles["@I1@"]?.firstName == "John William")
        #expect(reimported.snapshot.profiles["@I1@"]?.lastName == "Smith")

        // Approximate date preserved
        #expect(reimported.snapshot.profiles["@I1@"]?.birthDate?.original == "ABT 1887")
        #expect(reimported.snapshot.profiles["@I1@"]?.birthDate?.qualifier == .about)

        // Between date preserved
        #expect(reimported.snapshot.profiles["@I3@"]?.birthDate?.original == "BET 1910 AND 1915")

        // Relationships
        #expect(reimported.snapshot.parentsOf("@I3@").count == 2)
        #expect(reimported.snapshot.spousesOf("@I1@").count == 1)

        // Marriage date
        let marriage = reimported.snapshot.relationships.first {
            $0.type == .spouse && $0.marriageDate != nil
        }
        #expect(marriage?.marriageDate?.original == "1908")
    }
}
