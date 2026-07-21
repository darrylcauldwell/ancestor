import Foundation
import AncestorKit
import os

/// FamilySearch enrichment leg (Slice 6) — the pivot's unique value beyond
/// records search: FamilySearch's own ML-driven **record hints** on a matching
/// shared-tree person, surfaced as **leads** through the firewall into lead
/// discovery, plus document-image **pointers** (link-only).
///
/// Read-only flow (no write/contribute leg): search the shared Family Tree for
/// the subject → take the best-matching tree person(s) → fetch their record
/// hints (`/matches?collection=records`) → each hint becomes a lead-shaped
/// `FamilySearchHint`. Requires the subject to exist in FamilySearch's shared
/// tree; when they don't, the enrichment is simply empty (records search still
/// covers them).
///
/// **§18 (deterministic sandwich for a remote ML matcher):** a FamilySearch
/// match confidence is a **lead-ordering signal only** — it never sets a trust
/// tier, enters a gate, or counts toward convergence. It orders the hint list;
/// our rules decide.
actor FamilySearchEnrichmentService {

    /// How many top tree-person matches to pull hints for (bounded — the shared
    /// tree can hold many same-name persons).
    static let maxTreePersons = 3

    private let environment: FamilySearchEnvironment
    private let client: FamilySearchClient
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FamilySearchEnrichment")

    init(environment: FamilySearchEnvironment = .beta) {
        self.environment = environment
        self.client = FamilySearchClient(
            environment: environment,
            tokenSource: KeychainFamilySearchTokenSource(environment: environment))
    }

    /// Injectable init for tests.
    init(client: FamilySearchClient, environment: FamilySearchEnvironment) {
        self.environment = environment
        self.client = client
    }

    // MARK: - Record hints → leads

    /// Fetch FamilySearch record hints for a subject, ordered by match
    /// confidence (§18: ordering only). Empty when the subject isn't in the
    /// shared tree or has no hints — never throws (enrichment is best-effort).
    func recordHints(surname: String, givenName: String?, birthYear: Int?, deathYear: Int?) async -> [FamilySearchHint] {
        var query = FamilySearchQuery()
        query.surname = surname
        query.givenName = givenName
        if let birthYear { query.birthDateRange = (birthYear - 2)...(birthYear + 2) }
        query.count = Self.maxTreePersons

        let treePersons: [FSPerson]
        do {
            let feed = try await client.treePersonSearch(query)
            treePersons = (feed.entries ?? []).compactMap { $0.content?.gedcomx?.persons?.first }
        } catch {
            logger.warning("Tree search for hints failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var hints: [FamilySearchHint] = []
        for person in treePersons.prefix(Self.maxTreePersons) {
            guard let pid = person.id else { continue }
            do {
                let feed = try await client.personMatches(pid: pid, collection: .records)
                hints.append(contentsOf: Self.parseHints(feed, treePersonID: pid))
            } catch {
                logger.warning("Record-hint fetch for \(pid, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // §18: match confidence orders the list; highest first. Stable on ties.
        return hints.sorted { ($0.matchConfidence ?? 0) > ($1.matchConfidence ?? 0) }
    }

    /// Fetch FamilySearch record hints for a subject as full `SourceRecord`s,
    /// ready to route through the deterministic scorer (the S6b design: hints
    /// reach the pipeline through the SAME gates as records search, deduped on
    /// the persona id). Parsed via the S5 records parser so every gate has the
    /// full typed record; each carries `rawFields["fsMatchScore"]` (§18 ordering
    /// only) + `rawFields["fsTreePersonID"]` (provenance). Best-effort — empty
    /// when the subject isn't in the shared tree; never throws.
    func recordHintsAsSourceRecords(surname: String, givenName: String?, birthYear: Int?, deathYear: Int?) async -> [SourceRecord] {
        var treeQuery = FamilySearchQuery()
        treeQuery.surname = surname
        treeQuery.givenName = givenName
        if let birthYear { treeQuery.birthDateRange = (birthYear - 2)...(birthYear + 2) }
        treeQuery.count = Self.maxTreePersons

        let treePersons: [FSPerson]
        do {
            let feed = try await client.treePersonSearch(treeQuery)
            treePersons = (feed.entries ?? []).compactMap { $0.content?.gedcomx?.persons?.first }
        } catch {
            logger.warning("Tree search for hint records failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        // A synthetic query only drives `parseSearchFeed`'s surname guard
        // (`.variant` = exact surname, no phonetic tail) and its record-type
        // fallback; `buildRecord` derives the real type per persona fact.
        let recordQuery = RecordQuery(
            surname: surname, givenName: givenName, recordType: .parish,
            yearFrom: birthYear, yearTo: deathYear, gender: nil, region: nil,
            sourceParams: .generic, strictness: .variant)

        var records: [SourceRecord] = []
        for person in treePersons.prefix(Self.maxTreePersons) {
            guard let pid = person.id else { continue }
            do {
                let feed = try await client.personMatches(pid: pid, collection: .records)
                records.append(contentsOf: FamilySearchSource.parseSearchFeed(
                    feed, query: recordQuery, extraRawFields: ["fsTreePersonID": pid]).records)
            } catch {
                logger.warning("Record-hint fetch for \(pid, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return records
    }

    /// Parse a `/matches` feed into lead-shaped hints. Pure and testable.
    nonisolated static func parseHints(_ feed: RecordsSearchFeed, treePersonID: String) -> [FamilySearchHint] {
        (feed.entries ?? []).compactMap { entry -> FamilySearchHint? in
            let gx = entry.content?.gedcomx
            guard let persona = gx?.persons?.first else { return nil }
            let nameForm = persona.names?.first?.nameForms?.first
            let name = nameForm?.fullText
                ?? nameForm?.parts?.compactMap(\.value).joined(separator: " ")
            let primaryFact = persona.facts?.first
            let year = primaryFact?.date?.formal.flatMap(yearFromFormal)
                ?? primaryFact?.date?.original.flatMap(yearFromOriginal)
            let place = primaryFact?.place?.original
            let recordType = primaryFact?.type?.split(separator: "/").last.map(String.init)

            let sd = gx?.sourceDescriptions?.first
            let ark = bareArk(from: sd?.about) ?? bareArk(from: persona.identifiers?.persistent)
            let collectionTitle = sd?.titles?.first?.value ?? ""

            // Confidence: the entry's score, else its FS match confidence.
            let confidence = entry.score ?? entry.confidence

            // A hint with no identity at all isn't actionable.
            guard name != nil || ark != nil else { return nil }
            return FamilySearchHint(
                ark: ark,
                collectionTitle: collectionTitle,
                matchConfidence: confidence,
                name: name,
                year: year,
                place: place,
                recordType: recordType,
                treePersonID: treePersonID)
        }
    }

    // MARK: - Image pointers (link-only)

    /// Document-image pointers for a tree person's memories — link-only per the
    /// Find a Grave posture (§16): capture the ARK/URL + title, never download
    /// or store the image bytes. Best-effort; empty on failure.
    func imagePointers(forTreePerson pid: String) async -> [FamilySearchImagePointer] {
        do {
            let response = try await client.execute(
                FamilySearchRequest(url: FamilySearchEndpoints.personMemories(environment, pid: pid), accept: .json))
            guard (200...299).contains(response.statusCode),
                  let memories = try? response.decode(FamilySearchMemoriesEnvelope.self) else { return [] }
            return memories.sourceDescriptions?.compactMap { sd -> FamilySearchImagePointer? in
                guard let href = sd.about ?? sd.links?["image"]?.href else { return nil }
                return FamilySearchImagePointer(url: href, title: sd.titles?.first?.value)
            } ?? []
        } catch {
            return []
        }
    }

    // MARK: - Pure helpers

    /// The bare `ark:/…` path segment (§17.1) from a full URL/fragment, or nil.
    nonisolated static func bareArk(from raw: String?) -> String? {
        guard let raw, let r = raw.range(of: "ark:/") else { return nil }
        return String(raw[r.lowerBound...])
    }

    nonisolated static func yearFromFormal(_ formal: String) -> Int? {
        let trimmed = formal.hasPrefix("+") ? String(formal.dropFirst()) : formal
        return Int(trimmed.split(separator: "-").first.map(String.init) ?? trimmed)
    }

    nonisolated static func yearFromOriginal(_ original: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(1[5-9]\d{2}|20\d{2})\b"#) else { return nil }
        let range = NSRange(original.startIndex..., in: original)
        guard let match = regex.firstMatch(in: original, range: range), let r = Range(match.range, in: original) else { return nil }
        return Int(original[r])
    }
}

// MARK: - Hint / pointer value types

/// A FamilySearch record hint, shaped for the firewall's lead surface. The
/// `matchConfidence` is a §18 lead-ordering signal only — never a gate/tier/
/// convergence input.
nonisolated struct FamilySearchHint: Sendable, Equatable {
    let ark: String?               // bare `ark:/…` path of the hinted record
    let collectionTitle: String
    let matchConfidence: Double?   // §18: ordering only
    let name: String?
    let year: Int?
    let place: String?
    let recordType: String?        // GEDCOM X fact-type suffix
    /// The shared-tree person the hint attaches to (its identity to the subject
    /// is advisory — the user reviews the lead).
    let treePersonID: String
}

/// A link-only pointer to a FamilySearch document image (never stored content).
nonisolated struct FamilySearchImagePointer: Sendable, Equatable {
    let url: String
    let title: String?
}

/// Minimal memories envelope — link-only, so only the pointer fields are modelled.
nonisolated struct FamilySearchMemoriesEnvelope: Decodable, Sendable, Equatable {
    let sourceDescriptions: [Memory]?
    struct Memory: Decodable, Sendable, Equatable {
        let about: String?
        let titles: [FSTextValue]?
        let links: [String: Link]?
        struct Link: Decodable, Sendable, Equatable { let href: String? }
    }
}
