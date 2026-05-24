import Testing
import Foundation
@testable import Ancestor_Research

/// Within-county locality check for the geography gate (parity cluster #4,
/// `eval/PARITY_REPORT_2026-05-25.md`).
///
/// Anchored to George Bowden (@I50104443@), the corpus's
/// `geographic_outlier` test subject. His twin records `birthLocation:
/// "Glossop, Derbyshire, England"` — Glossop is in DBY but sits in the
/// NW Derbyshire High Peak cluster, far from the canonical Belper /
/// Wirksworth / Ashbourne tree-core. Before this fix, every Derbyshire
/// registration district passed `isLocalDistrict("DBY")`, so a death
/// record from Basford (south DBY, 50mi from Glossop) promoted to
/// `.fact` against George — the corpus expects `out_of_scope` /
/// `not_yet_verified` because his twin lacks the death year required
/// to disambiguate.
///
/// New rule (only fires when subject has a parish-level birth anchor):
///   * Subject's birth town resolves to a home-county district via
///     `RegionConfig` / `FreeBMDDistrictCatalogue`.
///   * Record's district is in the same home county but DIFFERENT from
///     the subject's birth district.
///   * Record's district's parish list does NOT include the subject's
///     birth town (so successor districts like Glossop↔High Peak still
///     pass via parish containment).
/// Then geography returns `.softFail` instead of `.pass`, and the
/// scorer downgrades the record from `.fact` to `.lead`.
///
/// The rule MUST NOT regress:
///   * Robert Cauldwell's CWGC casualty (Lijssenthoek, Belgium) — the
///     `.military` short-circuit fires first.
///   * Subjects with no parish-level birth anchor (free-text
///     `birthLocation` = "Derbyshire, England" only).
///   * Records whose district's parishes overlap the subject's birth
///     parish (Glossop↔High Peak successor pair).
struct RecordScorerGeographyOutlierTests {

    // MARK: - Helpers

    /// George Bowden: born Glossop, no death year on twin. Wide birth
    /// window because the corpus YAML records a year discrepancy
    /// (twin 1902 vs registration 1901 vs bio 1901).
    private func georgeBowden(
        deathYear: Int? = nil,
        birthLocation: String = "Glossop, Derbyshire, England"
    ) -> ResearchSubject {
        ResearchSubject(
            surname: "Bowden",
            givenName: "George",
            birthYearFrom: 1900,
            birthYearTo: 1904,
            deathYearFrom: deathYear,
            deathYearTo: deathYear,
            gender: .male,
            region: .county(birthLocation),
            mode: .extend,
            homeChapmanCode: "DBY"
        )
    }

    /// A control subject for the tree-core: Ernest Cauldwell-style
    /// Belper-born so the gate's existing pass behaviour stays put
    /// when the record sits in the same district cluster as the
    /// subject's birth parish.
    private func belperBornSubject(
        givenName: String = "Ernest",
        surname: String = "Cauldwell",
        birthLow: Int = 1885,
        birthHigh: Int = 1889,
        deathYear: Int? = 1957
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname,
            givenName: givenName,
            birthYearFrom: birthLow,
            birthYearTo: birthHigh,
            deathYearFrom: deathYear,
            deathYearTo: deathYear,
            gender: .male,
            region: .county("Belper, Derbyshire, England"),
            mode: .extend,
            homeChapmanCode: "DBY"
        )
    }

    private func deathRecord(
        givenName: String,
        surname: String,
        deathYear: Int,
        district: String,
        age: Int? = nil
    ) -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(
                id: "death-\(givenName)-\(surname)-\(deathYear)-\(district)",
                sourceID: "freebmd",
                name: nil,
                surname: surname,
                givenName: givenName,
                detailURL: nil,
                rawFields: [:]
            ),
            deathYear: deathYear,
            deathDate: nil,
            deathPlace: nil,
            age: age,
            quarter: "Mar",
            district: district,
            volume: nil,
            page: nil,
            spouseSurname: nil
        ))
    }

    private func marriageRecord(
        givenName: String,
        surname: String,
        marriageYear: Int,
        district: String,
        spouseName: String? = "Keyworth"
    ) -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(
                id: "marriage-\(givenName)-\(surname)-\(marriageYear)-\(district)",
                sourceID: "freebmd",
                name: nil,
                surname: surname,
                givenName: givenName,
                detailURL: nil,
                rawFields: [:]
            ),
            marriageYear: marriageYear,
            marriageDate: nil,
            marriagePlace: nil,
            quarter: "Jun",
            district: district,
            volume: nil,
            page: nil,
            spouseName: spouseName
        ))
    }

    private func birthRecord(
        givenName: String,
        surname: String,
        birthYear: Int,
        district: String
    ) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: "birth-\(givenName)-\(surname)-\(birthYear)-\(district)",
                sourceID: "freebmd",
                name: nil,
                surname: surname,
                givenName: givenName,
                detailURL: nil,
                rawFields: [:]
            ),
            birthYear: birthYear,
            birthDate: nil,
            birthPlace: nil,
            quarter: "Sep",
            district: district,
            volume: nil,
            page: nil,
            mothersMaidenName: nil
        ))
    }

    // MARK: - George Bowden — the targeted over-claim

    @Test func georgeBowdenDeathInBasfordDoesNotPromoteToFact() {
        // The cluster-#4 bug. George has no death year on twin; the date
        // gate's death-axis logic accepts any record year that lands in
        // the [15, 100] plausibility band against the 1901-ish birth
        // window. Without the new locality check, a Basford death record
        // also passes geography (Basford is in DBY's district map) and
        // the verdict promotes to `.fact` → envelope emits "supported"
        // for `death_disambiguation` where the corpus expects
        // `out_of_scope`. Fix: Basford's parishes (Loscoe, Heanor,
        // Langley Mill) do not include Glossop → softFail → `.lead`.
        let result = RecordScorer.classify(
            record: deathRecord(
                givenName: "George",
                surname: "Bowden",
                deathYear: 1981,
                district: "Basford"
            ),
            subject: georgeBowden(),
            searchType: .death
        )
        #expect(result.verdict != .fact,
                "George/Basford-death must not auto-promote: got \(result.verdict)")
    }

    @Test func georgeBowdenDeathInIlkestonDoesNotPromoteToFact() {
        // Same shape as Basford — Ilkeston is a DBY district in the
        // tree-core cluster, not the Glossop area.
        let result = RecordScorer.classify(
            record: deathRecord(
                givenName: "George",
                surname: "Bowden",
                deathYear: 1965,
                district: "Ilkeston"
            ),
            subject: georgeBowden(),
            searchType: .death
        )
        #expect(result.verdict != .fact)
    }

    @Test func georgeBowdenMarriageInBakewellDoesNotPromoteToFact() {
        // Bakewell is a DBY district but its parishes (Bakewell,
        // Youlgreave, Monyash, …) don't include Glossop. The dispatch
        // log showed exactly this hit — `FreeBMD Bakewell marriages:
        // Bowden × Keyworth 1918–1962 → 1 result(s)` — promoting to
        // supported. Must drop to lead.
        let result = RecordScorer.classify(
            record: marriageRecord(
                givenName: "George",
                surname: "Bowden",
                marriageYear: 1920,
                district: "Bakewell"
            ),
            subject: georgeBowden(),
            searchType: .marriage
        )
        #expect(result.verdict != .fact)
    }

    // MARK: - Successor / overlapping districts still pass

    @Test func georgeBowdenDeathInGlossopStillPasses() {
        // Glossop IS George's birth district — geography must still pass
        // and the verdict can reach `.fact`. (Date and name gates still
        // apply; this just confirms the locality rule didn't break the
        // common-case pass.)
        let result = RecordScorer.classify(
            record: deathRecord(
                givenName: "George",
                surname: "Bowden",
                deathYear: 1965,
                district: "Glossop"
            ),
            subject: georgeBowden(),
            searchType: .death
        )
        // Without a known death year on the subject the date gate's
        // age-at-death window is wide; we just check this record
        // doesn't get demoted to a lead for the geography reason.
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .pass,
                "Glossop death for Glossop-born subject must pass geography: got \(geo?.outcome.rawValue ?? "nil")")
    }

    @Test func georgeBowdenDeathInHighPeakStillPasses() {
        // High Peak is the post-1974 successor district that covers the
        // same parishes as the historical Glossop RD — Buxton, Glossop,
        // Hadfield, New Mills, etc. The locality rule checks parish
        // overlap (not exact district name), so a High Peak record on a
        // Glossop-born subject must still pass geography.
        let result = RecordScorer.classify(
            record: deathRecord(
                givenName: "George",
                surname: "Bowden",
                deathYear: 1981,
                district: "High Peak"
            ),
            subject: georgeBowden(),
            searchType: .death
        )
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .pass,
                "High Peak (Glossop successor) must pass geography for a Glossop-born subject: got \(geo?.outcome.rawValue ?? "nil")")
    }

    // MARK: - Tree-core subjects must not regress

    @Test func belperSubjectDeathInBelperStillPromotes() {
        // Control: Ernest Cauldwell-style subject born Belper, death
        // record from Belper — geography is the matching district itself,
        // promotes to fact when date and name also pass. Pre-fix
        // behaviour, must be preserved.
        let result = RecordScorer.classify(
            record: deathRecord(
                givenName: "Ernest",
                surname: "Cauldwell",
                deathYear: 1957,
                district: "Belper"
            ),
            subject: belperBornSubject(),
            searchType: .death
        )
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .pass)
    }

    @Test func belperSubjectDeathInAmberValleyStillPromotes() {
        // Amber Valley is the post-1994 successor district to Belper —
        // its parishes (Belper, Heanor, Ripley, Alfreton, Crich, Denby,
        // Holbrook, Duffield, Turnditch) include Belper. A Belper-born
        // subject must still see Amber Valley records pass.
        let result = RecordScorer.classify(
            record: deathRecord(
                givenName: "Ernest",
                surname: "Cauldwell",
                deathYear: 1997,
                district: "Amber Valley"
            ),
            subject: belperBornSubject(),
            searchType: .death
        )
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .pass)
    }

    @Test func subjectWithoutParishLevelBirthLocationFallsThrough() {
        // When `birthLocation` is just a county name ("Derbyshire,
        // England"), there's no parish-level anchor — the locality rule
        // must NOT fire, and the gate falls through to the existing
        // pass for any in-county district. This is the safe default
        // for sparse-evidence subjects.
        var subject = belperBornSubject()
        subject.region = .county("Derbyshire, England")
        let result = RecordScorer.classify(
            record: deathRecord(
                givenName: "Ernest",
                surname: "Cauldwell",
                deathYear: 1957,
                district: "Bakewell"
            ),
            subject: subject,
            searchType: .death
        )
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .pass,
                "County-only birth location must not trigger locality check: got \(geo?.outcome.rawValue ?? "nil")")
    }

    @Test func subjectWithNilRegionFallsThrough() {
        // Belt-and-braces: a subject built from manual input with no
        // region at all must hit the legacy pass path.
        var subject = belperBornSubject()
        subject.region = nil
        let result = RecordScorer.classify(
            record: deathRecord(
                givenName: "Ernest",
                surname: "Cauldwell",
                deathYear: 1957,
                district: "Bakewell"
            ),
            subject: subject,
            searchType: .death
        )
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .pass)
    }

    // MARK: - CWGC carve-out preserved (Robert Cauldwell axis)

    @Test func cwgcMilitaryRecordStillPassesGeographyForOutlierSubject() {
        // Robert Cauldwell's CWGC casualty record at Lijssenthoek
        // Military Cemetery (Belgium) is a `.military` record — the
        // class-level short-circuit at the head of `checkGeography`
        // returns `.pass` for any `.military` record regardless of UK
        // residence data. Verify it still fires even when the subject
        // has a parish-level birth anchor that would otherwise trigger
        // the new locality check (and even though Belgium isn't a UK
        // district at all). Without the carve-out, military_service
        // for Robert regresses from `supported` to `inconclusive`.
        let military = MilitaryRecord(
            common: RecordCommon(
                id: "cwgc-robert",
                sourceID: "cwgc",
                name: "Robert Cauldwell",
                surname: "Cauldwell",
                givenName: "Robert",
                detailURL: nil,
                rawFields: [:]
            ),
            rank: "Private",
            regiment: "Sherwood Foresters",
            unit: nil,
            serviceNumber: nil,
            dateOfDeath: "1917-08-15",
            deathYear: 1917,
            age: 32,
            cemetery: "Lijssenthoek Military Cemetery",
            graveRef: nil,
            additionalInfo: "Son of John and Mary Cauldwell, of Turnditch, Derby"
        )
        // Robert's profile would carry Turnditch (Belper RD) as birth
        // locality; build a subject that would, in principle, trip
        // the new locality rule if it ever reached the structured-
        // district branch. The carve-out fires first.
        let robert = ResearchSubject(
            surname: "Cauldwell",
            givenName: "Robert",
            birthYearFrom: 1885,
            birthYearTo: 1885,
            deathYearFrom: 1917,
            deathYearTo: 1917,
            gender: .male,
            region: .county("Turnditch, Derbyshire, England"),
            mode: .extend,
            homeChapmanCode: "DBY"
        )
        let result = RecordScorer.classify(
            record: .military(military),
            subject: robert,
            searchType: .death
        )
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .pass,
                "CWGC short-circuit must pass: got \(geo?.outcome.rawValue ?? "nil")")
        #expect(geo?.reason.lowercased().contains("cwgc") == true,
                "Pass reason should cite the CWGC carve-out: \(geo?.reason ?? "")")
    }

    @Test func cwgcMilitaryStillPassesForGlossopBornOutlierSubject() {
        // Variant — a Glossop-born WWI casualty (hypothetical) must also
        // pass via the class short-circuit, not be tripped by the new
        // locality rule. Defensive: future test corpus may add a
        // High-Peak-born casualty.
        let military = MilitaryRecord(
            common: RecordCommon(
                id: "cwgc-glossop",
                sourceID: "cwgc",
                name: "George Bowden",
                surname: "Bowden",
                givenName: "George",
                detailURL: nil,
                rawFields: [:]
            ),
            rank: "Sergeant",
            regiment: nil,
            unit: nil,
            serviceNumber: nil,
            dateOfDeath: "1917-09-21",
            deathYear: 1917,
            age: 16,
            cemetery: "Tyne Cot",
            graveRef: nil,
            additionalInfo: nil
        )
        let result = RecordScorer.classify(
            record: .military(military),
            subject: georgeBowden(),
            searchType: .death
        )
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .pass)
    }

    // MARK: - Subject helpers (white-box checks)

    @Test func birthLocalityExtractsFirstCommaToken() {
        let glossop = georgeBowden()
        #expect(glossop.birthLocality == "Glossop")

        let belper = belperBornSubject()
        #expect(belper.birthLocality == "Belper")
    }

    @Test func birthLocalityRejectsCountyOnlyLocation() {
        // A profile that records `birthLocation: "Derbyshire, England"`
        // has no parish-level anchor — `birthLocality` must return nil
        // so the locality rule doesn't over-trigger.
        var subject = belperBornSubject()
        subject.region = .county("Derbyshire, England")
        #expect(subject.birthLocality == nil)
    }

    @Test func birthLocalityIsNilForNilRegion() {
        var subject = belperBornSubject()
        subject.region = nil
        #expect(subject.birthLocality == nil)
    }

    @Test func homeCountyBirthDistrictResolvesGlossop() {
        // Glossop parish lives in two configured DBY districts —
        // historical Glossop RD and post-1974 High Peak RD. Either
        // is acceptable; the within-county locality check uses
        // parish containment, not strict equality, so a slight bias
        // toward one resolution is fine.
        let glossop = georgeBowden().homeCountyBirthDistrict
        #expect(glossop == "Glossop" || glossop == "High Peak",
                "expected Glossop or High Peak, got \(String(describing: glossop))")
    }

    @Test func homeCountyBirthDistrictIsNilForCountyOnlyLocation() {
        var subject = belperBornSubject()
        subject.region = .county("Derbyshire, England")
        #expect(subject.homeCountyBirthDistrict == nil)
    }

    // MARK: - District coverage helper

    @Test func districtCoversParishHighPeakIncludesGlossop() {
        #expect(ScoringRules.districtCoversParish(
            "High Peak", parish: "Glossop", forHomeChapman: "DBY"
        ))
    }

    @Test func districtCoversParishBasfordDoesNotIncludeGlossop() {
        #expect(!ScoringRules.districtCoversParish(
            "Basford", parish: "Glossop", forHomeChapman: "DBY"
        ))
    }

    @Test func districtCoversParishIsCaseInsensitive() {
        #expect(ScoringRules.districtCoversParish(
            "high peak", parish: "GLOSSOP", forHomeChapman: "DBY"
        ))
    }

    // MARK: - Cross-district legitimate moves still surface as leads

    @Test func glossopBornBirthRecordInBasfordDoesNotPromote() {
        // Birth records are even more anchored to the subject's birth
        // locality than death records — a "George Bowden Sep 1901 Basford"
        // birth (~50mi from Glossop) is clearly the wrong person.
        // Locality rule keeps it from promoting.
        let result = RecordScorer.classify(
            record: birthRecord(
                givenName: "George",
                surname: "Bowden",
                birthYear: 1901,
                district: "Basford"
            ),
            subject: georgeBowden(),
            searchType: .birth
        )
        #expect(result.verdict != .fact)
    }
}
