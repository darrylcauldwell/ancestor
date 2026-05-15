import Foundation

/// Regional configuration for research — district mappings, parish lists, etc.
/// Loaded from bundled JSON. Different regions provide different mappings
/// without changing the strategy detection logic.
nonisolated struct RegionConfig: Codable, Sendable {
    let county: String
    let chapmanCode: String
    let country: String
    let defaultLocation: String
    let districts: [String: String]             // name → FreeBMD code
    let districtParishes: [String: [String]]    // district → parishes
    let nonLocalDistricts: [String: String]     // district → location name

    /// Load region config from a bundled JSON resource.
    static func load(named name: String = "derbyshire") -> RegionConfig? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Regions") else {
            return Self.derbyshire  // fallback to hardcoded
        }
        guard let data = try? Data(contentsOf: url) else { return Self.derbyshire }
        return try? JSONDecoder().decode(RegionConfig.self, from: data)
    }

    /// Hardcoded Derbyshire config — fallback if JSON resource not found.
    /// Ported from Python config.yaml.
    ///
    /// District codes verified against FreeBMD's authoritative dropdown
    /// (https://www.freebmd.org.uk/search). Each code passes when sent
    /// to FreeBMD's POST endpoint; the prior config had five wrong codes
    /// (420 Bakewell, 621 Chesterfield, 710 Derby, 676 Basford, 765 Worksop)
    /// that silently produced zero results.
    ///
    /// Includes successor districts from post-1974 boundary changes:
    /// High Peak (from Jun1974), Amber Valley (from Jun1994 — successor to
    /// Belper), South Derbyshire (from Jun1997), Ilkeston (Jun1938-Mar1997).
    /// Glossop (Jun1898-Mar1974) covers the same area pre-reorganisation
    /// that High Peak now covers.
    static let derbyshire = RegionConfig(
        county: "Derbyshire",
        chapmanCode: "DBY",
        country: "England",
        defaultLocation: "Derbyshire, England",
        districts: [
            // Pre-1974 districts (still valid for their period)
            "Belper": "722",            // (to Jun1994)
            "Ashbourne": "418",
            "Bakewell": "691",          // was 420
            "Chesterfield": "1102",     // was 621
            "Derby": "1016",            // was 710
            "Basford": "707",           // was 676 — Nottinghamshire-side, covered SE Derbyshire historically
            "Worksop": "630",           // was 765 — Nottinghamshire-side, covered NE Derbyshire historically
            "Glossop": "81",            // (Jun1898-Mar1974) — NW Derbyshire pre-reorganisation
            // Post-1974 successors
            "High Peak": "495",         // (from Jun1974) — successor to Glossop/Bakewell area
            "Ilkeston": "1149",         // (Jun1938-Mar1997) — east Derbyshire
            "Amber Valley": "406",      // (from Jun1994) — successor to Belper
            "South Derbyshire": "246",  // (from Jun1997)
        ],
        districtParishes: [
            "Belper": ["Turnditch", "Windley", "Duffield", "Heage", "Crich", "Holbrook",
                       "Belper", "Kilburn", "Denby", "Mugginton", "Weston Underwood",
                       "Kirk Ireton", "Hulland"],
            "Ashbourne": ["Ashbourne", "Mappleton", "Tissington", "Bradbourne",
                          "Parwich", "Doveridge", "Kirk Ireton"],
            "Bakewell": ["Bakewell", "Youlgreave", "Monyash", "Baslow", "Eyam",
                         "Matlock", "Darley Dale", "Snitterton", "Wensley",
                         "Middleton by Wirksworth", "Wirksworth", "Cromford"],
            "Derby": ["Derby", "Littleover", "Mickleover", "Spondon"],
            "Chesterfield": ["Chesterfield", "Brampton", "Staveley", "Unstone"],
            "Basford": ["Loscoe", "Heanor", "Langley Mill"],
            "Worksop": ["Worksop"],
            "Glossop": ["Glossop", "Hadfield", "Tintwistle", "Charlesworth"],
            "High Peak": ["Buxton", "Glossop", "Hadfield", "New Mills", "Whaley Bridge",
                          "Chapel-en-le-Frith", "Bakewell", "Matlock", "Wirksworth"],
            "Ilkeston": ["Ilkeston", "Heanor", "Langley Mill", "Long Eaton", "Sandiacre"],
            "Amber Valley": ["Belper", "Heanor", "Ripley", "Alfreton", "Crich",
                             "Denby", "Holbrook", "Duffield", "Turnditch"],
            "South Derbyshire": ["Swadlincote", "Repton", "Melbourne", "Hilton"],
        ],
        nonLocalDistricts: [
            "Chorlton": "Manchester",
            "Kensington": "London",
            "Birmingham": "West Midlands",
            "Leeds": "Yorkshire",
            "Bristol": "Somerset",
            "Salford": "Manchester",
            "Lambeth": "London",
            "Islington": "London",
        ]
    )

    // MARK: - Lookup helpers (used by ScoringRules)

    /// Strip whitespace and a trailing " district" / " DISTRICT" suffix,
    /// then lowercase for the case-insensitive lookups below. Sources
    /// return district names in varying case (FreeBMD uppercases; our
    /// stored keys are title case), and a case-sensitive dict lookup
    /// silently returns nil — which manifested as "unknown district:
    /// BELPER" soft-fails on records that should pass the geography gate.
    private static func canonicalDistrictKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " district", with: "", options: .caseInsensitive)
            .lowercased()
    }

    func isLocalDistrict(_ district: String) -> Bool {
        let needle = Self.canonicalDistrictKey(district)
        return districtParishes.keys.contains { $0.lowercased() == needle }
    }

    func nonLocalLocation(for district: String) -> String? {
        let needle = Self.canonicalDistrictKey(district)
        for (key, location) in nonLocalDistricts where key.lowercased() == needle {
            return location
        }
        return nil
    }

    func parishes(in district: String) -> [String] {
        let needle = Self.canonicalDistrictKey(district)
        for (key, parishes) in districtParishes where key.lowercased() == needle {
            return parishes
        }
        return []
    }

    func district(for parish: String) -> String? {
        let parishLower = parish.lowercased()
        // Sorted iteration so a parish that appears in multiple districts
        // (e.g. Wirksworth in Bakewell AND High Peak) returns the same answer
        // every time — Swift's dict order is non-deterministic and was causing
        // a test flake before this fix.
        for district in districtParishes.keys.sorted() {
            let parishes = districtParishes[district] ?? []
            if parishes.contains(where: { $0.lowercased() == parishLower }) {
                return district
            }
        }
        return nil
    }

    // MARK: - Per-subject factories (RESEARCH_AXES_SPEC Change 1)

    /// District map for a given Chapman code. Returns the hand-curated
    /// Derbyshire map for "DBY" (12 verified entries with parish lists);
    /// for any other Chapman code, derives from the national
    /// FreeBMDDistrictCatalogue's enrichment (district name → FreeBMD code
    /// for every district tagged with that county). 68% of the 1125 catalogue
    /// entries are tagged in the initial enrichment; untagged districts are
    /// mostly post-1974 modern composites, fill in over time.
    /// Empty map signals "no local-district knowledge" — scoring downgrades
    /// accordingly rather than failing.
    static func districts(forChapmanCode code: String) -> [String: String] {
        let upper = code.uppercased()
        if upper == "DBY" { return Self.derbyshire.districts }
        let entries = FreeBMDDistrictCatalogue.shared.districts(forChapmanCode: upper)
        var map: [String: String] = [:]
        for entry in entries {
            // First occurrence wins — districts with successor renames
            // (e.g. Glossop → High Peak) appear twice in the catalogue
            // with different validity windows but the same canonical name
            // would otherwise collide. The earlier-seen entry keeps its slot.
            if map[entry.name] == nil { map[entry.name] = entry.code }
        }
        return map
    }

    /// Single-hop adjacency lookup. Returns the Chapman codes of counties
    /// bordering the given county; empty array for island chains, sea-bounded
    /// codes, or unknown inputs. Symmetric — `A in adjacentCounties(B)` iff
    /// `B in adjacentCounties(A)`, enforced by tests. Backed by
    /// `Resources/Regions/county-adjacency.json` (RESEARCH_AXES_SPEC Change 2).
    static func adjacentCounties(_ code: String) -> [String] {
        CountyAdjacency.shared.neighbours(of: code)
    }

    /// Resolve the rich per-county config (parishes, non-local map, etc.) for
    /// a Chapman code. Currently Derbyshire-only — non-DBY codes return nil.
    /// Callers should fall through to the bare district map (`districts(forChapmanCode:)`)
    /// when this returns nil.
    static func config(forChapmanCode code: String) -> RegionConfig? {
        switch code.uppercased() {
        case "DBY": return Self.derbyshire
        default:    return nil
        }
    }
}
