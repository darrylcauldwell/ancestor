import Foundation

/// The kind of name a `NameForm` records. Mirrors the typed-name vocabularies
/// every mature genealogy system converged on (GEDCOM X, FamilySearch,
/// WikiTree, RootsMagic, Legacy — `r2-conclusions.md` §3 E2).
///
/// This is *classification only*: it never changes what the flat search-key
/// fields (`firstName`/`lastName`/`marriedSurname`/`nickName`) resolve to. A
/// `.married` form and the flat `marriedSurname` coexist — the flat field keeps
/// the single search-key "winner" (MODEL_EVOLUTION_SPEC §Change2 AC1); the form
/// list is the lossless landing zone for *every* variant, including the ones
/// the flat model cannot express (a second marriage, a deed-poll change, an
/// alias, a non-Western structure).
public nonisolated enum NameFormType: String, Codable, Hashable, Sendable, CaseIterable {
    /// The name at birth / christening. Its surname corresponds to the flat
    /// `lastName` (maiden surname, by this app's genealogy convention).
    case birth
    /// A surname acquired by marriage. A twice-married woman carries two
    /// `.married` forms; the flat `marriedSurname` still holds the search-key
    /// winner. WikiTree `LastNameCurrent` (when it differs from
    /// `LastNameAtBirth`) ingests as this.
    case married
    /// An "also known as" / other name. WikiTree `LastNameOther` ingests as
    /// this — the variant both importers silently dropped before E2.
    case alsoKnownAs
    /// A familiar / diminutive form ("Bill" for William). Distinct from the
    /// flat `nickName` search key only in that a profile may carry several.
    case nickname
    /// A religious name (name in religion, ordination name).
    case religious
    /// An anglicised rendering of a name from another language/script.
    case anglicised
    /// Anything the above cases do not capture.
    case other
}

/// One typed, repeatable name a person is or was known by
/// (MODEL_EVOLUTION_SPEC §Change2 / ADR-004 E2).
///
/// A **sidecar, not a rebuild** (`r2-mapping-analysis.md` §7.3): the flat
/// `firstName`/`middleName`/`lastName`/`marriedSurname`/`nickName`/
/// `mothersMaidenName` fields on `Profile` stay the canonical search keys with
/// their engine semantics untouched. `NameForm` is the additive record that
/// makes previously-unrepresentable structure *storable* — a twice-married
/// woman, aliases, prefixes/suffixes, non-Western name shapes — without any
/// engine, scorer, publisher, or viewer re-derivation. `Profile.displayName`
/// remains the only name projection consumers see, and it is computed from the
/// flat given/surname fields exactly as before.
///
/// Storage granularity for provenance is the *whole list* — `nameForms` is
/// journalled as a single `ProfileField.nameForms` case (per-form provenance is
/// a non-goal, AC5).
public nonisolated struct NameForm: Codable, Hashable, Sendable {
    /// What kind of name this is — see `NameFormType`.
    public var type: NameFormType

    /// The complete name as a single rendered string. Always populated; the
    /// structured parts below are optional refinements. For a form built from a
    /// bare surname variant (the common WikiTree ingest case) `fullText` is that
    /// surname.
    public var fullText: String

    /// BCP-47 language tag when the form is language-specific (e.g. an
    /// `.anglicised` or `.religious` name). Optional.
    public var lang: String?

    /// Structured given name(s), when known separately from `fullText`.
    public var given: String?

    /// Structured surname, when known separately from `fullText`.
    public var surname: String?

    /// Honorific/prefix ("Sir", "Dr", "Lady"), when known.
    public var prefix: String?

    /// Post-nominal/suffix ("Jr", "III", "MD"), when known.
    public var suffix: String?

    public init(
        type: NameFormType,
        fullText: String,
        lang: String? = nil,
        given: String? = nil,
        surname: String? = nil,
        prefix: String? = nil,
        suffix: String? = nil
    ) {
        self.type = type
        self.fullText = fullText
        self.lang = lang
        self.given = given
        self.surname = surname
        self.prefix = prefix
        self.suffix = suffix
    }
}

public nonisolated extension Array where Element == NameForm {

    /// True when a `.married` form carrying `surname` (or `fullText`) is already
    /// present. Used by ingest to stay idempotent — re-importing the same
    /// WikiTree profile must not accumulate duplicate forms.
    func containsMarriedSurname(_ surname: String) -> Bool {
        let needle = surname.lowercased()
        return contains { form in
            form.type == .married &&
            (form.surname?.lowercased() == needle || form.fullText.lowercased() == needle)
        }
    }

    /// The surname of the first `.married` form, if any. This is a *convenience
    /// read over the sidecar* — it is **not** wired into the scorer or source
    /// dispatch, which continue to read the flat `marriedSurname` search key.
    /// Exposed so tests (and, later, an opt-in matcher) can confirm a
    /// twice-married woman's married surnames survived ingest.
    var marriedSurnames: [String] {
        compactMap { form in
            guard form.type == .married else { return nil }
            return form.surname ?? (form.fullText.isEmpty ? nil : form.fullText)
        }
    }
}
