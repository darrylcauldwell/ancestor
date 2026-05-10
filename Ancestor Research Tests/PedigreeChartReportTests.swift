import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the pedigree chart report (DESIGN.md §7.9.2).
///
/// `PedigreeChartReport.renderPDF` runs through `PDFRenderer`, which uses
/// `ImageRenderer` and therefore needs MainActor. We mark the whole suite
/// `@MainActor` so each test can call into it directly.
@MainActor
struct PedigreeChartReportTests {

    // MARK: - Test fixtures

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        birthYear: Int? = nil,
        deathYear: Int? = nil,
        location: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: location,
            deathDate: deathYear.map { GenealogicalDate(parsing: String($0)) },
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func parentRel(from: String, to: String, role: ParentRole) -> Relationship {
        Relationship(
            id: UUID(),
            from: from,
            to: to,
            type: .parent,
            role: role,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )
    }

    /// Build a fully populated 5-generation tree (31 unique profiles, all
    /// with father/mother edges). IDs: "g{N}p{R}" where N=generation,
    /// R=row 0..(2^N - 1). Subject is "g0p0".
    private func fullFiveGenSnapshot() -> FamilyGraphSnapshot {
        var profiles: [String: Profile] = [:]
        var rels: [Relationship] = []

        // 5 generations: 1 + 2 + 4 + 8 + 16 = 31 profiles.
        for gen in 0..<5 {
            let count = 1 << gen
            for row in 0..<count {
                let id = "g\(gen)p\(row)"
                profiles[id] = makeProfile(
                    id: id,
                    firstName: "Person\(gen)\(row)",
                    lastName: "Tree",
                    birthYear: 2000 - gen * 25,
                    deathYear: 2000 - gen * 25 + 60,
                    location: "Town\(gen)"
                )
            }
        }
        // Wire up parent edges: for each child in gen N row R,
        // father = gen N+1 row 2R, mother = gen N+1 row 2R+1.
        for gen in 0..<4 {
            let count = 1 << gen
            for row in 0..<count {
                let childID = "g\(gen)p\(row)"
                let fatherID = "g\(gen + 1)p\(row * 2)"
                let motherID = "g\(gen + 1)p\(row * 2 + 1)"
                rels.append(parentRel(from: fatherID, to: childID, role: .father))
                rels.append(parentRel(from: motherID, to: childID, role: .mother))
            }
        }
        return FamilyGraphSnapshot(profiles: profiles, relationships: rels)
    }

    // MARK: - Ancestor walk

    @Test func ancestorMatrixCountsPerGeneration() {
        let snapshot = fullFiveGenSnapshot()
        let matrix = PedigreeChartReport.buildAncestorMatrix(
            subjectID: "g0p0",
            generations: 5,
            snapshot: snapshot
        )
        #expect(matrix.count == 5)
        #expect(matrix[0].count == 1)
        #expect(matrix[1].count == 2)
        #expect(matrix[2].count == 4)
        #expect(matrix[3].count == 8)
        #expect(matrix[4].count == 16)
        // Every slot is filled in the full tree.
        #expect(matrix.flatMap { $0 }.allSatisfy { $0 != nil })
    }

    @Test func ancestorMatrixFourGen() {
        let snapshot = fullFiveGenSnapshot()
        let matrix = PedigreeChartReport.buildAncestorMatrix(
            subjectID: "g0p0",
            generations: 4,
            snapshot: snapshot
        )
        #expect(matrix.count == 4)
        #expect(matrix.map(\.count) == [1, 2, 4, 8])
    }

    @Test func ancestorMatrixMissingParentsAreNil() {
        // Subject with one parent only.
        let subject = makeProfile(id: "s", firstName: "Subject", birthYear: 1990)
        let father = makeProfile(id: "f", firstName: "Father", birthYear: 1965)
        let rel = parentRel(from: "f", to: "s", role: .father)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["s": subject, "f": father],
            relationships: [rel]
        )
        let matrix = PedigreeChartReport.buildAncestorMatrix(
            subjectID: "s",
            generations: 3,
            snapshot: snapshot
        )
        #expect(matrix[0] == ["s"])
        // Generation 1: father slot filled, mother nil.
        #expect(matrix[1][0] == "f")
        #expect(matrix[1][1] == nil)
        // Generation 2: father's parents both nil; mother branch all nil.
        #expect(matrix[2].allSatisfy { $0 == nil })
    }

    @Test func ancestorMatrixTruncatesExtraParents() {
        // A child with three parent edges — the third should be ignored.
        let subject = makeProfile(id: "s")
        let p1 = makeProfile(id: "p1")
        let p2 = makeProfile(id: "p2")
        let p3 = makeProfile(id: "p3")
        // Two un-roled parents fill the slots; the third is truncated.
        let rels = [
            parentRel(from: "p1", to: "s", role: .unspecified),
            parentRel(from: "p2", to: "s", role: .unspecified),
            parentRel(from: "p3", to: "s", role: .unspecified)
        ]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["s": subject, "p1": p1, "p2": p2, "p3": p3],
            relationships: rels
        )
        let matrix = PedigreeChartReport.buildAncestorMatrix(
            subjectID: "s",
            generations: 2,
            snapshot: snapshot
        )
        let ancestors = matrix[1].compactMap { $0 }
        #expect(ancestors.count == 2)
        // p3 must not appear.
        #expect(!ancestors.contains("p3"))
    }

    @Test func ancestorMatrixSubjectMissing() {
        // Even if the subject ID isn't in the snapshot, the matrix should
        // still have the correct shape — just empty slots beyond column 0.
        let snapshot = FamilyGraphSnapshot.empty
        let matrix = PedigreeChartReport.buildAncestorMatrix(
            subjectID: "ghost",
            generations: 4,
            snapshot: snapshot
        )
        #expect(matrix.count == 4)
        #expect(matrix[0] == ["ghost"])
        for col in 1..<4 {
            #expect(matrix[col].allSatisfy { $0 == nil })
        }
    }

    // MARK: - PDF rendering

    @Test func rendersFourGenerationPDF() {
        let snapshot = fullFiveGenSnapshot()
        let data = PedigreeChartReport.renderPDF(
            profileID: "g0p0",
            generations: .four,
            showCompleteness: true,
            paperSize: .a4,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
        // PDF magic header — sanity check that we got real PDF bytes.
        if let prefix = data?.prefix(4) {
            #expect(Array(prefix) == Array("%PDF".utf8))
        }
    }

    @Test func rendersFiveGenerationPDF() {
        let snapshot = fullFiveGenSnapshot()
        let data = PedigreeChartReport.renderPDF(
            profileID: "g0p0",
            generations: .five,
            showCompleteness: true,
            paperSize: .a3,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test func rendersSubjectWithNoAncestors() {
        // A subject whose snapshot contains nobody else. Renderer must not
        // crash and must still emit a valid PDF — every ancestor slot is a
        // dotted "?" placeholder.
        let subject = makeProfile(id: "lonely", firstName: "Lonely", birthYear: 1990)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["lonely": subject],
            relationships: []
        )
        let data = PedigreeChartReport.renderPDF(
            profileID: "lonely",
            generations: .four,
            showCompleteness: false,
            paperSize: .a4,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test func rendersWithoutCompletenessChip() {
        // Smoke test for the showCompleteness == false branch.
        let snapshot = fullFiveGenSnapshot()
        let data = PedigreeChartReport.renderPDF(
            profileID: "g0p0",
            generations: .four,
            showCompleteness: false,
            paperSize: .letter,
            snapshot: snapshot
        )
        #expect(data != nil)
    }
}
