import Foundation

/// Generates a fictional family tree for App Store screenshots and demos.
/// Uses historically plausible Derbyshire names, dates, locations, and occupations.
/// No real people — entirely fictitious.
nonisolated struct DemoDataGenerator {

    static var isDemoMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo-mode") ||
        ScreenshotScreen.isScreenshotMode ||
        UserDefaults.standard.bool(forKey: "demoModeEnabled")
    }

    /// Generate a demo snapshot with ~30 profiles across 5 generations.
    static func generate() -> (profiles: [String: Profile], relationships: [Relationship]) {
        var profiles: [String: Profile] = [:]
        var relationships: [Relationship] = []
        let now = Date()
        let wt = SourceOrigin(identifier: "demo")

        func src(_ field: ProfileField, _ raw: String) -> [ProfileField: [FieldSource]] {
            [field: [FieldSource(origin: wt, raw: raw, addedAt: now)]]
        }

        func profile(
            id: String, first: String, last: String, gender: Gender,
            birth: String? = nil, birthLoc: String? = nil,
            death: String? = nil, deathLoc: String? = nil,
            bio: String? = nil
        ) -> Profile {
            var sources: [ProfileField: [FieldSource]] = [:]
            sources[.firstName] = [FieldSource(origin: wt, raw: first, addedAt: now)]
            sources[.lastName] = [FieldSource(origin: wt, raw: last, addedAt: now)]
            if let b = birth { sources[.birthDate] = [FieldSource(origin: wt, raw: b, addedAt: now)] }
            if let bl = birthLoc { sources[.birthLocation] = [FieldSource(origin: wt, raw: bl, addedAt: now)] }
            if let d = death { sources[.deathDate] = [FieldSource(origin: wt, raw: d, addedAt: now)] }

            return Profile(
                id: id, externalIDs: ["demo": id],
                firstName: first, lastName: last, gender: gender,
                birthDate: birth.map { GenealogicalDate(parsing: $0) },
                birthLocation: birthLoc,
                deathDate: death.map { GenealogicalDate(parsing: $0) },
                deathLocation: deathLoc,
                bio: bio, sources: sources, disputes: [:]
            )
        }

        func parent(_ parentID: String, _ childID: String, role: ParentRole) {
            relationships.append(Relationship(
                id: UUID(), from: parentID, to: childID,
                type: .parent, role: role, subtype: .unknown,
                marriageDate: nil, divorceDate: nil
            ))
        }

        func spouse(_ a: String, _ b: String, marriageDate: String? = nil) {
            relationships.append(Relationship(
                id: UUID(), from: a, to: b,
                type: .spouse, role: nil, subtype: .unknown,
                marriageDate: marriageDate.map { GenealogicalDate(parsing: $0) },
                divorceDate: nil
            ))
        }

        // ── Generation 1: Great-great-grandparents (born ~1790s) ──

        let gg1 = profile(id: "demo-001", first: "William", last: "Ashford", gender: .male,
            birth: "1792", birthLoc: "Wirksworth, Derbyshire, England",
            death: "1861", bio: "Lead miner at Goodluck Mine, Wirksworth. Married Sarah at Wirksworth parish church.")
        let gg2 = profile(id: "demo-002", first: "Sarah", last: "Bunting", gender: .female,
            birth: "1795", birthLoc: "Cromford, Derbyshire, England",
            death: "1868")

        profiles[gg1.id] = gg1; profiles[gg2.id] = gg2
        spouse("demo-001", "demo-002", marriageDate: "1816")

        // ── Generation 2: Great-grandparents (born ~1820s) ──

        let g1 = profile(id: "demo-010", first: "Thomas", last: "Ashford", gender: .male,
            birth: "1821-03-15", birthLoc: "Wirksworth, Derbyshire, England",
            death: "1889-11-02", deathLoc: "Bakewell, Derbyshire, England",
            bio: "Quarryman at Middleton quarry. Census 1851: age 30, married, 3 children. Census 1861: age 40, quarryman, 5 children.")
        let g2 = profile(id: "demo-011", first: "Martha", last: "Fearn", gender: .female,
            birth: "1824", birthLoc: "Matlock, Derbyshire, England",
            death: "1893")
        let g3 = profile(id: "demo-012", first: "James", last: "Hartington", gender: .male,
            birth: "1818", birthLoc: "Bakewell, Derbyshire, England",
            death: "1875")
        let g4 = profile(id: "demo-013", first: "Elizabeth", last: "Wragg", gender: .female,
            birth: "1822-07-08", birthLoc: "Belper, Derbyshire, England",
            death: "1901-01-15")

        for p in [g1, g2, g3, g4] { profiles[p.id] = p }
        parent("demo-001", "demo-010", role: .father)
        parent("demo-002", "demo-010", role: .mother)
        spouse("demo-010", "demo-011", marriageDate: "1845")
        spouse("demo-012", "demo-013", marriageDate: "1842")

        // ── Generation 3: Grandparents (born ~1850s) ──

        let p1 = profile(id: "demo-020", first: "George", last: "Ashford", gender: .male,
            birth: "1850-09-22", birthLoc: "Wirksworth, Derbyshire, England",
            death: "1918-03-14", deathLoc: "Wirksworth, Derbyshire, England",
            bio: "Framework knitter then lead miner. Married Mary Hartington at Bakewell in 1874. Six children. Died during influenza epidemic.")
        let p2 = profile(id: "demo-021", first: "Mary", last: "Hartington", gender: .female,
            birth: "1853-04-11", birthLoc: "Bakewell, Derbyshire, England",
            death: "1932-08-20")
        let p3 = profile(id: "demo-022", first: "Samuel", last: "Ashford", gender: .male,
            birth: "1848", birthLoc: "Wirksworth, Derbyshire, England",
            death: "1916")
        let p4 = profile(id: "demo-023", first: "Annie", last: "Smedley", gender: .female,
            birth: "1855", birthLoc: "Crich, Derbyshire, England")
        let p5 = profile(id: "demo-024", first: "Ellen", last: "Ashford", gender: .female,
            birth: "1856", birthLoc: "Wirksworth, Derbyshire, England",
            death: "1890", bio: "Died young — possibly in childbirth. Buried at Wirksworth.")

        for p in [p1, p2, p3, p4, p5] { profiles[p.id] = p }
        parent("demo-010", "demo-020", role: .father)
        parent("demo-011", "demo-020", role: .mother)
        parent("demo-010", "demo-022", role: .father)
        parent("demo-011", "demo-022", role: .mother)
        parent("demo-010", "demo-024", role: .father)
        parent("demo-011", "demo-024", role: .mother)
        parent("demo-012", "demo-021", role: .father)
        parent("demo-013", "demo-021", role: .mother)
        spouse("demo-020", "demo-021", marriageDate: "1874")
        spouse("demo-022", "demo-023")

        // ── Generation 4: Parents (born ~1880s) ──

        let c1 = profile(id: "demo-030", first: "Albert", last: "Ashford", gender: .male,
            birth: "1878-12-04", birthLoc: "Wirksworth, Derbyshire, England",
            death: "1952-06-18", deathLoc: "Belper, Derbyshire, England",
            bio: "Served in Sherwood Foresters, survived the Somme. Returned to lead mining then moved to Belper cotton mills.")
        let c2 = profile(id: "demo-031", first: "Florence", last: "Kirkland", gender: .female,
            birth: "1882-03-21", birthLoc: "Duffield, Derbyshire, England",
            death: "1961-11-30")
        let c3 = profile(id: "demo-032", first: "Harold", last: "Ashford", gender: .male,
            birth: "1880", birthLoc: "Wirksworth, Derbyshire, England",
            death: "1916-07-01", deathLoc: "Thiepval, France",
            bio: "Private, 1st Battalion Sherwood Foresters. Killed in action on the first day of the Battle of the Somme. Memorial: Thiepval.")
        let c4 = profile(id: "demo-033", first: "Edith", last: "Ashford", gender: .female,
            birth: "1884", birthLoc: "Wirksworth, Derbyshire, England")
        let c5 = profile(id: "demo-034", first: "Clara", last: "Ashford", gender: .female,
            birth: "1876-08-10", birthLoc: "Wirksworth, Derbyshire, England",
            death: "1945-02-14")

        for p in [c1, c2, c3, c4, c5] { profiles[p.id] = p }
        parent("demo-020", "demo-034", role: .father)
        parent("demo-021", "demo-034", role: .mother)
        parent("demo-020", "demo-030", role: .father)
        parent("demo-021", "demo-030", role: .mother)
        parent("demo-020", "demo-032", role: .father)
        parent("demo-021", "demo-032", role: .mother)
        parent("demo-020", "demo-033", role: .father)
        parent("demo-021", "demo-033", role: .mother)
        spouse("demo-030", "demo-031", marriageDate: "1904")

        // ── Generation 5: Present (born ~1910s-1940s) ──

        let d1 = profile(id: "demo-040", first: "Dorothy", last: "Ashford", gender: .female,
            birth: "1906-01-28", birthLoc: "Belper, Derbyshire, England",
            death: "1989-03-15")
        let d2 = profile(id: "demo-041", first: "Ernest", last: "Ashford", gender: .male,
            birth: "1910-05-12", birthLoc: "Belper, Derbyshire, England",
            death: "1978-09-03")
        let d3 = profile(id: "demo-042", first: "Margaret", last: "Ashford", gender: .female,
            birth: "1914-11-07", birthLoc: "Belper, Derbyshire, England")

        for p in [d1, d2, d3] { profiles[p.id] = p }
        parent("demo-030", "demo-040", role: .father)
        parent("demo-031", "demo-040", role: .mother)
        parent("demo-030", "demo-041", role: .father)
        parent("demo-031", "demo-041", role: .mother)
        parent("demo-030", "demo-042", role: .father)
        parent("demo-031", "demo-042", role: .mother)

        return (profiles, relationships)
    }
}
