import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the dispatcher-side family-context axis plumbing for FreeBMD and
/// FindAGrave, plus FreeBMD's source-side `s_surname` overload for births
/// (MMN) vs marriages (spouse). Spec §23 — every known fact reaches every
/// source that can use it.
@MainActor
struct FamilyContextAxisDispatchTests {

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
        return dispatcher.buildQueriesForTest(source: source, subject: subject, recordType: recordType, scope: .county)
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
