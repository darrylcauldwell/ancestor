import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// FamilySearch client — Slice 5. The records `RecordSource`: query mapping
/// (RecordQuery → q.*/f.*), the GEDCOM X → SourceRecord parser (ported from the
/// proven cookie plugin, re-pointed at the FS* model), the truncation rule, and
/// the no-network flow branches. All pure/hermetic. `@MainActor` so the actor's
/// MainActor-isolated init (as constructed by `bootstrapSources`) is callable.
@MainActor
struct FamilySearchSourceTests {

    private func query(
        recordType: RecordType = .birth,
        surname: String? = "Cauldwell",
        given: String? = "Ernest",
        from: Int? = nil, to: Int? = nil,
        strictness: SearchStrictness = .strict,
        gender: Gender? = nil,
        spouseSurname: String? = nil
    ) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: given, recordType: recordType,
            yearFrom: from, yearTo: to, gender: gender, region: nil,
            sourceParams: .generic, strictness: strictness,
            spouseSurname: spouseSurname)
    }

    private func feed(_ json: String) throws -> RecordsSearchFeed {
        try JSONDecoder().decode(RecordsSearchFeed.self, from: Data(json.utf8))
    }

    // MARK: makeQuery

    @Test func birthQueryPinsBirthDateRangeAndStrictSurnameAndFullPage() {
        let q = FamilySearchSource.makeQuery(from: query(recordType: .birth, from: 1885, to: 1889), surname: "Cauldwell")
        let items = Dictionary(grouping: q.queryItems(), by: \.name).mapValues { $0.compactMap(\.value) }
        #expect(items["q.birthLikeDate.from"] == ["1885"])
        #expect(items["q.birthLikeDate.to"] == ["1889"])
        #expect(items["q.surname.exact"] == ["on"])       // strict → opt out of Soundex
        #expect(items["count"] == ["100"])                // full page
    }

    @Test func wideDeathWindowOmitsDeathDateAxis() {
        // A birth-derived guess (span > 15y) must NOT pin q.deathLikeDate.
        let wide = FamilySearchSource.makeQuery(from: query(recordType: .death, from: 1850, to: 1930), surname: "Cauldwell")
        #expect(wide.deathDateRange == nil)
        // A narrow known-death window does pin it.
        let narrow = FamilySearchSource.makeQuery(from: query(recordType: .death, from: 1960, to: 1963), surname: "Cauldwell")
        #expect(narrow.deathDateRange == 1960...1963)
    }

    @Test func looseStrictnessDropsExactSurname() {
        let q = FamilySearchSource.makeQuery(from: query(strictness: .loose), surname: "Cauldwell")
        #expect(q.surnameExact == false)
    }

    @Test func familyContextAxesPassThrough() {
        let q = FamilySearchSource.makeQuery(from: query(recordType: .marriage, spouseSurname: "Marshall"), surname: "Cauldwell")
        #expect(q.spouseSurname == "Marshall")
    }

    // MARK: parseSearchFeed

    @Test func parsesBirthPersonaIntoBirthRecordWithArkAndTotal() throws {
        let f = try feed(#"""
        { "results": 21047, "entries": [ { "score": 9.0, "content": { "gedcomx": {
            "persons": [ { "id": "p_1", "principal": true,
              "names": [ { "nameForms": [ { "fullText": "Ernest Cauldwell", "parts": [
                { "type": "http://gedcomx.org/Given", "value": "Ernest" },
                { "type": "http://gedcomx.org/Surname", "value": "Cauldwell" } ] } ] } ],
              "gender": { "type": "http://gedcomx.org/Male" },
              "facts": [ { "type": "http://gedcomx.org/Birth", "date": { "original": "1887", "formal": "+1887" },
                           "place": { "original": "Derbyshire, England" } } ] } ],
            "sourceDescriptions": [ { "about": "ark:/61903/1:1:XYZ", "titles": [ { "value": "England Births 1887" } ],
                                      "coverage": [ { "completeness": 0.9 } ] } ]
        } } } ] }
        """#)
        let parsed = FamilySearchSource.parseSearchFeed(f, query: query(recordType: .birth))
        #expect(parsed.totalAvailable == 21047)
        #expect(parsed.records.count == 1)
        let record = try #require(parsed.records.first)
        #expect(record.recordType == .birth)
        #expect(record.common.name == "Ernest Cauldwell")
        #expect(record.common.surname == "Cauldwell")
        #expect(record.common.detailURL == "https://www.familysearch.org/ark:/61903/1:1:p_1")
        #expect(record.common.rawFields["collection.title"] == "England Births 1887")
        guard case .birth(let birth) = record else { Issue.record("expected .birth"); return }
        #expect(birth.birthYear == 1887)
        #expect(birth.birthPlace == "Derbyshire, England")
    }

    @Test func strictSurnameGuardRejectsNonMatchingPersonas() throws {
        let f = try feed(#"""
        { "results": 5, "entries": [ { "content": { "gedcomx": {
            "persons": [ { "id": "s1", "names": [ { "nameForms": [ { "fullText": "John Smith", "parts": [
                { "type": "http://gedcomx.org/Surname", "value": "Smith" } ] } ] } ],
              "facts": [ { "type": "http://gedcomx.org/Birth", "date": { "formal": "+1887" } } ] } ]
        } } } ] }
        """#)
        // Query wants Cauldwell (strict) — a Smith persona is not a candidate.
        let parsed = FamilySearchSource.parseSearchFeed(f, query: query(recordType: .birth, surname: "Cauldwell"))
        #expect(parsed.records.isEmpty)
    }

    @Test func parsesCensusHouseholdWithAgeDerivedBirthYear() throws {
        let f = try feed(#"""
        { "results": 1, "entries": [ { "content": { "gedcomx": {
            "persons": [
              { "id": "head", "principal": true,
                "names": [ { "nameForms": [ { "fullText": "John Smith", "parts": [
                  { "type": "http://gedcomx.org/Surname", "value": "Smith" } ] } ] } ],
                "facts": [ { "type": "http://gedcomx.org/Census", "date": { "formal": "+1911" } } ],
                "fields": [ { "type": "http://gedcomx.org/Age", "values": [ { "type": "http://gedcomx.org/Interpreted", "text": "34" } ] } ] },
              { "id": "wife", "names": [ { "nameForms": [ { "fullText": "Mary Smith" } ] } ],
                "gender": { "type": "http://gedcomx.org/Female" },
                "fields": [ { "type": "http://gedcomx.org/Age", "values": [ { "text": "32" } ] } ] }
            ],
            "relationships": [ { "type": "http://gedcomx.org/Couple",
                                 "person1": { "resourceId": "head" }, "person2": { "resourceId": "wife" } } ],
            "sourceDescriptions": [ { "titles": [ { "value": "1911 Census" } ] } ]
        } } } ] }
        """#)
        let parsed = FamilySearchSource.parseSearchFeed(f, query: query(recordType: .census, surname: "Smith"))
        let head = try #require(parsed.records.first)
        guard case .census(let census) = head else { Issue.record("expected .census"); return }
        #expect(census.censusYear == 1911)
        #expect(census.age == 34)
        #expect(census.birthYear == 1877)   // age-derived (1911 − 34)
        #expect(census.household?.contains(where: { $0.name == "Mary Smith" }) == true)
    }

    // MARK: truncation

    @Test func truncationRule() {
        #expect(FamilySearchSource.isTruncated(entryCount: 1, totalAvailable: 21047))   // partial page of many
        #expect(FamilySearchSource.isTruncated(entryCount: 100, totalAvailable: nil))    // full page, no claimed total
        #expect(!FamilySearchSource.isTruncated(entryCount: 5, totalAvailable: 5))       // complete
    }

    // MARK: flow branches (no network)

    @Test func requiresAuthWhenNotSignedIn() async {
        let client = FamilySearchClient(environment: .beta, tokenSource: StubTokenSource(bearer: nil), sleeper: { _ in })
        let source = FamilySearchSource(client: client, environment: .beta)
        let result = await source.search(query(recordType: .birth, from: 1885, to: 1889))
        guard case .requiresAuth = result else { Issue.record("expected .requiresAuth, got \(result)"); return }
    }

    @Test func outsideCoverageForUnsupportedRecordType() async {
        let client = FamilySearchClient(environment: .beta, tokenSource: StubTokenSource(bearer: "T"), sleeper: { _ in })
        let source = FamilySearchSource(client: client, environment: .beta)
        let result = await source.search(query(recordType: .pedigree))
        guard case .outsideCoverage = result else { Issue.record("expected .outsideCoverage"); return }
    }

    @Test func emptySurnameReturnsEmptyResults() async {
        let client = FamilySearchClient(environment: .beta, tokenSource: StubTokenSource(bearer: "T"), sleeper: { _ in })
        let source = FamilySearchSource(client: client, environment: .beta)
        let result = await source.search(query(surname: nil))
        #expect(result.records.isEmpty)
        guard case .results = result else { Issue.record("expected .results([])"); return }
    }

    // Regression: not signed in must publish a red-cross `sourceError` (so a
    // run doesn't end with FamilySearch wearing a green tick / "no results").
    // The 401/403 branch already did this; the no-token branch used to return
    // requiresAuth silently, leaking the in-flight count and settling green.
    @Test func notSignedInPublishesSourceErrorTellingUserToSignIn() async {
        let collector = FSEventCollector()
        let stream = await ResearchActivityBus.shared.subscribe()
        let task = Task { for await event in stream { await collector.record(event) } }
        defer { task.cancel() }
        await Task.yield()

        let client = FamilySearchClient(environment: .beta, tokenSource: StubTokenSource(bearer: nil), sleeper: { _ in })
        let source = FamilySearchSource(client: client, environment: .beta)
        let envelope = await source.searchWithOutcome(query(recordType: .birth, from: 1885, to: 1889))

        #expect(envelope.outcome.availability == .requiresAuth)

        // Poll (bounded) so the background collector can drain the fan-out —
        // a single yield races the actor and flakes under the batch runner.
        var signInError = false
        for _ in 0..<200 {
            if await collector.hasSignInError { signInError = true; break }
            await Task.yield()
        }
        let seenEvents = await collector.events
        #expect(signInError,
                "a not-signed-in FamilySearch must publish a sourceError telling the user to sign in — got \(seenEvents)")
    }
}

/// Collects `ResearchActivityBus` events for assertions.
private actor FSEventCollector {
    private(set) var events: [ResearchActivityEvent] = []
    func record(_ event: ResearchActivityEvent) { events.append(event) }

    /// True once a FamilySearch `sourceError` asking the user to sign in has
    /// been observed.
    var hasSignInError: Bool {
        events.contains { event in
            if case let .sourceError(sourceID, _, reason, _) = event {
                return sourceID == "familysearch" && reason.lowercased().contains("sign in")
            }
            return false
        }
    }
}

/// Minimal token source for the no-network flow tests.
private struct StubTokenSource: FamilySearchTokenSource {
    let bearer: String?
    func currentBearer() async -> String? { bearer }
    func refreshBearer() async -> String? { nil }
}
