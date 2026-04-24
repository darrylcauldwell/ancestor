import Testing
import Foundation
@testable import Ancestor_Research

struct GEDCOMParserTests {

    // Path to the real GEDCOM file — adjust if moved
    static let testFilePath: String = {
        // #filePath is the full path to this .swift file.
        // Walk up from the file to the test directory, then up to the repo root.
        let thisFile = URL(fileURLWithPath: #filePath)       // .../Ancestor Research Tests/GEDCOMParserTests.swift
        let testDir = thisFile.deletingLastPathComponent()   // .../Ancestor Research Tests/
        let repoRoot = testDir.deletingLastPathComponent()   // .../ancestor/
        return repoRoot.appendingPathComponent("Cauldwell Family Tree.ged").path
    }()

    @Test func parsesRealGEDCOM() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        #expect(result.individualCount == 216)
        #expect(result.familyCount == 81)
        #expect(result.snapshot.profiles.count == 216)
        #expect(!result.snapshot.relationships.isEmpty)
    }

    @Test func parsesDarrylCauldwell() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let darryl = result.snapshot.profiles.values.first {
            $0.firstName == "Darryl James" && $0.lastName == "Cauldwell"
        }
        #expect(darryl != nil)
        #expect(darryl?.gender == .male)
        #expect(darryl?.birthDate?.earliest == 1976)
        #expect(darryl?.birthDate?.latest == 1976)
        #expect(darryl?.birthDate?.qualifier == .exact)
        #expect(darryl?.birthLocation == "Wirksworth, Derbyshire, England")
        #expect(darryl?.externalIDs["gedcom"] == "@I_1564859388@")
    }

    @Test func parsesErnestWithDeathDate() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let ernest = result.snapshot.profiles.values.first {
            $0.firstName == "Ernest Victor" && $0.lastName == "Cauldwell"
        }
        #expect(ernest != nil)
        #expect(ernest?.birthDate?.earliest == 1919)
        #expect(ernest?.deathDate?.earliest == 2017)
        #expect(ernest?.deathLocation == "Chesterfield, Derbyshire, England")
    }

    @Test func parsesParentRelationships() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        // Darryl's parents should be David Cauldwell and Jennifer Holmes
        guard let darryl = result.snapshot.profiles.values.first(where: {
            $0.firstName == "Darryl James" && $0.lastName == "Cauldwell"
        }) else {
            Issue.record("Darryl not found")
            return
        }
        let parents = result.snapshot.parentsOf(darryl.id)
        #expect(parents.count == 2)
        let parentNames = Set(parents.map(\.displayName))
        #expect(parentNames.contains("David Cauldwell"))
        #expect(parentNames.contains("Jennifer Holmes"))
    }

    @Test func parsesSpouseRelationship() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        guard let darryl = result.snapshot.profiles.values.first(where: {
            $0.firstName == "Darryl James" && $0.lastName == "Cauldwell"
        }) else {
            Issue.record("Darryl not found")
            return
        }
        let spouses = result.snapshot.spousesOf(darryl.id)
        #expect(spouses.count == 1)
        #expect(spouses.first?.lastName == "Rose")
    }

    @Test func parsesMarriageDate() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        // FAM @F5@ has MARR DATE 1921
        let marriageRels = result.snapshot.relationships.filter {
            $0.type == .spouse && $0.marriageDate != nil
        }
        #expect(!marriageRels.isEmpty)
        let f5marriage = marriageRels.first { $0.marriageDate?.earliest == 1921 }
        #expect(f5marriage != nil)
    }

    @Test func parentRolesAssigned() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        let parentRels = result.snapshot.relationships.filter { $0.type == .parent }
        let fatherCount = parentRels.filter { $0.role == .father }.count
        let motherCount = parentRels.filter { $0.role == .mother }.count
        // Should have roughly equal fathers and mothers
        #expect(fatherCount > 0)
        #expect(motherCount > 0)
    }

    @Test func sourceProvenanceTracked() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        guard let darryl = result.snapshot.profiles.values.first(where: {
            $0.firstName == "Darryl James" && $0.lastName == "Cauldwell"
        }) else {
            Issue.record("Darryl not found")
            return
        }
        // Birth date should have a GEDCOM source
        let birthSources = darryl.sources[.birthDate] ?? []
        #expect(birthSources.count == 1)
        #expect(birthSources.first?.origin == .gedcom)
        #expect(birthSources.first?.raw == "5 Mar 1976")
    }

    @Test func siblingsDerivedFromSharedParents() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        // Find a family with multiple children and verify siblings work
        guard let darryl = result.snapshot.profiles.values.first(where: {
            $0.firstName == "Darryl James" && $0.lastName == "Cauldwell"
        }) else {
            Issue.record("Darryl not found")
            return
        }
        let siblings = result.snapshot.siblingsOf(darryl.id)
        // Darryl has at least one sibling (Helen Clare Cauldwell)
        let siblingNames = siblings.map(\.displayName)
        #expect(siblingNames.contains("Helen Clare Cauldwell"))
    }

    @Test func completenessComputed() throws {
        let result = try GEDCOMParser.parse(fileAt: Self.testFilePath)
        guard let darryl = result.snapshot.profiles.values.first(where: {
            $0.firstName == "Darryl James" && $0.lastName == "Cauldwell"
        }) else {
            Issue.record("Darryl not found")
            return
        }
        let comp = result.snapshot.completeness(for: darryl.id)
        // Darryl has: firstName, birthDate, birthLocation, parents — at least 4
        // Potentially living (born 1976) so max is 6
        #expect(comp.potentiallyLiving == true)
        #expect(comp.maximum == 6)
        #expect(comp.score >= 4)
    }
}

// MARK: - Synthetic GEDCOM Tests

struct GEDCOMParserSyntheticTests {

    @Test func parsesMinimalINDI() {
        let gedcom = """
        0 HEAD
        1 CHAR UTF-8
        0 @I1@ INDI
        1 NAME John /Smith/
        1 SEX M
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        #expect(result.individualCount == 1)
        let profile = result.snapshot.profiles["@I1@"]
        #expect(profile?.firstName == "John")
        #expect(profile?.lastName == "Smith")
        #expect(profile?.gender == .male)
    }

    @Test func parsesApproximateDate() {
        let gedcom = """
        0 HEAD
        1 CHAR UTF-8
        0 @I1@ INDI
        1 NAME Mary /Jones/
        1 BIRT
        2 DATE ABT 1887
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        let profile = result.snapshot.profiles["@I1@"]
        #expect(profile?.birthDate?.qualifier == .about)
        #expect(profile?.birthDate?.earliest == 1882)
        #expect(profile?.birthDate?.latest == 1892)
    }

    @Test func parsesGIVNandSURNoverrideName() {
        let gedcom = """
        0 HEAD
        1 CHAR UTF-8
        0 @I1@ INDI
        1 NAME J /Smith/
        2 GIVN John William
        2 SURN Smith
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        let profile = result.snapshot.profiles["@I1@"]
        #expect(profile?.firstName == "John William")
        #expect(profile?.lastName == "Smith")
    }

    @Test func parsesFamilyRelationships() {
        let gedcom = """
        0 HEAD
        1 CHAR UTF-8
        0 @I1@ INDI
        1 NAME John /Smith/
        1 SEX M
        0 @I2@ INDI
        1 NAME Mary /Jones/
        1 SEX F
        0 @I3@ INDI
        1 NAME James /Smith/
        1 SEX M
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        1 CHIL @I3@
        1 MARR
        2 DATE 15 JUN 1880
        2 PLAC Derby, Derbyshire
        0 TRLR
        """
        let result = GEDCOMParser.parse(content: gedcom)
        #expect(result.snapshot.profiles.count == 3)

        // Parent relationships
        let parents = result.snapshot.parentsOf("@I3@")
        #expect(parents.count == 2)

        // Spouse relationship
        let spouses = result.snapshot.spousesOf("@I1@")
        #expect(spouses.count == 1)
        #expect(spouses.first?.lastName == "Jones")

        // Marriage date
        let spouseRel = result.snapshot.relationships.first { $0.type == .spouse }
        #expect(spouseRel?.marriageDate?.earliest == 1880)

        // Parent roles
        let fatherRel = result.snapshot.relationships.first {
            $0.type == .parent && $0.from == "@I1@" && $0.to == "@I3@"
        }
        #expect(fatherRel?.role == .father)

        let motherRel = result.snapshot.relationships.first {
            $0.type == .parent && $0.from == "@I2@" && $0.to == "@I3@"
        }
        #expect(motherRel?.role == .mother)
    }
}
