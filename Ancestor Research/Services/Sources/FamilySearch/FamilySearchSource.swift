import Foundation
import AncestorKit
import os

/// FamilySearch historical-records source over the official OAuth Platform API
/// (`GET /platform/records/personas`). 2000+ collections — parish registers,
/// civil registration, censuses (UK + global), military, probate.
///
/// Transport is `FamilySearchClient` (OAuth2 bearer, 429/301/410 handling); the
/// GEDCOM X → `SourceRecord` parser is the transport-agnostic logic from the
/// retired cookie plugin (`git 9facbc1`), re-pointed at the `FS*` model. Two
/// spec-correctness fixes over the cookie original: the place-authority ARK is
/// read from `place.description` (GEDCOM X §3.17, not `normalized[].description`)
/// and the exact-surname opt-out uses the documented `q.surname.exact=on`
/// modifier (Record Persona Search resource) rather than the cookie endpoint's
/// `~` suffix.
///
/// **§16 pointer-only:** the pipeline scores full search responses in memory,
/// but persistence keeps pointers (ARKs) + our derived conclusions only, never
/// record content/images — enforced downstream by the evidence layer. Beta
/// (non-production) under the Innovator Solution Provider agreement.
actor FamilySearchSource: RecordSource {

    // MARK: - RecordSource metadata

    nonisolated let sourceID = "familysearch"
    nonisolated let displayName = "FamilySearch"
    nonisolated let descriptiveName = "FamilySearch historical records"
    /// FS place params are documented single-value fuzzy matches within three
    /// jurisdiction levels — no multi-county OR — so `.adjacent` collapses to
    /// `.county` (SOURCE_WEIGHTING Change 4; scope steers the place-axis level).
    nonisolated let scopeHandling: ScopeHandling = .scoped
    nonisolated let recordTypes: Set<RecordType> = [
        .birth, .death, .marriage, .census, .burial,
        .military, .probate, .baptism, .christening, .parish,
    ]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales, .scotland, .ireland, .commonwealthMilitary]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "various")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(
        level: .restricted,
        summary: "Official API (OAuth2 + PKCE); Beta (non-production) under the Innovator Solution Provider agreement; §16 pointer-only persistence"
    )

    // MARK: - Constants

    /// Documented hard max per page (Record Persona Search: count 1–100).
    /// Shared by the query builder and the truncation rule.
    nonisolated static let pageSize = 100
    /// Above this span (years) a death/burial window is a birth-derived guess,
    /// not a known death year; a wide guess must not pin `q.deathLikeDate` or FS
    /// excludes Funeral-Notice personas (a Funeral fact, not a Death fact).
    nonisolated static let deathDateWindowThreshold = 15
    nonisolated private static let arkBase = "https://www.familysearch.org/ark:/61903/1:1:"

    // MARK: - State

    private let environment: FamilySearchEnvironment
    private let client: FamilySearchClient
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FamilySearch")

    init(environment: FamilySearchEnvironment = .beta) {
        self.environment = environment
        self.client = FamilySearchClient(
            environment: environment,
            tokenSource: KeychainFamilySearchTokenSource(environment: environment))
    }

    /// Injectable init for tests (mock client).
    init(client: FamilySearchClient, environment: FamilySearchEnvironment) {
        self.environment = environment
        self.client = client
    }

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        await searchWithOutcome(query).result
    }

    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        guard recordTypes.contains(query.recordType) else {
            return SourceSearchEnvelope(.outsideCoverage(reason: "FamilySearch does not surface \(query.recordType.rawValue) records via this plugin"))
        }
        guard let surname = query.surname, !surname.isEmpty else {
            return SourceSearchEnvelope(.results([]))
        }

        let summary = Self.activitySummary(query: query, surname: surname)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        let fsQuery = Self.makeQuery(from: query, surname: surname)
        let url = FamilySearchEndpoints.recordsPersonaSearch(environment, fsQuery)

        do {
            let response = try await client.execute(FamilySearchRequest(url: url, accept: .gedcomxAtom))
            switch response.statusCode {
            case 200:
                guard let feed = try? response.decode(RecordsSearchFeed.self) else {
                    await publishError(summary, "unparseable response", query.strictness)
                    return SourceSearchEnvelope(
                        result: .unavailable(reason: "unparseable response"),
                        outcome: SearchOutcome(resultCount: 0, availability: .error(reason: "unparseable response")))
                }
                let parsed = Self.parseSearchFeed(feed, query: query)
                let truncated = Self.isTruncated(entryCount: parsed.entryCount, totalAvailable: parsed.totalAvailable)
                logger.info("\(summary, privacy: .public) → \(parsed.records.count) records (total \(parsed.totalAvailable.map(String.init) ?? "?", privacy: .public)\(truncated ? ", truncated" : ""))")
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: parsed.records.count, strictness: query.strictness))
                return SourceSearchEnvelope(
                    result: .results(parsed.records),
                    outcome: SearchOutcome(resultCount: parsed.records.count, totalAvailable: parsed.totalAvailable, truncated: truncated))

            case 204:
                // Clean negative — the search ran and found nothing.
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: 0, strictness: query.strictness))
                return SourceSearchEnvelope(.results([]))

            case 401, 403:
                await publishError(summary, "Sign in to FamilySearch in Settings to get records from this source (session expired or no records access)", query.strictness)
                return SourceSearchEnvelope(
                    result: .requiresAuth(message: "FamilySearch access unavailable (HTTP \(response.statusCode)) — re-authenticate in Settings, or this key's tier lacks records access"),
                    outcome: SearchOutcome(resultCount: 0, availability: .requiresAuth))

            case 429:
                await publishError(summary, "throttled", query.strictness)
                return SourceSearchEnvelope(
                    result: .unavailable(reason: "throttled"),
                    outcome: SearchOutcome(resultCount: 0, availability: .throttled))

            default:
                await publishError(summary, "HTTP \(response.statusCode)", query.strictness)
                return SourceSearchEnvelope(
                    result: .unavailable(reason: "HTTP \(response.statusCode)"),
                    outcome: SearchOutcome(resultCount: 0, availability: .error(reason: "HTTP \(response.statusCode)")))
            }
        } catch FamilySearchClientError.notAuthenticated {
            // Not signed in at all — surface a red-cross source error (not a
            // silent zero-result), so the run doesn't end with FamilySearch
            // wearing a green tick when the user simply hasn't connected it.
            await publishError(summary, "Sign in to FamilySearch in Settings to get records from this source", query.strictness)
            return SourceSearchEnvelope(
                result: .requiresAuth(message: "Sign in to FamilySearch in Settings to enable this source"),
                outcome: SearchOutcome(resultCount: 0, availability: .requiresAuth))
        } catch FamilySearchClientError.tooManyThrottleRetries {
            await publishError(summary, "throttled", query.strictness)
            return SourceSearchEnvelope(
                result: .unavailable(reason: "throttled"),
                outcome: SearchOutcome(resultCount: 0, availability: .throttled))
        } catch is CancellationError {
            return SourceSearchEnvelope(.unavailable(reason: "cancelled"))
        } catch {
            await publishError(summary, error.localizedDescription, query.strictness)
            return SourceSearchEnvelope(
                result: .unavailable(reason: error.localizedDescription),
                outcome: SearchOutcome(resultCount: 0, availability: .error(reason: error.localizedDescription)))
        }
    }

    private func publishError(_ summary: String, _ reason: String, _ strictness: SearchStrictness) async {
        logger.warning("\(summary, privacy: .public) failed: \(reason, privacy: .public)")
        await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: reason, strictness: strictness))
    }

    /// A page is truncated when the server claims more hits than the page
    /// carries, or when a full page arrives without a claimed total.
    nonisolated static func isTruncated(entryCount: Int, totalAvailable: Int?) -> Bool {
        if let total = totalAvailable { return total > entryCount }
        return entryCount >= pageSize
    }

    // MARK: - Query construction

    /// Map a `RecordQuery` to a structured `FamilySearchQuery` (the `q.*`/`f.*`
    /// grammar). Record-type steers the date axis; `.strict` opts surname out of
    /// Soundex; family-context axes pass straight through.
    nonisolated static func makeQuery(from query: RecordQuery, surname: String) -> FamilySearchQuery {
        var q = FamilySearchQuery()
        q.surname = surname
        q.surnameExact = (query.strictness == .strict)
        q.givenName = query.givenName
        if let gender = query.gender { q.sex = (gender == .male) ? .male : .female }

        if let from = query.yearFrom, let to = query.yearTo, from <= to {
            switch query.recordType {
            case .birth, .baptism, .christening:
                q.birthDateRange = from...to
            case .death, .burial:
                // Only pin a NARROW (known-death-year) window; a wide
                // birth-derived guess would exclude Funeral-Notice personas.
                if to - from <= deathDateWindowThreshold { q.deathDateRange = from...to }
            case .marriage:
                q.marriageDateRange = from...to
            case .census:
                q.residenceDateRange = from...to
            default:
                q.anyDateRange = from...to
            }
        }

        q.birthPlace = query.birthPlace
        q.deathPlace = query.deathPlace
        q.residencePlace = query.residencePlace
        q.marriagePlace = query.marriagePlace
        q.anyPlace = query.anyPlace
        q.spouseSurname = query.spouseSurname
        q.spouseGivenName = query.spouseGivenName
        q.fatherSurname = query.fatherSurname
        q.fatherGivenName = query.fatherGivenName
        q.motherSurname = query.motherSurname
        q.motherGivenName = query.motherGivenName
        q.count = pageSize
        return q
    }

    nonisolated static func activitySummary(query: RecordQuery, surname: String) -> String {
        let given = query.givenName.flatMap { $0.isEmpty ? nil : $0 } ?? ""
        let person = given.isEmpty ? surname : "\(given) \(surname)"
        let kind = query.recordType.rawValue
        var axes: [String] = []
        if let s = query.spouseSurname, !s.isEmpty { axes.append("spouse=\(s)") }
        if let s = query.fatherSurname, !s.isEmpty { axes.append("father=\(s)") }
        if let s = query.motherSurname, !s.isEmpty { axes.append("mother=\(s)") }
        if let p = query.birthPlace, !p.isEmpty { axes.append("birthPlace=\(p)") }
        if let p = query.deathPlace, !p.isEmpty { axes.append("deathPlace=\(p)") }
        if let g = query.gender { axes.append("sex=\(g == .male ? "M" : "F")") }
        let axisSuffix = axes.isEmpty ? "" : " [\(axes.joined(separator: ", "))]"
        if let from = query.yearFrom, let to = query.yearTo {
            return "FamilySearch \(kind): \(person) \(from)–\(to)\(axisSuffix)"
        }
        return "FamilySearch \(kind): \(person)\(axisSuffix)"
    }
}

// MARK: - GEDCOM X parser (multi-persona, §5.0)

extension FamilySearchSource {

    /// Parse a records-persona search feed into `[SourceRecord]` plus the
    /// envelope's own accounting (`totalAvailable` = the feed's `results`
    /// total; `entryCount` = entries on this page). Every persona in an entry
    /// produces one candidate record.
    /// `extraRawFields` are merged onto every produced record's `rawFields`
    /// (e.g. the enrichment leg stamps `fsTreePersonID` provenance). The
    /// per-entry FS match score is stamped automatically as `fsMatchScore` —
    /// both are §18 lead-ordering/triage signals only, never gate inputs.
    nonisolated static func parseSearchFeed(
        _ feed: RecordsSearchFeed, query: RecordQuery, extraRawFields: [String: String] = [:]
    ) -> (records: [SourceRecord], totalAvailable: Int?, entryCount: Int) {
        let allowed = allowedSurnames(for: query)
        var out: [SourceRecord] = []
        let entries = feed.entries ?? []
        for entry in entries {
            let gx = entry.content?.gedcomx
            guard let persons = gx?.persons, !persons.isEmpty else { continue }
            // Per-entry FS match confidence (§18 ordering signal only).
            let entryScore = entry.score ?? entry.confidence

            let collectionTitle = gx?.sourceDescriptions?.first?.titles?.first?.value ?? ""
            let collectionARK = gx?.sourceDescriptions?.first?.about ?? ""
            let completeness = gx?.sourceDescriptions?.first?.coverage?.first?.completeness

            var idToIndex: [String: Int] = [:]
            for (i, p) in persons.enumerated() { if let id = p.id { idToIndex[id] = i } }
            let householdRoles = deriveHouseholdRoles(persons: persons, relationships: gx?.relationships ?? [], idToIndex: idToIndex)

            for (i, persona) in persons.enumerated() {
                if let allowed {
                    guard let ps = personaSurname(persona), allowed.contains(ps) else { continue }
                }
                guard let record = buildRecord(
                    persona: persona,
                    personaIndex: i,
                    householdRole: householdRoles[persona.id ?? ""],
                    siblingsAndKin: persons.enumerated().compactMap { (j, other) in
                        j == i ? nil : (other, householdRoles[other.id ?? ""])
                    },
                    relationships: gx?.relationships ?? [],
                    collectionTitle: collectionTitle,
                    collectionARK: collectionARK,
                    collectionCompleteness: completeness,
                    entryScore: entryScore,
                    extraRawFields: extraRawFields,
                    queryRecordType: query.recordType
                ) else { continue }
                out.append(record)
            }
        }
        return (out, feed.results, entries.count)
    }

    /// Acceptable surnames (lowercased) for `query`; nil = no filter. `.strict`/
    /// `.variant` = the supplied surname only; `.loose` adds registered
    /// transcription variants (never the server's phonetic long tail).
    nonisolated static func allowedSurnames(for query: RecordQuery) -> Set<String>? {
        guard let want = query.surname?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !want.isEmpty else { return nil }
        switch query.strictness {
        case .strict, .variant:
            return [want]
        case .loose:
            var set: Set<String> = [want]
            for variant in SurnameVariants.shared.variants(of: want) { set.insert(variant) }
            return set
        }
    }

    nonisolated private static func personaSurname(_ persona: FSPerson) -> String? {
        let nameForm = persona.names?.first?.nameForms?.first
        if let surname = nameForm?.parts?.first(where: { ($0.type ?? "").hasSuffix("/Surname") })?.value {
            return surname.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let full = nameForm?.fullText, let last = full.split(separator: " ").last {
            return String(last).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Bare person id for a relationship reference — `resourceId` when present,
    /// else the `resource` URI stripped of a leading `#` or reduced to its last
    /// path segment (the OAuth feed may use `resource` where the cookie feed
    /// used `resourceId`).
    nonisolated private static func refID(_ ref: FSResourceReference?) -> String? {
        if let rid = ref?.resourceId, !rid.isEmpty { return rid }
        guard let resource = ref?.resource, !resource.isEmpty else { return nil }
        if resource.hasPrefix("#") { return String(resource.dropFirst()) }
        return resource.split(separator: "/").last.map(String.init) ?? resource
    }

    nonisolated private static func deriveHouseholdRoles(
        persons: [FSPerson], relationships: [FSRelationship], idToIndex: [String: Int]
    ) -> [String: String] {
        var roles: [String: String] = [:]
        for (i, p) in persons.enumerated() {
            guard let id = p.id else { continue }
            roles[id] = i == 0 ? "principal" : "household_member"
        }
        for rel in relationships {
            let type = rel.type?.split(separator: "/").last.map(String.init) ?? ""
            guard let p1 = refID(rel.person1), let p2 = refID(rel.person2) else { continue }
            switch type {
            case "ParentChild":
                if roles[p1] == "household_member" { roles[p1] = "parent" }
                if roles[p2] == "household_member" { roles[p2] = "child" }
            case "Couple":
                if roles[p1] == "household_member" { roles[p1] = "spouse" }
                if roles[p2] == "household_member" { roles[p2] = "spouse" }
            default:
                break
            }
        }
        return roles
    }

    nonisolated private static func buildRecord(
        persona: FSPerson,
        personaIndex: Int,
        householdRole: String?,
        siblingsAndKin: [(FSPerson, String?)],
        relationships: [FSRelationship],
        collectionTitle: String,
        collectionARK: String,
        collectionCompleteness: Double?,
        entryScore: Double? = nil,
        extraRawFields: [String: String] = [:],
        queryRecordType: RecordType
    ) -> SourceRecord? {
        let nameForm = persona.names?.first?.nameForms?.first
        let fullName = nameForm?.fullText
        let givenName = nameForm?.parts?.first(where: { ($0.type ?? "").hasSuffix("/Given") })?.value
        let surname = nameForm?.parts?.first(where: { ($0.type ?? "").hasSuffix("/Surname") })?.value

        let primaryFact = pickPrimaryFact(facts: persona.facts ?? [], queryHint: queryRecordType)
        let mappedFactType = primaryFact.flatMap { recordType(forGedcomxFact: $0.type ?? "") }
        let recordRecordType = mappedFactType ?? queryRecordType

        var rawFields: [String: String] = [:]
        for fact in persona.facts ?? [] {
            let typeName = fact.type?.split(separator: "/").last.map(String.init) ?? "fact"
            if let date = fact.date?.original { rawFields["fact.\(typeName).date"] = date }
            if let formal = fact.date?.formal { rawFields["fact.\(typeName).date.formal"] = formal }
            if let place = fact.place?.original { rawFields["fact.\(typeName).place"] = place }
            // Place-authority ARK on the place reference itself (GEDCOM X §3.17).
            if let placeARK = fact.place?.description { rawFields["fact.\(typeName).placeARK"] = placeARK }
        }
        for field in persona.fields ?? [] {
            let typeName = field.type?.split(separator: "/").last.map(String.init) ?? "field"
            for value in field.values ?? [] {
                let kind = value.type?.split(separator: "/").last.map(String.init) ?? ""
                if kind == "Original" {
                    rawFields["field.\(typeName).original"] = value.text ?? ""
                } else if kind == "Interpreted" {
                    rawFields["field.\(typeName).interpreted"] = value.text ?? ""
                } else if let v = value.text {
                    rawFields["field.\(typeName)"] = v
                }
            }
        }

        if let personaID = persona.id {
            rawFields["ark"] = "\(arkBase)\(personaID)"
            rawFields["personaID"] = personaID
        }
        rawFields["collection.title"] = collectionTitle
        if !collectionARK.isEmpty { rawFields["collection.ark"] = collectionARK }
        if let c = collectionCompleteness { rawFields["collection.completeness"] = String(c) }
        if mappedFactType == nil, let suffix = primaryFact?.type?.split(separator: "/").last.map(String.init) {
            rawFields["unmappedFactType"] = suffix
        }
        if let role = householdRole { rawFields["household.role"] = role }
        rawFields["primary"] = personaIndex == 0 ? "true" : "false"
        if let principal = persona.principal, principal { rawFields["principal"] = "true" }
        // §18: FS match confidence + tree-person provenance ride in rawFields
        // for lead ordering/triage only — never a gate/tier/verdict input.
        if let entryScore { rawFields["fsMatchScore"] = String(entryScore) }
        for (key, value) in extraRawFields { rawFields[key] = value }

        let recordID = persona.id ?? "fs-\(collectionARK)-\(personaIndex)"
        let detailURL = persona.id.map { "\(arkBase)\($0)" }
        // Bare `ark:/…` path segment only (§17.1), from the place reference.
        let primaryPlaceARK: String? = primaryFact?.place?.description.flatMap { raw in
            guard let r = raw.range(of: "ark:/") else { return nil }
            return String(raw[r.lowerBound...])
        }
        let common = RecordCommon(
            id: recordID,
            sourceID: "familysearch",
            name: fullName,
            surname: surname,
            givenName: givenName,
            detailURL: detailURL,
            rawFields: rawFields,
            placeARK: primaryPlaceARK,
            collectionCompleteness: collectionCompleteness
        )

        let date = primaryFact?.date?.original
        let year = primaryFact?.date?.formal.flatMap(Self.yearFromFormal) ?? date.flatMap(Self.yearFromOriginal)
        let place = primaryFact?.place?.original

        switch recordRecordType {
        case .birth, .baptism, .christening:
            if recordRecordType == .birth {
                let mmn = extractMothersMaidenName(relationships: relationships, personaID: persona.id, allPersons: siblingsAndKin.map(\.0))
                return .birth(BirthRecord(common: common, birthYear: year, birthDate: date, birthPlace: place, mothersMaidenName: mmn))
            } else {
                return .parish(ParishRecord(common: common, eventType: recordRecordType.rawValue, eventDate: date, eventYear: year, parish: place))
            }
        case .death:
            return .death(DeathRecord(common: common, deathYear: year, deathDate: date, deathPlace: place, age: extractAge(rawFields: rawFields)))
        case .burial:
            let memorialID = extractFindAGraveMemorialID(collectionTitle: collectionTitle, rawFields: rawFields)
            let isFagBridge = memorialID != nil
            return .burial(BurialRecord(
                common: common,
                deathDate: isFagBridge ? nil : date,
                deathYear: isFagBridge ? nil : year,
                burialLocation: place,
                memorialID: memorialID,
                isVeteran: false))
        case .marriage:
            let spouseName = extractSpouseName(relationships: relationships, personaID: persona.id, otherPersons: siblingsAndKin.map(\.0))
            return .marriage(MarriageRecord(common: common, marriageYear: year, marriageDate: date, marriagePlace: place, quarter: nil, district: nil, volume: nil, page: nil, spouseName: spouseName))
        case .census:
            let household = siblingsAndKin.map { (other, role) -> HouseholdMember in
                let nm = other.names?.first?.nameForms?.first?.fullText ?? ""
                let ageStr = other.fields?.first(where: { ($0.type ?? "").hasSuffix("/Age") })?.values?.first?.text
                return HouseholdMember(
                    name: nm,
                    relationship: role ?? "household_member",
                    age: ageStr.flatMap(Int.init),
                    sex: other.gender?.type.flatMap { $0.split(separator: "/").last.map(String.init) })
            }
            let birthFact = (persona.facts ?? []).first { fact in
                let typeName = fact.type?.split(separator: "/").last.map(String.init) ?? ""
                return ["Birth", "BirthRegistration", "Christening", "Baptism"].contains(typeName)
            }
            let censusBirthPlace = birthFact?.place?.original
            let censusAge = extractAge(rawFields: rawFields)
            let censusBirthYear = birthFact?.date?.formal.flatMap(Self.yearFromFormal)
                ?? birthFact?.date?.original.flatMap(Self.yearFromOriginal)
                ?? year.flatMap { y in censusAge.map { y - $0 } }
            return .census(CensusRecord(
                common: common,
                censusYear: year ?? 0,
                age: censusAge,
                birthYear: censusBirthYear,
                birthPlace: censusBirthPlace,
                relationship: householdRole,
                occupation: rawFields["fact.Occupation.date"] ?? rawFields["fact.Occupation.place"],
                household: household.isEmpty ? nil : household))
        case .probate:
            return .probate(ProbateRecord(common: common, probateDate: date, ageAtDeath: extractAge(rawFields: rawFields), address: place))
        case .military:
            return .military(MilitaryRecord(common: common, dateOfDeath: date, deathYear: year, age: extractAge(rawFields: rawFields)))
        case .parish:
            return .parish(ParishRecord(common: common, eventType: primaryFact?.type?.split(separator: "/").last.map(String.init), eventDate: date, eventYear: year, parish: place))
        case .pedigree:
            return .pedigree(PedigreeRecord(common: common))
        }
    }

    /// Choose the per-persona primary fact — prefer a fact aligned with the
    /// query's record-type hint; fall back to the first fact. Mirrored pair with
    /// `recordType(forGedcomxFact:)` — update both together.
    nonisolated private static func pickPrimaryFact(facts: [FSFact], queryHint: RecordType) -> FSFact? {
        let hintedTypes: Set<String> = {
            switch queryHint {
            case .birth: return ["Birth", "BirthRegistration", "BirthNotice"]
            case .baptism, .christening: return ["Baptism", "Christening", "AdultChristening", "Blessing"]
            case .death: return ["Death", "DeathRegistration", "Funeral"]
            case .burial: return ["Burial", "Cremation"]
            case .marriage: return ["Marriage", "MarriageBanns", "MarriageRegistration",
                                    "MarriageLicense", "MarriageContract", "MarriageNotice", "CommonLawMarriage"]
            case .census: return ["Census", "Residence"]
            case .probate: return ["Probate", "Will"]
            case .military: return ["MilitaryService", "MilitaryDischarge", "MilitaryDraftRegistration", "MilitaryInduction", "MilitaryAward"]
            case .parish: return ["Baptism", "Christening", "Burial", "Marriage"]
            case .pedigree: return []
            }
        }()
        if let hit = facts.first(where: { fact in
            guard let suffix = fact.type?.split(separator: "/").last else { return false }
            return hintedTypes.contains(String(suffix))
        }) {
            return hit
        }
        return facts.first
    }

    /// Map a GEDCOM X fact-type URI to a RecordType, or nil for the query-hint
    /// fallback. Deliberate divergences: Funeral → .death (a funeral notice
    /// dates death to within days; .burial never writes date fields); the
    /// divorce family stays unmapped; Obituary is not cross-hint promoted.
    nonisolated private static func recordType(forGedcomxFact uri: String) -> RecordType? {
        switch uri.split(separator: "/").last.map(String.init) ?? "" {
        case "Birth", "BirthRegistration", "BirthNotice": return .birth
        case "Baptism", "Blessing": return .baptism
        case "Christening", "AdultChristening": return .christening
        case "Death", "DeathRegistration", "Funeral": return .death
        case "Burial", "Cremation": return .burial
        case "Marriage", "MarriageBanns", "MarriageRegistration",
             "MarriageLicense", "MarriageContract", "MarriageNotice", "CommonLawMarriage": return .marriage
        case "Census", "Residence": return .census
        case "Probate", "Will": return .probate
        case "MilitaryService", "MilitaryDischarge", "MilitaryDraftRegistration",
             "MilitaryInduction", "MilitaryAward": return .military
        default: return nil
        }
    }

    /// Find a Grave memorial id from a FAG-collection persona's fields (only
    /// the reliable `ExtRecordId`), so the pipeline's FAG bridge can follow up.
    nonisolated static func extractFindAGraveMemorialID(collectionTitle: String, rawFields: [String: String]) -> Int? {
        let title = collectionTitle.lowercased()
        guard title.contains("find a grave") || title.contains("findagrave") else { return nil }
        let candidates = [
            rawFields["field.ExtRecordId.original"],
            rawFields["field.ExtRecordId.interpreted"],
            rawFields["field.ExtRecordId"],
        ]
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            if let id = Int(raw) { return id }
            if let digits = raw.split(whereSeparator: { !$0.isNumber }).last, let id = Int(digits) { return id }
        }
        return nil
    }

    nonisolated private static func yearFromFormal(_ formal: String) -> Int? {
        let trimmed = formal.hasPrefix("+") ? String(formal.dropFirst()) : formal
        let yearPart = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        return Int(yearPart)
    }

    nonisolated private static func yearFromOriginal(_ original: String) -> Int? {
        let pattern = #"\b(1[5-9]\d{2}|20\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(original.startIndex..., in: original)
        if let match = regex.firstMatch(in: original, range: range), let r = Range(match.range, in: original) {
            return Int(original[r])
        }
        return nil
    }

    nonisolated private static func extractAge(rawFields: [String: String]) -> Int? {
        if let s = rawFields["field.Age"] ?? rawFields["field.Age.interpreted"] ?? rawFields["field.Age.original"] {
            return Int(s.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    nonisolated private static func extractSpouseName(relationships: [FSRelationship], personaID: String?, otherPersons: [FSPerson]) -> String? {
        guard let pid = personaID else { return nil }
        for rel in relationships where (rel.type?.split(separator: "/").last.map(String.init) ?? "") == "Couple" {
            let p1 = refID(rel.person1)
            let p2 = refID(rel.person2)
            let spouseID = (p1 == pid) ? p2 : (p2 == pid ? p1 : nil)
            guard let sid = spouseID, let spouse = otherPersons.first(where: { $0.id == sid }) else { continue }
            return spouse.names?.first?.nameForms?.first?.fullText
        }
        return nil
    }

    nonisolated private static func extractMothersMaidenName(relationships: [FSRelationship], personaID: String?, allPersons: [FSPerson]) -> String? {
        guard let pid = personaID else { return nil }
        for rel in relationships where (rel.type?.split(separator: "/").last.map(String.init) ?? "") == "ParentChild" {
            guard refID(rel.person2) == pid, let parentID = refID(rel.person1),
                  let parent = allPersons.first(where: { $0.id == parentID }) else { continue }
            let isMother = parent.gender?.type.flatMap { $0.split(separator: "/").last.map(String.init) } == "Female"
            if isMother {
                return parent.names?.first?.nameForms?.first?.parts?.first(where: { ($0.type ?? "").hasSuffix("/Surname") })?.value
            }
        }
        return nil
    }
}
