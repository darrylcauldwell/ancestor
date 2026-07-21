import Foundation

// GEDCOM X response model for the FamilySearch Platform API (Slice 2).
//
// Two envelope shapes, distinguished by media type (see
// `AncestorApp/FAMILYSEARCH_CLIENT_SPEC.md`):
//   • Tree person read / tree data (`application/x-fs-v1+json`) → the body IS
//     an `FSGedcomx` with `persons[]` / `relationships[]` at the top level.
//   • Search / matches feed (`application/x-gedcomx-atom+json`) → an Atom feed:
//     `RecordsSearchFeed` with `entries[]`, each wrapping a nested `FSGedcomx`.
//
// Only the members the pipeline consumes are modelled; GEDCOM X is
// open/extensible so unmodelled members fall through Codable harmlessly, and
// every URI-typed value is decoded as a plain `String` (never a closed enum).
// The struct set is seeded from the deleted cookie-era parser (git 9facbc1,
// which decoded the same GEDCOM X Atom shape in production) and reconciled to
// the fuller graph the docs describe. Member names for the Atom wrapper
// (`results`/`entries`/`content.gedcomx`/`score`) match what that parser read
// live from `/service/search/hr/v2/personas`; re-confirm against a live OAuth
// `/platform/records/personas` body in Slice 4 before treating as final.

// MARK: - Envelopes

/// A GEDCOM X data set — the top-level body of a tree read, and the payload
/// wrapped inside each search-feed entry. (FamilySearch's `x-fs-v1+json`
/// FamilySearchPlatform extends this with `childAndParentsRelationships` and
/// `errors`, both folded in here as optional members.)
nonisolated struct FSGedcomx: Decodable, Sendable, Equatable {
    var id: String?
    var lang: String?
    var persons: [FSPerson]?
    var relationships: [FSRelationship]?
    var childAndParentsRelationships: [FSChildAndParentsRelationship]?
    var sourceDescriptions: [FSSourceDescription]?
    var errors: [FSError]?
}

/// The Atom feed returned by records/tree search + tree-person matches
/// (`application/x-gedcomx-atom+json`).
nonisolated struct RecordsSearchFeed: Decodable, Sendable, Equatable {
    /// Total matching results (Atom/OpenSearch `totalResults`; FS exposes it as
    /// `results` at feed level — can be far larger than the returned page).
    var results: Int?
    /// Offset of the first returned entry.
    var index: Int?
    var entries: [FSSearchEntry]?
}

nonisolated struct FSSearchEntry: Decodable, Sendable, Equatable {
    var id: String?
    var title: String?
    /// Per-result relevance score (lead-ordering signal only — never a gate,
    /// trust tier, or convergence input; spec §18).
    var score: Double?
    var confidence: Double?
    var content: FSEntryContent?
    var searchInfo: FSSearchInfo?
    var matchInfo: [FSMatchInfo]?
}

nonisolated struct FSEntryContent: Decodable, Sendable, Equatable {
    var gedcomx: FSGedcomx?
}

nonisolated struct FSSearchInfo: Decodable, Sendable, Equatable {
    var totalHits: Int?
    var closeHits: Int?
}

/// Per-hint match metadata on a `/matches` feed entry.
nonisolated struct FSMatchInfo: Decodable, Sendable, Equatable {
    var collection: String?   // URI: .../collections/records for record hints
    var status: String?       // URI: .../v1/{Pending,Accepted,Rejected}
}

// MARK: - Conclusions / subjects

nonisolated struct FSPerson: Decodable, Sendable, Equatable {
    var id: String?
    /// true ⇒ a record persona (extracted from a document) rather than a tree
    /// conclusion person.
    var extracted: Bool?
    /// Record-extension: the principal subject of the record.
    var principal: Bool?
    var living: Bool?
    var sortKey: String?
    var gender: FSGender?
    var names: [FSName]?
    var facts: [FSFact]?
    var fields: [FSField]?
    var sources: [FSSourceReference]?
    var identifiers: FSIdentifiers?
}

nonisolated struct FSName: Decodable, Sendable, Equatable {
    var id: String?
    var type: String?          // URI: BirthName/MarriedName/Nickname/…
    var preferred: Bool?
    var date: FSDate?
    var nameForms: [FSNameForm]?
}

nonisolated struct FSNameForm: Decodable, Sendable, Equatable {
    var lang: String?
    var fullText: String?
    var parts: [FSNamePart]?
}

nonisolated struct FSNamePart: Decodable, Sendable, Equatable {
    var type: String?          // URI: Given/Surname/Prefix/Suffix
    var value: String?
    var qualifiers: [FSQualifier]?
}

nonisolated struct FSGender: Decodable, Sendable, Equatable {
    var type: String?          // URI: Male/Female/Unknown/Intersex
}

nonisolated struct FSFact: Decodable, Sendable, Equatable {
    var id: String?
    var type: String?          // URI: http://gedcomx.org/<FactType>
    var date: FSDate?
    var place: FSPlaceReference?
    var value: String?
    var primary: Bool?
    var qualifiers: [FSQualifier]?
    /// Raw indexed record fields attached to this fact (record personas).
    var fields: [FSField]?
}

nonisolated struct FSDate: Decodable, Sendable, Equatable {
    var original: String?      // verbatim as recorded
    var formal: String?        // GEDCOM X date format, e.g. "+1651-11-29"
    var normalized: [FSTextValue]?
}

nonisolated struct FSPlaceReference: Decodable, Sendable, Equatable {
    var original: String?
    /// URI/fragment to a PlaceDescription (place ARK), e.g. "#1740247784".
    var description: String?
    var normalized: [FSTextValue]?
}

// MARK: - Relationships

nonisolated struct FSRelationship: Decodable, Sendable, Equatable {
    var id: String?
    var type: String?          // URI: Couple/ParentChild/…
    var person1: FSResourceReference?
    var person2: FSResourceReference?
    var facts: [FSFact]?
}

/// FamilySearch models parentage as a single triad rather than two ParentChild
/// edges — handle alongside plain `FSRelationship`.
nonisolated struct FSChildAndParentsRelationship: Decodable, Sendable, Equatable {
    var id: String?
    var father: FSResourceReference?
    var mother: FSResourceReference?
    var child: FSResourceReference?
    var fatherFacts: [FSFact]?
    var motherFacts: [FSFact]?
}

nonisolated struct FSResourceReference: Decodable, Sendable, Equatable {
    var resource: String?      // URI, e.g. "https://…/persons/PID" or "#PID"
    var resourceId: String?
}

// MARK: - Sources

nonisolated struct FSSourceReference: Decodable, Sendable, Equatable {
    var id: String?
    var description: String?   // URI → a SourceDescription (REQUIRED per spec)
    var descriptionId: String?
    var qualifiers: [FSQualifier]?
}

nonisolated struct FSSourceDescription: Decodable, Sendable, Equatable {
    var id: String?
    var resourceType: String?  // URI: Collection/Record/…/Person
    var about: String?         // URI/fragment the description is about (ARK)
    var citations: [FSSourceCitation]?
    var titles: [FSTextValue]?
    var coverage: [FSCoverage]?
    var componentOf: FSSourceReference?
    var identifiers: FSIdentifiers?
    var modified: Int64?       // ms since epoch
    var version: String?
}

nonisolated struct FSSourceCitation: Decodable, Sendable, Equatable {
    var lang: String?
    var value: String?
}

nonisolated struct FSCoverage: Decodable, Sendable, Equatable {
    var spatial: FSPlaceReference?
    var temporal: FSDate?
    var recordType: String?    // URI
    /// Collection completeness 0…1 (negative-search-evidence signal).
    var completeness: Double?
}

// MARK: - Record fields (original vs interpreted)

nonisolated struct FSField: Decodable, Sendable, Equatable {
    var id: String?
    var type: String?          // URI: field type (Age/Date/Place/Name/…)
    var values: [FSFieldValue]?
}

nonisolated struct FSFieldValue: Decodable, Sendable, Equatable {
    /// URI: http://gedcomx.org/Original (verbatim) | …/Interpreted (parsed).
    var type: String?
    var labelId: String?
    var text: String?
    var datatype: String?      // xsd# type hint for `text`
    var resource: String?      // URI when the value is a controlled resource
}

// MARK: - Shared value types

nonisolated struct FSTextValue: Decodable, Sendable, Equatable {
    var lang: String?
    var value: String?
}

nonisolated struct FSQualifier: Decodable, Sendable, Equatable {
    var name: String?          // URI
    var value: String?
}

nonisolated struct FSError: Decodable, Sendable, Equatable {
    var code: Int?
    var label: String?
    var message: String?
}

// MARK: - Identifiers (map, not array)

/// GEDCOM X `identifiers` is a JSON object keyed by identifier-type URI whose
/// values are arrays of strings (a single-valued custom type MAY be a bare
/// string; untyped identifiers use the key "$"). Decoded into a plain
/// `[String: [String]]`, tolerating both bare-string and array values.
nonisolated struct FSIdentifiers: Decodable, Sendable, Equatable {
    var values: [String: [String]]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FSDynamicCodingKey.self)
        var result: [String: [String]] = [:]
        for key in container.allKeys {
            if let array = try? container.decode([String].self, forKey: key) {
                result[key.stringValue] = array
            } else if let single = try? container.decode(String.self, forKey: key) {
                result[key.stringValue] = [single]
            }
        }
        values = result
    }

    subscript(_ typeURI: String) -> [String] { values[typeURI] ?? [] }

    /// The persistent ARK (bare `ark:/…` is derived at persist time; this is the
    /// full URI as delivered) if the person/description carries one.
    var persistent: String? { values["http://gedcomx.org/Persistent"]?.first }
}

private struct FSDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}
