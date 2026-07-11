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

    /// FreeBMD transcription variants that map to canonical UK
    /// registration-district names. Volunteer transcribers occasionally
    /// drop a letter or follow a different spelling convention; the
    /// scorer's geography gate would otherwise soft-fail an otherwise
    /// good record as "unknown district". Keys are lowercased variants;
    /// values are the lowercased canonical form (used directly in
    /// dictionary lookups below). Add entries as drift surfaces them.
    ///
    /// 2026-05-24: "ashborne" → "ashbourne" from Catherine Hannah
    /// Bown's death record (Jun 1907 Ashborne) failing the geography
    /// gate.
    private static let districtAliases: [String: String] = [
        "ashborne": "ashbourne",
    ]

    /// Strip whitespace and a trailing " district" / " DISTRICT" suffix,
    /// lowercase, then apply known transcription-variant aliases.
    /// Sources return district names in varying case (FreeBMD
    /// uppercases; our stored keys are title case), and a case-
    /// sensitive dict lookup silently returns nil — which manifested
    /// as "unknown district: BELPER" soft-fails on records that should
    /// pass the geography gate. The alias step closes a second class
    /// of misses: transcription variants like "Ashborne" for the
    /// canonical "Ashbourne".
    private static func canonicalDistrictKey(_ raw: String) -> String {
        let base = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " district", with: "", options: .caseInsensitive)
            .lowercased()
        return districtAliases[base] ?? base
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

    /// FT-01 — the FreeBMD `countyid` wire value for a county-level query.
    ///
    /// IMPORTANT: the county select's option values use their OWN numeric
    /// ID space — NOT the district-select IDs in `districts(forChapmanCode:)`
    /// (probe 2026-07-11: reconstructed "DBY,406,418,…" returned a valid
    /// empty result; the live form's value is "DBY,47,77,78,…"). The table
    /// below is the complete option list captured from the live search form
    /// on 2026-07-10; `FreeBMDCountyProbeTests` (env-gated live probe)
    /// validates it. Re-capture if FreeBMD's form changes.
    static func freeBMDCountyID(forChapmanCode code: String) -> String? {
        let chapman = code.trimmingCharacters(in: .whitespaces).uppercased()
        return freeBMDCountyIDTable[chapman]
    }

    /// Captured verbatim from freebmd.org.uk's search form, 2026-07-10.
    private static let freeBMDCountyIDTable: [String: String] = [
        "AGY": "AGY,134,185",  // Anglesey (to Mar1974)
        "AVN": "AVN,96,166",  // Avon (from Jun1974)
        "BDF": "BDF,66,133,153,161,211",  // Bedfordshire
        "BRK": "BRK,7,69,110,124,130,151,152,156,169,171,197",  // Berkshire
        "BRE": "BRE,3,71,148,182,190,214",  // Breconshire (to Mar1974)
        "BKM": "BKM,22,28,119,132,151,196,211",  // Buckinghamshire
        "CAE": "CAE,126,180,185,217",  // Caernarvonshire (to Mar1974)
        "CAM": "CAM,17,39,63,66,72,79,170,175,176,212",  // Cambridgeshire
        "CGN": "CGN,8,123,210,219,228",  // Cardiganshire (to Mar1974)
        "CMN": "CMN,2,8,210,213,214,215",  // Carmarthenshire (to Mar1974)
        "CHS": "CHS,1,53,104,105,149,158,168,174,220,232",  // Cheshire
        "CLV": "CLV,29",  // Cleveland (from Jun1974)
        "CWD": "CWD,48",  // Clwyd (from Jun1974)
        "DUR": "DUR,45,46,106,107,191",  // Co. Durham
        "CON": "CON,59,61",  // Cornwall
        "CUL": "CUL,131",  // Cumberland (to Mar1974)
        "CMA": "CMA,135,188",  // Cumbria (from Jun1974)
        "DEN": "DEN,58,81,142,174,216,217,233",  // Denbighshire (to Mar1974)
        "DBY": "DBY,47,77,78,91,113,136,137,149,172,173",  // Derbyshire
        "DEV": "DEV,23,61,114,138,229",  // Devon
        "DOR": "DOR,31,93,138,195,222,229",  // Dorset
        "DFD": "DFD,101",  // Dyfed (from Jun1974)
        "ERY": "ERY,87,88,90,181",  // East Riding of Yorkshire (to Mar1974)
        "SXE": "SXE,144",  // East Sussex (from Jun1974)
        "ESS": "ESS,72,74,79,111,164,194,201,212",  // Essex
        "FLN": "FLN,53,58,143,168,174,202",  // Flintshire (to Mar1974)
        "GLA": "GLA,3,19,51,215",  // Glamorgan (to Mar1974)
        "GLS": "GLS,12,30,75,76,94,95,96,110,117,118,124,171,184,189,223,230,231",  // Gloucestershire
        "GTL": "GTL,14,56,160,164,187,235",  // Greater London (from Jun1965)
        "GTM": "GTM,73,105,112",  // Greater Manchester (from Jun1974)
        "GNT": "GNT,20",  // Gwent (from Jun1974)
        "GWN": "GWN,128",  // Gwynedd (from Jun1974)
        "HAM": "HAM,7,13,32,125,156,177,195,197,236",  // Hampshire
        "HWR": "HWR,70,76,116,199,205",  // Hereford and Worcester (from Jun1974)
        "HEF": "HEF,12,75,115,129,148,162,179,200,208,218,223",  // Herefordshire (to Mar1974)
        "HRT": "HRT,57,79,132,153,186,187,194,201",  // Hertfordshire
        "HUM": "HUM,50,155",  // Humberside (from Jun1974)
        "HUN": "HUN,63,66,102,121,157,175",  // Huntingdonshire (to Mar1974)
        "IOW": "IOW,236",  // Isle of Wight (from Sep1946)
        "KEN": "KEN,26,55,56,83,234,235",  // Kent
        "LAN": "LAN,5,62,73,84,104,105,122,188,203",  // Lancashire
        "LEI": "LEI,44,52,80,82,91,137,139,192,209,221",  // Leicestershire
        "LIN": "LIN,6,33,49,50,52,102,103,154,175,176,225,226",  // Lincolnshire
        "LND": "LND,55,60,65,67",  // London (to Mar1965)
        "MER": "MER,126,183,219,224,233",  // Merionethshire (to Mar1974)
        "MSY": "MSY,62,89,158",  // Merseyside (from Jun1974)
        "MGM": "MGM,140",  // Mid Glamorgan (from Jun1974)
        "MDX": "MDX,60,64,186,201,207",  // Middlesex (to Mar1965)
        "MON": "MON,19,129,178,190,223,230",  // Monmouthshire (to Mar1974)
        "MGY": "MGY,24,127,216,219,224",  // Montgomeryshire (to Mar1974)
        "NFK": "NFK,37,120,154,170",  // Norfolk
        "NRY": "NRY,40,54,87,106,181",  // North Riding of Yorkshire (to Mar1974)
        "NYK": "NYK,41,107",  // North Yorkshire (from Jun1974)
        "NTH": "NTH,22,42,80,99,102,103,121,161,175,176,184,196,209,221",  // Northamptonshire
        "NBL": "NBL,10,11,191",  // Northumberland
        "NTT": "NTT,6,43,91,172,173,192,225,226",  // Nottinghamshire
        "OXF": "OXF,119,124,130,151,167,171,184,196,197,231",  // Oxfordshire
        "PEM": "PEM,2,8,147,228",  // Pembrokeshire (to Mar1974)
        "POW": "POW,25",  // Powys (from Jun1974)
        "RAD": "RAD,68,71,148,179,208",  // Radnorshire (to Mar1974)
        "RUT": "RUT,102,139,204,209",  // Rutland (to Mar1974)
        "SAL": "SAL,21,34,108,109,115,116,127,142,163,168,199,202,205,208,218,220",  // Shropshire
        "SOM": "SOM,35,93,114,166,189,198,222,229",  // Somerset
        "SGM": "SGM,100",  // South Glamorgan (from Jun1974)
        "SYK": "SYK,78,92,226",  // South Yorkshire (from Jun1974)
        "STS": "STS,9,21,108,109,113,136,159,163,193,199,205,206,220,227,232",  // Staffordshire
        "SFK": "SFK,17,18,72,111,120",  // Suffolk
        "SRY": "SRY,16,67,125,146,160,169,207,234,235",  // Surrey
        "SSX": "SSX,15,83,125,146,177",  // Sussex (to Mar1974)
        "TWR": "TWR,11,36,46",  // Tyne and Wear (from Jun1974)
        "WAR": "WAR,38,44,80,94,95,97,98,99,113,163,184,193,199,206,231",  // Warwickshire
        "WGM": "WGM,4",  // West Glamorgan (from Jun1974)
        "WMD": "WMD,86,98,109,159",  // West Midlands (from Jun1974)
        "WRY": "WRY,27,49,54,77,84,90,172,181,225",  // West Riding of Yorkshire (to Mar1974)
        "SXW": "SXW,150",  // West Sussex (from Jun1974)
        "WYK": "WYK,122,145",  // West Yorkshire (from Jun1974)
        "WES": "WES,165,203",  // Westmorland (to Mar1974)
        "WIL": "WIL,13,85,117,124,152,156,198,222",  // Wiltshire
        "WOR": "WOR,12,94,97,108,110,115,118,141,163,200,206,227",  // Worcestershire (to Mar1974)
    ]

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
