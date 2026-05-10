import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the fan-chart pedigree variant (DESIGN.md §7.9.2).
///
/// `PedigreeChartReport.renderFanPDF` runs through `PDFRenderer`, which uses
/// `ImageRenderer` and therefore needs MainActor. We mark the whole suite
/// `@MainActor` so each test can call into it directly.
@MainActor
struct PedigreeFanChartTests {

    // MARK: - Test fixtures

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        birthYear: Int? = nil,
        deathYear: Int? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil,
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
        for gen in 0..<5 {
            let count = 1 << gen
            for row in 0..<count {
                let id = "g\(gen)p\(row)"
                profiles[id] = makeProfile(
                    id: id,
                    firstName: "Person\(gen)\(row)",
                    lastName: "Tree",
                    birthYear: 2000 - gen * 25,
                    deathYear: 2000 - gen * 25 + 60
                )
            }
        }
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

    // MARK: - PDF rendering

    @Test func rendersFourGenerationFanPDF() {
        let snapshot = fullFiveGenSnapshot()
        let data = PedigreeChartReport.renderFanPDF(
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

    @Test func rendersFiveGenerationFanPDF() {
        // 5-gen fan is tight on A4 but should still render — outer ring text
        // shrinks rather than the renderer erroring out.
        let snapshot = fullFiveGenSnapshot()
        let data = PedigreeChartReport.renderFanPDF(
            profileID: "g0p0",
            generations: .five,
            showCompleteness: true,
            paperSize: .a3,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test func rendersSubjectOnlyNoAncestors() {
        // Subject with nobody else in the snapshot — every ancestor wedge
        // must render as a muted "?" placeholder. The page must not crash
        // even though only the centre disc has a real profile.
        let subject = makeProfile(id: "lonely", firstName: "Lonely", birthYear: 1990)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["lonely": subject],
            relationships: []
        )
        let data = PedigreeChartReport.renderFanPDF(
            profileID: "lonely",
            generations: .four,
            showCompleteness: false,
            paperSize: .a4,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    @Test func rendersSparseSnapshotMissingGrandparents() {
        // Subject has both parents but only one grandparent on the paternal
        // side — paternal grandmother and the entire maternal grandparent
        // pair are missing. The fan must render gracefully without crashing.
        let subject = makeProfile(id: "s", firstName: "Subject", birthYear: 1990)
        let father = makeProfile(id: "f", firstName: "Father", birthYear: 1965)
        let mother = makeProfile(id: "m", firstName: "Mother", birthYear: 1967)
        let pgf = makeProfile(id: "pgf", firstName: "PaternalGF", birthYear: 1940)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["s": subject, "f": father, "m": mother, "pgf": pgf],
            relationships: [
                parentRel(from: "f", to: "s", role: .father),
                parentRel(from: "m", to: "s", role: .mother),
                parentRel(from: "pgf", to: "f", role: .father)
                // No paternal-grandmother edge; no maternal grandparents.
            ]
        )
        let data = PedigreeChartReport.renderFanPDF(
            profileID: "s",
            generations: .four,
            showCompleteness: true,
            paperSize: .a4,
            snapshot: snapshot
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    // MARK: - Style dispatch

    @Test func renderPDFDispatchesByStyle() {
        // The unified `renderPDF` entry should produce different bytes for
        // rectangular vs fan styles, since the layouts are different.
        let snapshot = fullFiveGenSnapshot()
        let rect = PedigreeChartReport.renderPDF(
            profileID: "g0p0",
            generations: .four,
            style: .rectangular,
            showCompleteness: false,
            paperSize: .a4,
            snapshot: snapshot
        )
        let fan = PedigreeChartReport.renderPDF(
            profileID: "g0p0",
            generations: .four,
            style: .fan,
            showCompleteness: false,
            paperSize: .a4,
            snapshot: snapshot
        )
        #expect(rect != nil)
        #expect(fan != nil)
        // Both render but the visual content differs — bytes won't match.
        #expect(rect != fan)
    }
}
