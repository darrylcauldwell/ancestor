import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the hourglass pedigree chart variant (DESIGN.md §7.9.2).
///
/// `PedigreeChartReport.renderHourglassPDF` runs through `PDFRenderer`,
/// which uses `ImageRenderer` and therefore needs MainActor. We mark the
/// whole suite `@MainActor` so each test can call into it directly.
@MainActor
struct PedigreeHourglassChartTests {

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

    /// Build a fully populated 5-generation ancestor tree (31 unique profiles)
    /// PLUS a 4-generation descendant tree from the subject (subject's
    /// children + grandchildren + great-grandchildren). IDs:
    ///   - ancestors: "ag{N}p{R}" where N=generation upward, R=row 0..(2^N - 1)
    ///   - subject: "ag0p0"
    ///   - descendants: "dg{N}p{R}" where N=generation downward, R=row
    private func fullSnapshot(
        ancestorGens: Int = 5,
        descendantGens: Int = 4
    ) -> FamilyGraphSnapshot {
        var profiles: [String: Profile] = [:]
        var rels: [Relationship] = []

        // Ancestor side. ag0p0 is the subject.
        for gen in 0..<ancestorGens {
            let count = 1 << gen
            for row in 0..<count {
                let id = "ag\(gen)p\(row)"
                profiles[id] = makeProfile(
                    id: id,
                    firstName: "A\(gen)\(row)",
                    lastName: "Tree",
                    birthYear: 2000 - gen * 25,
                    deathYear: 2000 - gen * 25 + 60,
                    location: "Town\(gen)"
                )
            }
        }
        for gen in 0..<(ancestorGens - 1) {
            let count = 1 << gen
            for row in 0..<count {
                let childID = "ag\(gen)p\(row)"
                let fatherID = "ag\(gen + 1)p\(row * 2)"
                let motherID = "ag\(gen + 1)p\(row * 2 + 1)"
                rels.append(parentRel(from: fatherID, to: childID, role: .father))
                rels.append(parentRel(from: motherID, to: childID, role: .mother))
            }
        }

        // Descendant side: each profile has 2 children. dg1 = children of
        // subject, dg2 = grandchildren, dg3 = great-grandchildren.
        for gen in 1..<descendantGens {
            let count = 1 << gen
            for row in 0..<count {
                let id = "dg\(gen)p\(row)"
                profiles[id] = makeProfile(
                    id: id,
                    firstName: "D\(gen)\(row)",
                    lastName: "Tree",
                    birthYear: 2000 + gen * 25,
                    deathYear: nil
                )
            }
        }
        // Wire descendant edges. Generation 1 children come from the subject
        // (ag0p0). Generation N+1 children come from generation N.
        for gen in 0..<(descendantGens - 1) {
            let parentCount = 1 << gen
            for parentSlot in 0..<parentCount {
                let parentID = (gen == 0) ? "ag0p0" : "dg\(gen)p\(parentSlot)"
                let leftID = "dg\(gen + 1)p\(parentSlot * 2)"
                let rightID = "dg\(gen + 1)p\(parentSlot * 2 + 1)"
                rels.append(parentRel(from: parentID, to: leftID, role: .father))
                rels.append(parentRel(from: parentID, to: rightID, role: .father))
            }
        }

        return FamilyGraphSnapshot(profiles: profiles, relationships: rels)
    }

    // MARK: - Descendant matrix

    @Test func descendantMatrixCountsPerGeneration() {
        let snapshot = fullSnapshot(ancestorGens: 1, descendantGens: 4)
        let matrix = PedigreeChartReport.buildDescendantMatrix(
            subjectID: "ag0p0",
            generations: 4,
            maxFanout: 2,
            snapshot: snapshot
        )
        #expect(matrix.count == 4)
        #expect(matrix[0].count == 1)
        #expect(matrix[1].count == 2)
        #expect(matrix[2].count == 4)
        #expect(matrix[3].count == 8)
        #expect(matrix.flatMap { $0 }.allSatisfy { $0 != nil })
    }

    @Test func descendantMatrixSubjectWithoutChildren() {
        let lonely = makeProfile(id: "lonely", firstName: "Lonely", birthYear: 1990)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["lonely": lonely],
            relationships: []
        )
        let matrix = PedigreeChartReport.buildDescendantMatrix(
            subjectID: "lonely",
            generations: 4,
            maxFanout: 2,
            snapshot: snapshot
        )
        #expect(matrix.count == 4)
        #expect(matrix[0] == ["lonely"])
        // All descendant slots are nil.
        for gen in 1..<4 {
            #expect(matrix[gen].allSatisfy { $0 == nil })
        }
    }

    @Test func descendantMatrixDoesNotDuplicateChildren() {
        // A child recorded with two parent edges (father + mother) must not
        // appear twice in the descendant chart.
        let subject = makeProfile(id: "s")
        let coparent = makeProfile(id: "c")
        let kid = makeProfile(id: "k")
        let rels = [
            parentRel(from: "s", to: "k", role: .father),
            parentRel(from: "c", to: "k", role: .mother)
        ]
        let snapshot = FamilyGraphSnapshot(
            profiles: ["s": subject, "c": coparent, "k": kid],
            relationships: rels
        )
        let matrix = PedigreeChartReport.buildDescendantMatrix(
            subjectID: "s",
            generations: 2,
            maxFanout: 2,
            snapshot: snapshot
        )
        let kids = matrix[1].compactMap { $0 }
        #expect(kids == ["k"])
    }

    // MARK: - PDF rendering

    @Test func rendersFourGenerationHourglassPDF() {
        let snapshot = fullSnapshot(ancestorGens: 4, descendantGens: 4)
        let data = PedigreeChartReport.renderHourglassPDF(
            profileID: "ag0p0",
            generations: .four,
            showCompleteness: true,
            paperSize: .a4,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
        if let prefix = data?.prefix(4) {
            #expect(Array(prefix) == Array("%PDF".utf8))
        }
    }

    @Test func rendersFiveGenerationHourglassPDF() {
        let snapshot = fullSnapshot(ancestorGens: 5, descendantGens: 5)
        let data = PedigreeChartReport.renderHourglassPDF(
            profileID: "ag0p0",
            generations: .five,
            showCompleteness: true,
            paperSize: .a3,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test func rendersAncestorOnlyWhenNoDescendants() {
        // Subject has full ancestors but no children — the lower half should
        // be suppressed and the renderer should still emit a valid PDF.
        let snapshot = fullSnapshot(ancestorGens: 4, descendantGens: 1)
        let data = PedigreeChartReport.renderHourglassPDF(
            profileID: "ag0p0",
            generations: .four,
            showCompleteness: false,
            paperSize: .a4,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test func rendersDescendantOnlyWhenNoAncestors() {
        // Subject has children but no ancestors recorded. The upper half
        // is full of dotted "?" placeholders; the lower half draws as normal.
        let snapshot = fullSnapshot(ancestorGens: 1, descendantGens: 4)
        let data = PedigreeChartReport.renderHourglassPDF(
            profileID: "ag0p0",
            generations: .four,
            showCompleteness: true,
            paperSize: .a4,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test func rendersThroughGeneratorDispatch() {
        // Smoke test that ReportGenerator routes .hourglass to the new
        // renderer and produces a unique filename suffix.
        let snapshot = fullSnapshot(ancestorGens: 4, descendantGens: 3)
        var options = ReportOptions(type: .pedigree, format: .pdf)
        options.profileID = "ag0p0"
        options.pedigreeGenerations = .four
        options.pedigreeStyle = .hourglass
        options.paperSize = .a4
        let output = try? ReportGenerator.generate(
            options: options,
            snapshot: snapshot
        )
        #expect(output != nil)
        #expect(output?.suggestedFilename.contains("hourglass") == true)
        #expect((output?.data.count ?? 0) > 0)
    }
}
