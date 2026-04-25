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
    static let derbyshire = RegionConfig(
        county: "Derbyshire",
        chapmanCode: "DBY",
        country: "England",
        defaultLocation: "Derbyshire, England",
        districts: [
            "Belper": "722",
            "Ashbourne": "418",
            "Bakewell": "420",
            "Chesterfield": "621",
            "Derby": "710",
            "Basford": "676",
            "Worksop": "765",
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

    func isLocalDistrict(_ district: String) -> Bool {
        let clean = district.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " district", with: "")
        return districtParishes[clean] != nil
    }

    func nonLocalLocation(for district: String) -> String? {
        let clean = district.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " district", with: "")
        return nonLocalDistricts[clean]
    }

    func parishes(in district: String) -> [String] {
        districtParishes[district] ?? []
    }

    func district(for parish: String) -> String? {
        let parishLower = parish.lowercased()
        for (district, parishes) in districtParishes {
            if parishes.contains(where: { $0.lowercased() == parishLower }) {
                return district
            }
        }
        return nil
    }
}
