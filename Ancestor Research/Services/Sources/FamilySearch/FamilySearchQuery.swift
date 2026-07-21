import Foundation

/// A structured FamilySearch Platform-API search query.
///
/// Emits the documented `q.*` (fuzzy terms) / `f.*` (exact filters) grammar —
/// **not** the retired free-text `q=givenName:"…"` form the diagnostic probe
/// guessed (which the live API rejects with 400). The axes are grounded in the
/// official *Record Persona Search* resource (records search) and the
/// FamilySearch Bruno example collection (tree search); both consume the same
/// `q.*` term grammar. See `AncestorApp/FAMILYSEARCH_CLIENT_SPEC.md`.
///
/// Pure and `Sendable`; the URL builders in `FamilySearchEndpoints` consume
/// `queryItems()`. Date ranges emit an inclusive `.from`/`.to` pair of
/// Gedcomx simple-date years.
nonisolated struct FamilySearchQuery: Sendable, Equatable {

    /// `q.sex` filter value.
    enum Sex: String, Sendable, Equatable {
        case male = "Male"
        case female = "Female"
    }

    // MARK: Person terms (q.*)

    var givenName: String?
    var surname: String?
    /// When true (and a surname is present), emit `q.surname.exact=on` to opt
    /// out of Soundex/phonetic matching (Record Persona Search `.exact`
    /// modifier — value `on`/`off`).
    var surnameExact = false
    var sex: Sex?

    // MARK: Life-event date ranges + places (q.*)

    var birthDateRange: ClosedRange<Int>?
    var birthPlace: String?
    var deathDateRange: ClosedRange<Int>?
    var deathPlace: String?
    var marriageDateRange: ClosedRange<Int>?
    var marriagePlace: String?
    var residenceDateRange: ClosedRange<Int>?
    var residencePlace: String?
    var anyDateRange: ClosedRange<Int>?
    var anyPlace: String?

    // MARK: Relative axes (q.*)

    var fatherGivenName: String?
    var fatherSurname: String?
    var motherGivenName: String?
    var motherSurname: String?
    var spouseGivenName: String?
    var spouseSurname: String?

    // MARK: Exact filters (f.*)

    /// `f.treeId` — scope a tree search to a specific user tree.
    var treeId: String?
    /// `f.collectionId` — restrict a records search to one collection.
    var collectionId: String?

    // MARK: Pagination

    /// Results per page. Record Persona Search allows 1…100 (default 20).
    var count = 20
    /// 0-based start index. Record Persona Search allows 0…4999 (5000 cap).
    var offset = 0

    init() {}

    /// Deterministic, stably-ordered query items. Empty terms are omitted; a
    /// date range emits an inclusive `<base>.from` / `<base>.to` pair.
    /// Percent-encoding is left to `URLComponents` at URL-build time.
    func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: value))
        }
        func addRange(_ base: String, _ range: ClosedRange<Int>?) {
            guard let range else { return }
            items.append(URLQueryItem(name: "\(base).from", value: String(range.lowerBound)))
            items.append(URLQueryItem(name: "\(base).to", value: String(range.upperBound)))
        }

        add("q.givenName", givenName)
        add("q.surname", surname)
        if surnameExact, let surname, !surname.isEmpty {
            add("q.surname.exact", "on")
        }
        add("q.sex", sex?.rawValue)

        addRange("q.birthLikeDate", birthDateRange);       add("q.birthLikePlace", birthPlace)
        addRange("q.deathLikeDate", deathDateRange);       add("q.deathLikePlace", deathPlace)
        addRange("q.marriageLikeDate", marriageDateRange); add("q.marriageLikePlace", marriagePlace)
        addRange("q.residenceDate", residenceDateRange);   add("q.residencePlace", residencePlace)
        addRange("q.anyDate", anyDateRange);               add("q.anyPlace", anyPlace)

        add("q.fatherGivenName", fatherGivenName);         add("q.fatherSurname", fatherSurname)
        add("q.motherGivenName", motherGivenName);         add("q.motherSurname", motherSurname)
        add("q.spouseGivenName", spouseGivenName);         add("q.spouseSurname", spouseSurname)

        add("f.treeId", treeId)
        add("f.collectionId", collectionId)

        items.append(URLQueryItem(name: "count", value: String(count)))
        items.append(URLQueryItem(name: "offset", value: String(offset)))
        return items
    }
}
