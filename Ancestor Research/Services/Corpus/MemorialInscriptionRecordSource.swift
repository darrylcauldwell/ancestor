import Foundation

/// TEMPLATED_NARRATIVE_SOURCE_SPEC Stage 2 — the live Chapman-templated
/// memorial-inscription source. Given a subject's county Chapman code + resolved
/// parish (passed as `.memorialInscription` query params), it templates ONE
/// parish page via `TemplatedURLResolver`, fetches it, parses the stones with
/// `MemorialInscriptionSource`, and returns **burial** records — a death year +
/// age (→ birth year) and a name, the discriminating evidence a namesake-heavy
/// BMD index can't give (the William Holmes problem). One on-demand page per
/// lookup; never a crawl.
///
/// Firewall: only extracted FACTS are returned (dates, implied birth year, name).
/// The verbatim inscription text is NOT copied into the record — aligning with
/// the site's "may not be used in published family histories" term.
actor MemorialInscriptionRecordSource: RecordSource {

    nonisolated let sourceID = "wishful-thinking-mi"
    nonisolated let displayName = "Memorial Inscriptions (Wishful Thinking)"
    nonisolated let recordTypes: Set<RecordType> = [.burial]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1500...2000
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "memorial-inscriptions")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let scopeHandling: ScopeHandling = .scoped
    // Terms verified 2026-08-05 (wishful-thinking.org.uk/Conditions.html): personal
    // family-history research explicitly permitted, so `.open` — but attribution
    // required and republication forbidden (enforced by the firewall, not here).
    nonisolated let tosStatus = SourceToSStatus(
        level: .open,
        summary: "Personal family-history research permitted; commercial sale, publication in "
            + "family histories, and whole-site copying forbidden; attribution (URL) required. "
            + "One on-demand page per lookup — never a crawl.")

    /// Injected so tests drive the parse path with a fixture page and no network.
    let fetchPage: @Sendable (URL) async throws -> String

    // Under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the actor's init is
    // MainActor-isolated (as with ProseCorpusSource) — call it from a MainActor
    // context (SourceBootstrap, or a @MainActor test).
    init(fetchPage: @escaping @Sendable (URL) async throws -> String = MemorialInscriptionRecordSource.liveFetch) {
        self.fetchPage = fetchPage
    }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard case .memorialInscription(let params) = query.sourceParams else {
            return .outsideCoverage(reason: "Memorial inscriptions need a county Chapman code and a resolved parish")
        }
        guard let url = TemplatedURLResolver.resolve(
            TemplatedSourceCatalogue.wishfulThinkingMIs,
            subject: .init(chapmanCode: params.chapmanCode, parish: params.parish))
        else {
            return .outsideCoverage(reason: "Could not template a parish page for \(params.chapmanCode)/\(params.parish)")
        }

        let text: String
        do { text = try await fetchPage(url) }
        catch { return .unavailable(reason: error.localizedDescription) }

        return .results(Self.records(
            from: text, surname: query.surname,
            chapman: params.chapmanCode, parish: params.parish, url: url, sourceID: sourceID))
    }

    /// Parse the page and map matching people to burial records. `nonisolated
    /// static` on purpose: under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor a
    /// closure written inside the actor's `search` is inferred MainActor-isolated,
    /// and running that synchronous `.map` on the actor's own executor tripped a
    /// `swift_task_checkIsolated` abort at runtime. Building the records off the
    /// actor removes the inference. Facts only — the verbatim inscription is never
    /// copied into the record.
    nonisolated static func records(
        from text: String, surname: String?,
        chapman: String, parish: String, url: URL, sourceID: String
    ) -> [SourceRecord] {
        let wanted = (surname ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let people = MemorialInscriptionSource.parse(text)
            .filter { wanted.isEmpty || $0.surname.lowercased() == wanted }
        return people.enumerated().map { index, person in
            let common = RecordCommon(
                id: "wtmi_\(chapman)_\(parish)_\(index)",
                sourceID: sourceID,
                name: [person.givenName, person.surname].filter { !$0.isEmpty }.joined(separator: " "),
                surname: person.surname,
                givenName: person.givenName.isEmpty ? nil : person.givenName,
                detailURL: url.absoluteString,
                rawFields: [:])
            return .burial(BurialRecord(
                common: common,
                deathDate: person.deathYear.map(String.init),
                deathYear: person.deathYear,
                birthDate: person.birthYear.map(String.init),
                birthYear: person.birthYear,
                birthPlace: nil,
                deathPlace: nil,
                burialLocation: parish,
                cemetery: nil,
                memorialID: nil,
                inscription: nil,
                bio: nil,
                isVeteran: false))
        }
    }

    /// Extract the PARISH from a subject's location string, for the dispatcher to
    /// slot into the URL template. Drops a trailing country and county (a token
    /// ending "shire", carrying a "(XXX)" Chapman code, or matching a known
    /// county), then takes the last remaining place — the parish/town, e.g.
    /// "Alport, Youlgreave, Derbyshire, England" -> "Youlgreave". Returns nil when
    /// nothing specific remains (no guessed parish).
    nonisolated static func parish(fromLocation location: String?) -> String? {
        guard let location, !location.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var parts = location
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func isCountryOrCounty(_ token: String) -> Bool {
            let t = token.lowercased()
            if ["england", "wales", "uk", "united kingdom", "gb", "great britain"].contains(t) { return true }
            if t.hasSuffix("shire") { return true }
            if token.contains("(") && token.contains(")") { return true }   // "Derbyshire (DBY)"
            return false
        }
        // Peel country/county tokens off the END only — a leading "London" stays.
        while let last = parts.last, isCountryOrCounty(last) { parts.removeLast() }
        return parts.last
    }

    /// Extract the burial records from a search result. The `.burial` pattern
    /// match runs in the app module — same AncestorKit copy the records were
    /// minted in — so a test can inspect them without a cross-module cast.
    nonisolated static func burials(in result: SourceQueryResult) -> [BurialRecord] {
        result.records.compactMap { if case .burial(let b) = $0 { return b } else { return nil } }
    }

    /// Single paced GET. Production fetch; not exercised by unit tests.
    nonisolated static func liveFetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }
}
