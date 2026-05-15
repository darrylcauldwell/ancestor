import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_AXES_SPEC.md Change 2 — county adjacency.
struct RegionConfigAdjacencyTests {

    // MARK: - AC2.1 — county-adjacency.json ships with the expected coverage

    @Test func ac2_1_coverageCountsMatchSpec() {
        let codes = UKChapmanCodes.shared.codes
        let map = CountyAdjacency.shared.map
        // Every Chapman code in the catalogue has an adjacency entry (even
        // if empty for islands / sea-bounded counties).
        for entry in codes {
            #expect(map[entry.code] != nil, "missing adjacency entry for \(entry.code)")
        }
        // Coverage check: 43 English + 13 Welsh + 33 Scottish + 4 Channel Islands + 1 Isle of Man
        // = 94 entries. Matches uk-chapman-codes.json (Ireland excluded — see file header).
        #expect(map.count == 94)
    }

    // MARK: - AC2.2 — adjacency is symmetric

    @Test func ac2_2_adjacencyIsSymmetric() {
        let map = CountyAdjacency.shared.map
        for (code, neighbours) in map {
            for neighbour in neighbours {
                let reciprocal = map[neighbour] ?? []
                #expect(
                    reciprocal.contains(code),
                    "asymmetric: \(code) lists \(neighbour) but \(neighbour) doesn't list \(code)"
                )
            }
        }
    }

    @Test func ac2_2_adjacencyEntriesReferenceKnownCodes() {
        let knownCodes = Set(UKChapmanCodes.shared.codes.map(\.code))
        let map = CountyAdjacency.shared.map
        for (code, neighbours) in map {
            #expect(knownCodes.contains(code), "unknown source code: \(code)")
            for neighbour in neighbours {
                #expect(knownCodes.contains(neighbour), "\(code) → unknown neighbour \(neighbour)")
            }
        }
    }

    @Test func ac2_2_noSelfReference() {
        let map = CountyAdjacency.shared.map
        for (code, neighbours) in map {
            #expect(!neighbours.contains(code), "\(code) lists itself as adjacent")
        }
    }

    // MARK: - AC2.3 — spot checks

    @Test func ac2_3_derbyshireBordersIncludeNTTSTSandCHS() {
        let neighbours = Set(RegionConfig.adjacentCounties("DBY"))
        #expect(neighbours.contains("NTT"))
        #expect(neighbours.contains("STS"))
        #expect(neighbours.contains("CHS"))
    }

    @Test func ac2_3_kentBordersIncludeSRYandSSX() {
        let neighbours = Set(RegionConfig.adjacentCounties("KEN"))
        #expect(neighbours.contains("SRY"))
        #expect(neighbours.contains("SSX"))
    }

    @Test func ac2_3_unknownCodeReturnsEmpty() {
        #expect(RegionConfig.adjacentCounties("ZZZ").isEmpty)
        #expect(RegionConfig.adjacentCounties("").isEmpty)
    }

    @Test func ac2_3_islandsHaveNoLandNeighbours() {
        #expect(RegionConfig.adjacentCounties("IOM").isEmpty)
        #expect(RegionConfig.adjacentCounties("AGY").isEmpty)
        #expect(RegionConfig.adjacentCounties("JSY").isEmpty)
    }

    @Test func ac2_3_lookupIsCaseInsensitive() {
        let upper = Set(RegionConfig.adjacentCounties("DBY"))
        let lower = Set(RegionConfig.adjacentCounties("dby"))
        let mixed = Set(RegionConfig.adjacentCounties("Dby"))
        #expect(upper == lower)
        #expect(upper == mixed)
    }

    @Test func ac2_3_crossBorderEnglandScotlandAdjacencyExists() {
        // NBL (Northumberland) borders BEW (Berwickshire) and ROX (Roxburghshire) in Scotland.
        // CUL (Cumberland) borders DFS (Dumfriesshire) and KKD (Kirkcudbrightshire).
        // These are the only England–Scotland land borders.
        #expect(Set(RegionConfig.adjacentCounties("NBL")).isSuperset(of: ["BEW", "ROX"]))
        #expect(Set(RegionConfig.adjacentCounties("CUL")).isSuperset(of: ["DFS", "KKD"]))
    }
}
