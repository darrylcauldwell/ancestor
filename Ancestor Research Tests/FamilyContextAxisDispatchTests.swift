import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the dispatcher-side family-context axis plumbing for FreeBMD and
/// FindAGrave, plus FreeBMD's source-side `s_surname` overload for births
/// (MMN) vs marriages (spouse). Spec §23 — every known fact reaches every
/// source that can use it.
@MainActor
struct FamilyContextAxisDispatchTests {

    // MARK: - #Change6-followup — homeCountry derivation for FS q.anyPlace

    @Test func homeCountryDerivesFromTreePlaceData() {
        // Country tail of a place string — tree-derived, no hardcoded region.
        #expect(SearchDispatcher.homeCountry(from: .county("Loscoe, Derbyshire, England")) == "England")
        #expect(SearchDispatcher.homeCountry(from: .parish("Duffield", county: "Belper, Derbyshire, Scotland")) == "Scotland")
        // Explicit UK-nation regions map to their nation.
        #expect(SearchDispatcher.homeCountry(from: .englandAndWales) == "England")
        #expect(SearchDispatcher.homeCountry(from: .scotland) == "Scotland")
        #expect(SearchDispatcher.homeCountry(from: .ireland) == "Ireland")
        // No derivable country → nil (never a hardcoded fallback).
        #expect(SearchDispatcher.homeCountry(from: .commonwealthMilitary) == nil)
        #expect(SearchDispatcher.homeCountry(from: nil) == nil)
    }

    // MARK: - FreeBMD MMN dispatcher gating

    @Test func freeBMDBirthPost1912PopulatesMotherSurnameFromContext() {
        let dispatcher = makeDispatcher()
        let subject = subjectWithMotherSurname(
            "Ward",
            birthYearFrom: 1919,
            birthYearTo: 1919
        )
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .birth)
        #expect(!queries.isEmpty)
        let mmns = queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.motherSurname }
            return nil
        }
        #expect(mmns.allSatisfy { $0 == "Ward" })
    }

    @Test func freeBMDBirthPre1912OmitsMotherSurname() {
        // GRO birth indexes pre-Sep-1911 do not carry MMN; filtering on it
        // would return zero hits. Dispatcher must gate by yearFrom >= 1912.
        let dispatcher = makeDispatcher()
        let subject = subjectWithMotherSurname(
            "Ward",
            birthYearFrom: 1905,
            birthYearTo: 1905
        )
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .birth)
        #expect(!queries.isEmpty)
        for q in queries {
            guard case .freeBMD(let p) = q.sourceParams else {
                Issue.record("Expected FreeBMDParams")
                continue
            }
            #expect(p.motherSurname == nil, "pre-1912 birth must not carry MMN; got \(p.motherSurname ?? "nil")")
        }
    }

    @Test func freeBMDBirth1911OnTheCuspOmitsMotherSurname() {
        // 1911 itself is ambiguous (Q1–Q2 lacks MMN, Q3–Q4 has it).
        // Dispatcher gates conservatively on yearFrom >= 1912 to avoid
        // erasing legitimate Q1–Q2 1911 hits.
        let dispatcher = makeDispatcher()
        let subject = subjectWithMotherSurname(
            "Ward",
            birthYearFrom: 1911,
            birthYearTo: 1911
        )
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .birth)
        for q in queries {
            guard case .freeBMD(let p) = q.sourceParams else { continue }
            #expect(p.motherSurname == nil)
        }
    }

    @Test func freeBMDDeathDoesNotCarryMotherOrSpouseSurname() {
        let dispatcher = makeDispatcher()
        let subject = subjectWithFullContext(birthYearFrom: 1919, birthYearTo: 1919)
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .death)
        for q in queries {
            guard case .freeBMD(let p) = q.sourceParams else { continue }
            #expect(p.motherSurname == nil)
            #expect(p.spouseSurname == nil)
        }
    }

    @Test func freeBMDMarriageStillCarriesSpouseSurname() {
        // Regression: marriage queries must keep wiring through spouseSurname
        // (unchanged behaviour) — only s_surname's source-side mapping was
        // restructured.
        let dispatcher = makeDispatcher()
        let subject = subjectWithFullContext(birthYearFrom: 1919, birthYearTo: 1919)
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .marriage)
        let spouseSurnames = queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.spouseSurname }
            return nil
        }
        #expect(spouseSurnames.allSatisfy { $0 == "Wheeldon" })
    }

    // MARK: - FreeBMD spouse-maiden fan-out (groom-side inverted wife)

    @Test func freeBMDMarriageFansOutBrideSurnameWhenWifeImportedInverted() {
        // Models Ernest Cauldwell: wife Sarah is recorded under her
        // married surname ("Cauldwell"), but her real maiden surname
        // is "Ward" via her father Joseph Ward on the tree. The
        // dispatcher must fan out FreeBMD probes across BOTH spouse
        // surnames so the canonical `Cauldwell × Ward` Ashbourne
        // Q1 1915 entry shows up alongside any `Cauldwell × Cauldwell`
        // probes the old code would have run.
        let dispatcher = makeDispatcher()
        let subject = subjectWithInvertedWife(
            spouseSurname: "Cauldwell",
            spouseFatherSurname: "Ward",
            birthYearFrom: 1887,
            birthYearTo: 1887
        )
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .marriage)
        let spouseSurnames = Set(queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.spouseSurname }
            return nil
        })
        #expect(spouseSurnames.contains("Cauldwell"),
                "Original spouseSurname must still be probed; got \(spouseSurnames)")
        #expect(spouseSurnames.contains("Ward"),
                "Wife's maiden via spouseFatherSurname must also be probed; got \(spouseSurnames)")

        // The fan-out should double the marriage-query count (one query
        // per district per spouse surname), not replace the original.
        let districts = Set(queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.districtCode }
            return nil
        })
        #expect(queries.count == districts.count * 2,
                "Expected one query per district per spouse surname; got \(queries.count) queries across \(districts.count) districts")
    }

    @Test func freeBMDMarriageDoesNotDuplicateWhenWifeImportedWell() {
        // Well-imported wife: lastName already matches her father's
        // surname (she's recorded under her maiden name per wikitree
        // convention). spouseFatherSurname equals spouseSurname, so
        // the equality check suppresses the duplicate probe and we
        // emit one query per district, not two.
        let dispatcher = makeDispatcher()
        let subject = subjectWithInvertedWife(
            spouseSurname: "Wheeldon",
            spouseFatherSurname: "Wheeldon",
            birthYearFrom: 1919,
            birthYearTo: 1919
        )
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .marriage)
        let spouseSurnames = queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.spouseSurname }
            return nil
        }
        #expect(spouseSurnames.allSatisfy { $0 == "Wheeldon" },
                "All probes should use the single shared surname; got \(Set(spouseSurnames))")

        let districts = Set(queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.districtCode }
            return nil
        })
        #expect(queries.count == districts.count,
                "No fan-out when surnames match — one query per district only")
    }

    @Test func freeBMDMarriageGracefulWhenSpouseFatherSurnameMissing() {
        // Wife has no linked father on the tree (no spouseFatherSurname).
        // Dispatcher must continue with single-axis behaviour — the
        // recorded spouseSurname only — and never emit a probe with a
        // nil surname when one was already populated.
        let dispatcher = makeDispatcher()
        let subject = subjectWithInvertedWife(
            spouseSurname: "Cauldwell",
            spouseFatherSurname: nil,
            birthYearFrom: 1887,
            birthYearTo: 1887
        )
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .marriage)
        let spouseSurnames = queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.spouseSurname }
            return nil
        }
        #expect(spouseSurnames.allSatisfy { $0 == "Cauldwell" })

        let districts = Set(queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.districtCode }
            return nil
        })
        #expect(queries.count == districts.count,
                "Single-axis when spouseFatherSurname missing")
    }

    @Test func freeBMDMarriageGracefulWhenNoSpouseAtAll() {
        // No spouse on context (e.g. an unmarried subject or a
        // researched-from-user-input subject with no family graph).
        // Marriage probes still emit — they just carry nil spouse
        // surname, matching pre-fix behaviour.
        let dispatcher = makeDispatcher()
        var subject = subjectWithFullContext(birthYearFrom: 1919, birthYearTo: 1919)
        subject.familyContext = nil
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .marriage)
        let spouseSurnames = queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.spouseSurname }
            return nil
        }
        #expect(spouseSurnames.isEmpty,
                "Nil familyContext → no spouse surname on any probe; got \(spouseSurnames)")
        #expect(!queries.isEmpty, "Marriage probes must still fire without family context")
    }

    @Test func freeBMDFanOutCaseInsensitive() {
        // spouseSurname "Cauldwell" vs spouseFatherSurname "CAULDWELL"
        // (different case) — still treated as equal, no duplicate probe.
        let dispatcher = makeDispatcher()
        let subject = subjectWithInvertedWife(
            spouseSurname: "Cauldwell",
            spouseFatherSurname: "CAULDWELL",
            birthYearFrom: 1887,
            birthYearTo: 1887
        )
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .marriage)
        let districts = Set(queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.districtCode }
            return nil
        })
        #expect(queries.count == districts.count, "Case-insensitive equality must suppress duplicate")
    }

    @Test func freeBMDBirthIgnoresSpouseFatherSurname() {
        // Birth queries must never carry a spouse surname (the
        // s_surname overload uses MMN for births, not spouse). The
        // spouseFatherSurname fan-out is scoped to .marriage only.
        let dispatcher = makeDispatcher()
        let subject = subjectWithInvertedWife(
            spouseSurname: "Cauldwell",
            spouseFatherSurname: "Ward",
            birthYearFrom: 1887,
            birthYearTo: 1887
        )
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .birth)
        for q in queries {
            guard case .freeBMD(let p) = q.sourceParams else { continue }
            #expect(p.spouseSurname == nil,
                    "Birth must not carry spouse surname; got \(p.spouseSurname ?? "nil")")
        }
    }

    // MARK: - FreeBMD source-side s_surname overload (wire test)

    @Test func freeBMDSourceBirthSendsMotherSurnameInSSurnameField() async {
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .birth,
            yearFrom: 1920, yearTo: 1920, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: "Jones",
                spouseSurname: nil
            )),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("s_surname=Jones"),
                "FreeBMD birth must send MMN via s_surname; body was \(body)")
    }

    @Test func freeBMDSourceMarriageSendsSpouseSurnameInSSurnameField() async {
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .marriage,
            yearFrom: 1945, yearTo: 1945, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: nil,
                spouseSurname: "Brown"
            )),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("s_surname=Brown"),
                "FreeBMD marriage must send spouse surname via s_surname; body was \(body)")
    }

    @Test func freeBMDSourceDeathSendsEmptySSurname() async {
        // Deaths overload `s_surname` for age in the response but the query
        // field is unused — must be empty on the wire so FreeBMD doesn't
        // interpret it as a spouse filter.
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .death,
            yearFrom: 1980, yearTo: 1980, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: "Jones",
                spouseSurname: "Brown"
            )),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("s_surname=&") || body.hasSuffix("s_surname="),
                "FreeBMD death must send empty s_surname; body was \(body)")
    }

    // MARK: - FreeBMD s_given (spouse given name) for marriages

    @Test func freeBMDMarriageCarriesSpouseGivenNameOnRecordQuery() {
        let dispatcher = makeDispatcher()
        let subject = subjectWithFullContext(birthYearFrom: 1919, birthYearTo: 1919)
        let queries = freeBMDQueries(dispatcher: dispatcher, subject: subject, recordType: .marriage)
        let spouseGivenNames = queries.compactMap(\.spouseGivenName)
        #expect(!spouseGivenNames.isEmpty)
        #expect(spouseGivenNames.allSatisfy { $0 == "Mary" })
    }

    @Test func freeBMDSourceMarriageSendsSpouseGivenInSGivenField() async {
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .marriage,
            yearFrom: 1945, yearTo: 1945, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: nil,
                spouseSurname: "Brown"
            )),
            strictness: .strict,
            spouseGivenName: "Mary"
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("s_given=Mary"),
                "FreeBMD marriage must send spouse given in s_given; body was \(body)")
    }

    @Test func freeBMDSourceMarriageStripsMultiTokenSpouseGiven() async {
        // Same first-token rule as `given`: FreeBMD's column is first-given
        // only, "Mary Ann" must be truncated to "Mary".
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .marriage,
            yearFrom: 1945, yearTo: 1945, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: nil,
                spouseSurname: "Brown"
            )),
            strictness: .strict,
            spouseGivenName: "Mary Ann"
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("s_given=Mary&") || body.hasSuffix("s_given=Mary"),
                "FreeBMD spouse given must be first-token only; body was \(body)")
    }

    @Test func freeBMDSourceBirthDoesNotSendSpouseGiven() async {
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .birth,
            yearFrom: 1920, yearTo: 1920, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false,
                motherSurname: "Jones",
                spouseSurname: nil
            )),
            strictness: .strict,
            spouseGivenName: "Mary"
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        // s_given must be empty for non-marriages so we don't accidentally
        // filter on a spouse who doesn't apply to the record type.
        #expect(body.contains("s_given=&") || body.hasSuffix("s_given="),
                "FreeBMD non-marriage must send empty s_given; body was \(body)")
    }

    // MARK: - FreeCen sex + birth year range

    @Test func freeCenSourceMaleSendsSexM() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .census,
            yearFrom: 1881, yearTo: 1881, gender: .male, region: nil,
            sourceParams: .freeCen(FreeCenParams(chapmanCode: "DBY", censusYear: 1881, birthYearRange: nil)),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query%5Bsex%5D=M") || body.contains("search_query[sex]=M"),
                "FreeCen male subject must send sex=M; body was \(body)")
    }

    @Test func freeCenSourceFemaleSendsSexF() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "Jane",
            recordType: .census,
            yearFrom: 1881, yearTo: 1881, gender: .female, region: nil,
            sourceParams: .freeCen(FreeCenParams(chapmanCode: "DBY", censusYear: 1881, birthYearRange: nil)),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query%5Bsex%5D=F") || body.contains("search_query[sex]=F"),
                "FreeCen female subject must send sex=F; body was \(body)")
    }

    @Test func freeCenSourceUnknownGenderSendsEmptySex() async {
        // .other / .unknown / nil must not filter — we don't want to drop
        // legitimate matches just because the subject's gender wasn't
        // recorded on the profile.
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "Pat",
            recordType: .census,
            yearFrom: 1881, yearTo: 1881, gender: nil, region: nil,
            sourceParams: .freeCen(FreeCenParams(chapmanCode: "DBY", censusYear: 1881, birthYearRange: nil)),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("search_query%5Bsex%5D=&") || body.contains("search_query[sex]=&")
                || body.hasSuffix("search_query%5Bsex%5D=") || body.hasSuffix("search_query[sex]="),
                "FreeCen unknown-gender subject must send empty sex; body was \(body)")
    }

    @Test func freeCenSourceWiresBirthYearRangeToStartEndYear() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .census,
            yearFrom: 1881, yearTo: 1881, gender: .male, region: nil,
            sourceParams: .freeCen(FreeCenParams(
                chapmanCode: "DBY",
                censusYear: 1881,
                birthYearRange: 1840...1845
            )),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("start_year%5D=1840") || body.contains("[start_year]=1840"),
                "FreeCen birth range lower bound must reach start_year; body was \(body)")
        #expect(body.contains("end_year%5D=1845") || body.contains("[end_year]=1845"),
                "FreeCen birth range upper bound must reach end_year; body was \(body)")
    }

    @Test func freeCenSourceOmitsStartEndYearWhenNoBirthYearRange() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .census,
            yearFrom: 1881, yearTo: 1881, gender: .male, region: nil,
            sourceParams: .freeCen(FreeCenParams(chapmanCode: "DBY", censusYear: 1881, birthYearRange: nil)),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("start_year%5D=&") || body.contains("[start_year]=&")
                || body.hasSuffix("start_year%5D=") || body.hasSuffix("[start_year]="),
                "FreeCen without birth range must send empty start_year; body was \(body)")
    }

    // MARK: - FindAGrave location dispatch

    @Test func findAGravePopulatesLocationFromDeathLocation() {
        let dispatcher = makeDispatcher()
        var subject = subjectWithFullContext(birthYearFrom: 1919, birthYearTo: 1919)
        subject.deathYearFrom = 2010
        subject.deathYearTo = 2010
        subject.deathLocation = "Chesterfield, Derbyshire"
        subject.region = .county("Loscoe")
        let queries = findAGraveQueries(dispatcher: dispatcher, subject: subject)
        guard let first = queries.first,
              case .findAGrave(let params) = first.sourceParams else {
            Issue.record("Expected single FAG query with FindAGraveParams")
            return
        }
        #expect(params.location == "Chesterfield, Derbyshire")
    }

    @Test func findAGraveFallsBackToRegionWhenDeathLocationNil() {
        let dispatcher = makeDispatcher()
        var subject = subjectWithFullContext(birthYearFrom: 1919, birthYearTo: 1919)
        subject.deathYearFrom = 2010
        subject.deathYearTo = 2010
        subject.deathLocation = nil
        subject.region = .county("Derbyshire")
        let queries = findAGraveQueries(dispatcher: dispatcher, subject: subject)
        guard let first = queries.first,
              case .findAGrave(let params) = first.sourceParams else {
            Issue.record("Expected FindAGraveParams")
            return
        }
        #expect(params.location == "Derbyshire")
    }

    @Test func findAGraveLocationNilWhenNoSubjectLocation() {
        let dispatcher = makeDispatcher()
        var subject = subjectWithFullContext(birthYearFrom: 1919, birthYearTo: 1919)
        subject.deathYearFrom = 2010
        subject.deathYearTo = 2010
        subject.deathLocation = nil
        subject.region = nil
        let queries = findAGraveQueries(dispatcher: dispatcher, subject: subject)
        guard let first = queries.first,
              case .findAGrave(let params) = first.sourceParams else {
            Issue.record("Expected FindAGraveParams")
            return
        }
        #expect(params.location == nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeDispatcher() -> SearchDispatcher {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)
        return SearchDispatcher(registry: registry)
    }

    private func subjectWithMotherSurname(
        _ motherSurname: String,
        birthYearFrom: Int,
        birthYearTo: Int
    ) -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Smith",
            givenName: "John",
            birthYearFrom: birthYearFrom,
            birthYearTo: birthYearTo,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: .male,
            region: nil,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: nil,
                spouseSurname: nil,
                spouseGivenName: nil,
                spouseFatherSurname: nil,
                childNames: [],
                fatherName: nil,
                fatherSurname: nil,
                fatherGivenName: nil,
                motherName: nil,
                motherSurname: motherSurname,
                motherGivenName: nil
            ),
            homeChapmanCode: "DBY"
        )
    }

    private func subjectWithFullContext(
        birthYearFrom: Int,
        birthYearTo: Int
    ) -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Smith",
            givenName: "John",
            birthYearFrom: birthYearFrom,
            birthYearTo: birthYearTo,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: .male,
            region: nil,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: "Mary Wheeldon",
                spouseSurname: "Wheeldon",
                spouseGivenName: "Mary",
                spouseFatherSurname: nil,
                childNames: [],
                fatherName: nil,
                fatherSurname: "Smith",
                fatherGivenName: "Henry",
                motherName: nil,
                motherSurname: "Ward",
                motherGivenName: "Eliza"
            ),
            homeChapmanCode: "DBY"
        )
    }

    /// Models Ernest Cauldwell's wife import shape: she's recorded
    /// under her married surname (spouseSurname) but her maiden surname
    /// is recoverable via her own father on the tree (spouseFatherSurname).
    /// Pass nil for `spouseFatherSurname` to model "no spouse father
    /// known" (wife is a leaf node on the tree with no parents).
    private func subjectWithInvertedWife(
        spouseSurname: String?,
        spouseFatherSurname: String?,
        birthYearFrom: Int,
        birthYearTo: Int
    ) -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell",
            givenName: "Ernest",
            birthYearFrom: birthYearFrom,
            birthYearTo: birthYearTo,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: .male,
            region: nil,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: spouseSurname.map { "Sarah \($0)" },
                spouseSurname: spouseSurname,
                spouseGivenName: "Sarah",
                spouseFatherSurname: spouseFatherSurname,
                childNames: [],
                fatherName: nil,
                fatherSurname: "Cauldwell",
                fatherGivenName: "John",
                motherName: nil,
                motherSurname: nil,
                motherGivenName: nil
            ),
            homeChapmanCode: "DBY"
        )
    }

    @MainActor
    private func freeBMDQueries(
        dispatcher: SearchDispatcher,
        subject: ResearchSubject,
        recordType: RecordType
    ) -> [RecordQuery] {
        guard let source = dispatcher.registry.allSources().first(where: { $0.sourceID == "freebmd" }) else {
            return []
        }
        // Pinned to the district-loop path (gate off): these tests verify
        // SPOUSE-AXIS arithmetic, whose expected counts are derived from
        // district codes. The FT-01 county default is covered separately
        // (freeBMDMarriageFanOutUnderCountyQuery + FreeBMDQueryShapeTests).
        return dispatcher.buildQueriesForTest(
            source: source, subject: subject, recordType: recordType,
            scope: .county, freeBMDCountyQueriesEnabled: false
        )
    }

    @MainActor
    @Test func freeBMDMarriageFanOutUnderCountyQuery() {
        // FT-01 gate ON: the spouse-surname fan-out must survive the
        // county-level geo axis — two spouse axes × one county query.
        let dispatcher = makeDispatcher()
        let subject = subjectWithInvertedWife(
            spouseSurname: "Cauldwell",
            spouseFatherSurname: "Wheeldon",
            birthYearFrom: 1887,
            birthYearTo: 1887
        )
        guard let source = dispatcher.registry.allSources().first(where: { $0.sourceID == "freebmd" }) else {
            Issue.record("freebmd not registered"); return
        }
        let queries = dispatcher.buildQueriesForTest(
            source: source, subject: subject, recordType: .marriage, scope: .county
        )
        #expect(queries.count == 2, "two spouse axes × one county query; got \(queries.count)")
        for q in queries {
            guard case .freeBMD(let params) = q.sourceParams else {
                Issue.record("expected .freeBMD params"); continue
            }
            #expect(params.countyCode == RegionConfig.freeBMDCountyID(forChapmanCode: "DBY"))
            #expect(params.districtCode == nil)
        }
        let spouseSurnames = Set(queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.spouseSurname }
            return nil
        })
        #expect(spouseSurnames == Set(["Cauldwell", "Wheeldon"]),
                "fan-out must probe recorded + maiden spouse surnames; got \(spouseSurnames)")
    }

    /// Kenneth-class: birth county known (Derbyshire via Loscoe), death place
    /// unknown, no death-year window.
    private func subjectDerbyshireNoDeathPlace() -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell",
            givenName: "Kenneth Howard",
            birthYearFrom: 1917,
            birthYearTo: 1917,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: .male,
            region: .county("Derbyshire"),
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: nil,
                spouseSurname: nil,
                spouseGivenName: nil,
                spouseFatherSurname: nil,
                childNames: [],
                fatherName: nil,
                fatherSurname: nil,
                fatherGivenName: nil,
                motherName: nil,
                motherSurname: nil,
                motherGivenName: nil
            ),
            homeChapmanCode: "DBY"
        )
    }

    @MainActor
    @Test func familySearchDeathAxisFallsBackToHomeRegionWhenDeathPlaceUnknown() {
        // With death place AND death year both unknown, the FS death/burial
        // query would otherwise carry no place or date axis and degenerate to
        // "any same-named persona" — FS fills the fetched page with census,
        // burying the real funeral notice. The home county (Derbyshire, from
        // the birth location) is a soft `q.deathLikePlace` re-rank so local
        // deaths surface. Non-death axes must NOT be biased toward it.
        let dispatcher = makeDispatcher()
        let subject = subjectDerbyshireNoDeathPlace()
        guard let fs = dispatcher.registry.allSources().first(where: { $0.sourceID == "familysearch" }) else {
            Issue.record("familysearch not registered"); return
        }
        let deathQueries = dispatcher.buildQueriesForTest(
            source: fs, subject: subject, recordType: .death, scope: .county
        )
        #expect(!deathQueries.isEmpty)
        #expect(deathQueries.allSatisfy { $0.deathPlace == "Derbyshire" },
                "death axis must fall back deathPlace to home county; got \(deathQueries.map { $0.deathPlace ?? "nil" })")

        let burialQueries = dispatcher.buildQueriesForTest(
            source: fs, subject: subject, recordType: .burial, scope: .county
        )
        #expect(burialQueries.allSatisfy { $0.deathPlace == "Derbyshire" },
                "burial axis must also fall back; got \(burialQueries.map { $0.deathPlace ?? "nil" })")

        let birthQueries = dispatcher.buildQueriesForTest(
            source: fs, subject: subject, recordType: .birth, scope: .county
        )
        #expect(birthQueries.allSatisfy { $0.deathPlace == nil },
                "birth axis must not be biased toward the death county; got \(birthQueries.map { $0.deathPlace ?? "nil" })")
    }

    @MainActor
    @Test func familySearchDeathAxisPrefersKnownDeathPlaceOverRegionFallback() {
        // A known death location wins over the region fallback.
        let dispatcher = makeDispatcher()
        var subject = subjectDerbyshireNoDeathPlace()
        subject.deathLocation = "Heanor, Derbyshire, England"
        guard let fs = dispatcher.registry.allSources().first(where: { $0.sourceID == "familysearch" }) else {
            Issue.record("familysearch not registered"); return
        }
        let deathQueries = dispatcher.buildQueriesForTest(
            source: fs, subject: subject, recordType: .death, scope: .county
        )
        #expect(deathQueries.allSatisfy { $0.deathPlace == "Heanor, Derbyshire, England" },
                "known death place must win; got \(deathQueries.map { $0.deathPlace ?? "nil" })")
    }

    /// George-class: full family context (spouse + parents) so the family-axis
    /// gating matrix is observable per record type.
    private func subjectWithFullFSContext() -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell",
            givenName: "George Eric Vaughn",
            birthYearFrom: 1915,
            birthYearTo: 1915,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: .male,
            region: .county("Derbyshire"),
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: "Kathleen Wheeldon",
                spouseSurname: "Wheeldon",
                spouseGivenName: "Kathleen",
                spouseFatherSurname: nil,
                childNames: [],
                fatherName: "Ernest Cauldwell",
                fatherSurname: "Cauldwell",
                fatherGivenName: "Ernest",
                motherName: "Mary Ward",
                motherSurname: "Ward",
                motherGivenName: "Mary"
            ),
            homeChapmanCode: "DBY"
        )
    }

    @MainActor
    @Test func familySearchFamilyAxesAreGatedByRecordType() {
        // Family axes ride only the record kinds that carry them. UK civil
        // death/burial/probate records are parent-less — parent axes on a
        // death query boost christenings/censuses and bury the actual death
        // registration (George Eric Vaughn Cauldwell's 1986 DeathRegistration:
        // #1 without parent axes, ABSENT from the top-100 with them). Spouse
        // rides marriage/census/death-shape; never birth-shape or parish.
        let dispatcher = makeDispatcher()
        let subject = subjectWithFullFSContext()
        guard let fs = dispatcher.registry.allSources().first(where: { $0.sourceID == "familysearch" }) else {
            Issue.record("familysearch not registered"); return
        }
        func first(_ rt: RecordType) -> RecordQuery? {
            dispatcher.buildQueriesForTest(source: fs, subject: subject, recordType: rt, scope: .county).first
        }
        // Death: spouse yes, parents no.
        if let d = first(.death) {
            #expect(d.spouseSurname == "Wheeldon")
            #expect(d.fatherSurname == nil, "death query must not carry parent axes; got \(d.fatherSurname ?? "nil")")
            #expect(d.motherSurname == nil)
        } else { Issue.record("no death query produced") }
        // Probate: same death-shape gating.
        if let p = first(.probate) {
            #expect(p.spouseSurname == "Wheeldon")
            #expect(p.fatherSurname == nil)
            #expect(p.motherSurname == nil)
        } else { Issue.record("no probate query produced") }
        // Birth: parents yes, spouse no.
        if let b = first(.birth) {
            #expect(b.fatherSurname == "Cauldwell")
            #expect(b.motherSurname == "Ward")
            #expect(b.spouseSurname == nil, "birth query must not carry spouse axes; got \(b.spouseSurname ?? "nil")")
        } else { Issue.record("no birth query produced") }
        // Census: both (household carries parents and spouse).
        if let c = first(.census) {
            #expect(c.fatherSurname == "Cauldwell")
            #expect(c.spouseSurname == "Wheeldon")
        } else { Issue.record("no census query produced") }
        // Marriage: spouse yes, parents no (civil marriage indexes are parent-less).
        if let m = first(.marriage) {
            #expect(m.spouseSurname == "Wheeldon")
            #expect(m.fatherSurname == nil)
        } else { Issue.record("no marriage query produced") }
        // Parish (christening-shape): parents yes, spouse no.
        if let pa = first(.parish) {
            #expect(pa.fatherSurname == "Cauldwell")
            #expect(pa.spouseSurname == nil)
        } else { Issue.record("no parish query produced") }
    }

    @MainActor
    @Test func familySearchPlaceAxesAreGatedByRecordType() {
        // Each place axis rides only its own record type. A death search must
        // NOT carry birthPlace/residencePlace — those describe census personas
        // and, sent on a death query, rank census above the real death record
        // (this is what buried Kenneth's 2007 funeral notice). anyPlace (soft
        // country) and the person axes still apply broadly.
        let dispatcher = makeDispatcher()
        let subject = subjectDerbyshireNoDeathPlace()
        guard let fs = dispatcher.registry.allSources().first(where: { $0.sourceID == "familysearch" }) else {
            Issue.record("familysearch not registered"); return
        }
        func first(_ rt: RecordType) -> RecordQuery? {
            dispatcher.buildQueriesForTest(source: fs, subject: subject, recordType: rt, scope: .county).first
        }
        // Death: deathPlace present (home-region fallback); birth/residence absent.
        if let d = first(.death) {
            #expect(d.deathPlace == "Derbyshire")
            #expect(d.birthPlace == nil, "death search must not carry birthPlace; got \(d.birthPlace ?? "nil")")
            #expect(d.residencePlace == nil, "death search must not carry residencePlace; got \(d.residencePlace ?? "nil")")
        } else { Issue.record("no death query produced") }
        // Birth: birthPlace present; death/residence absent.
        if let b = first(.birth) {
            #expect(b.birthPlace == "Derbyshire")
            #expect(b.deathPlace == nil, "birth search must not carry deathPlace; got \(b.deathPlace ?? "nil")")
            #expect(b.residencePlace == nil)
        } else { Issue.record("no birth query produced") }
        // Census: residencePlace present; birth/death absent.
        if let c = first(.census) {
            #expect(c.residencePlace == "Derbyshire")
            #expect(c.birthPlace == nil, "census search must not carry birthPlace; got \(c.birthPlace ?? "nil")")
            #expect(c.deathPlace == nil, "census search must not carry deathPlace; got \(c.deathPlace ?? "nil")")
        } else { Issue.record("no census query produced") }
    }

    @MainActor
    private func findAGraveQueries(
        dispatcher: SearchDispatcher,
        subject: ResearchSubject
    ) -> [RecordQuery] {
        guard let source = dispatcher.registry.allSources().first(where: { $0.sourceID == "findagrave" }) else {
            return []
        }
        return dispatcher.buildQueriesForTest(source: source, subject: subject, recordType: .death, scope: .county)
    }
}
