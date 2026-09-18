import Foundation
import AncestorKit

/// Subject place model Slice 2 — the one place shape.
///
/// Storage was always uniform: every location in the model is a `(text, code)`
/// pair — `birthLocation`/`birthLocationCode`, `deathLocation`/`deathLocationCode`,
/// `LifeEvent.location`/`locationCode` (census and residence alike),
/// `marriageLocation`/`marriageLocationCode`. It is `ResearchSubject` that
/// flattens that single shape into five ad-hoc ones (`region`, `deathLocation`,
/// `homeChapmanCode`, `residenceAxes`, `burialPlace`/`burialChapmanCode`), so
/// each consumer reads whichever field someone remembered to wire to it and the
/// gaps are arbitrary rather than designed. Four separate "additive arm" special
/// cases grew from that, one per source, each with its own comment explaining
/// the same idea — and census residences still reach nothing at all.
///
/// A `PlaceRef` is one place we know about a person: what the tree says, the
/// gazetteer id when there is one, what kind of event put them there, and when.
/// Consumers ask "places of kind X covering year Y" instead of reading a bespoke
/// field.
///
/// Read by `ConflictDetector`, `ResearchSubject` and the FamilySearch GEDCOM X
/// mapper. Readers were migrated one at a time, each proving the
/// characterization tests still passed, with the replay diff over the corpus as
/// the gate.
nonisolated struct PlaceRef: Sendable, Equatable, Hashable {

    /// What kind of event put the subject here. Not a source type — the same
    /// source can attest several kinds.
    enum Kind: String, Sendable, Codable, CaseIterable {
        case birth, death, marriage, residence, census, burial
    }

    /// What the tree says, verbatim. Never normalised — the user's words are
    /// evidence, and `Bolehill` meaning a settlement inside a street address is
    /// a real distinction no normaliser can safely make.
    let text: String

    /// `PlaceAuthority` id when known ("DBY:Wirksworth"), nil when the place is
    /// free text only. Its presence is the whole argument for this type: today
    /// the FreeBMD arm re-parses a death county from text at the call site while
    /// the burial county arrives pre-derived, five lines apart.
    let code: String?

    let kind: Kind

    /// Event window. Nil bounds are OPEN, not unknown-and-therefore-excluded —
    /// a residence recorded only as "from 1930" still applies in 1935.
    let yearFrom: Int?
    let yearTo: Int?

    /// Carried, never silently dropped. `residenceAxes` filters
    /// `!event.sensitive` at derivation, which means the information that a
    /// place was withheld is destroyed rather than represented. A collection
    /// that carries the flag can decide per consumer.
    let sensitive: Bool

    init(text: String, code: String? = nil, kind: Kind,
         yearFrom: Int? = nil, yearTo: Int? = nil, sensitive: Bool = false) {
        self.text = text
        self.code = code
        self.kind = kind
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.sensitive = sensitive
    }

    /// County chapman derived uniformly: the code first, because it is the more
    /// precise statement, then the text. This is the derivation that today is
    /// written out longhand at each call site.
    var chapmanCode: String? {
        ResearchSubject.chapmanCodeFromLocationCode(code)
            ?? ResearchSubject.chapmanCode(forPlaceText: text)
    }

    /// Does this place apply in `year`? Permissive on open bounds and on a nil
    /// query year — a caller with no year is asking "could this be relevant",
    /// and the answer is yes.
    func applies(to year: Int?) -> Bool {
        guard let year else { return true }
        if let from = yearFrom, year < from { return false }
        if let to = yearTo, year > to { return false }
        return true
    }
}

extension Array where Element == PlaceRef {

    /// Places of these kinds that apply in `year`. The question every consumer
    /// actually has, asked once.
    func of(_ kinds: Set<PlaceRef.Kind>, in year: Int? = nil,
            includingSensitive: Bool = false) -> [PlaceRef] {
        filter { (includingSensitive || !$0.sensitive) && kinds.contains($0.kind) && $0.applies(to: year) }
    }

    func of(_ kind: PlaceRef.Kind, in year: Int? = nil,
            includingSensitive: Bool = false) -> [PlaceRef] {
        of([kind], in: year, includingSensitive: includingSensitive)
    }

    /// Distinct county chapman codes, in first-seen order.
    ///
    /// Order is first-seen and not sorted deliberately: `places` is built in
    /// precedence order, so the caller's first county is the best-evidenced one,
    /// and a source that can afford only one axis should take `.first`. Sorting
    /// would silently hand it whichever county is alphabetically first.
    var chapmanCodes: [String] {
        var seen = Set<String>()
        return compactMap { ref -> String? in
            guard let code = ref.chapmanCode, !code.isEmpty, seen.insert(code).inserted
            else { return nil }
            return code
        }
    }
}
