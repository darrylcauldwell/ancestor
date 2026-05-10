import Foundation
import SwiftUI

/// Resolved family unit for a Family Group Sheet (DESIGN.md §7.9.3).
///
/// A unit always has at least one parent. The two adult slots are labelled
/// `father`/`mother` for clarity; either may be nil (single parent, or a
/// standalone subject without a partner). The `marriage` relationship
/// (when present) carries marriage date/location for the parents section.
struct FamilyUnit: Sendable {
    /// Profile shown in the father column of the parents section. Picked
    /// by gender first, falling back to the spouse-relationship `from` side
    /// when gender is unknown.
    let father: Profile?
    /// Profile shown in the mother column of the parents section.
    let mother: Profile?
    /// Children listed in the children section, ordered by birth year
    /// (unknown years sort last).
    let children: [Profile]
    /// The marriage edge between father and mother (if any). Drives the
    /// "Married" line in the parents section.
    let marriage: Relationship?

    /// All profiles in the unit — parents + children. Used to scope source
    /// and note collection.
    var allMembers: [Profile] {
        ([father, mother] + children.map { Optional($0) }).compactMap { $0 }
    }

    /// Display name for the unit — "John Smith & Mary Jones",
    /// or "John Smith" when only one parent is known.
    var headerName: String {
        switch (father?.displayName, mother?.displayName) {
        case let (f?, m?) where !f.isEmpty && !m.isEmpty: return "\(f) & \(m)"
        case let (f?, _) where !f.isEmpty: return f
        case let (_, m?) where !m.isEmpty: return m
        default: return "Family"
        }
    }
}

/// Family Group Sheet renderer (DESIGN.md §7.9.3).
///
/// One page per family unit. The unit is resolved from a subject profile
/// id using `family(forProfileID:in:)` — the unit either centres on the
/// subject's marriage (if any), the subject's parents (if known), or the
/// subject alone.
@MainActor
enum FamilyGroupSheetReport {

    static func renderPDF(
        profileID: String,
        paperSize: PaperSize,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote]
    ) -> Data? {
        guard let unit = family(forProfileID: profileID, in: snapshot) else {
            return nil
        }
        return PDFRenderer.renderToPDFData(paperSize: paperSize) {
            FamilyGroupSheetPage(unit: unit, notes: notes)
        }
    }

    /// Batch render — one PDF with one page per distinct family in the
    /// snapshot. Per DESIGN.md §7.9.3 ("Export all family group sheets").
    /// Returns nil when the snapshot has no families to render (empty tree
    /// or nothing the enumerator can resolve).
    static func renderAllFamiliesPDF(
        paperSize: PaperSize,
        snapshot: FamilyGraphSnapshot,
        notes: [WorkbenchNote]
    ) -> Data? {
        let units = enumerateFamilies(snapshot: snapshot)
        guard !units.isEmpty else { return nil }
        let pages = units.map { FamilyGroupSheetPage(unit: $0, notes: notes) }
        return PDFRenderer.renderMultiPagePDF(paperSize: paperSize, pages: pages)
    }

    // MARK: - Family enumeration (batch)

    /// Walk the snapshot and emit one `FamilyUnit` per distinct family.
    ///
    /// Three kinds of family per DESIGN.md §7.9.3:
    /// 1. Couples — every spouse `Relationship`, deduplicated so an edge
    ///    listed as `A→B` and a duplicate `B→A` collapses to one family.
    ///    Children are the intersection of both spouses' children edges.
    /// 2. Single-parent units — a profile that has parent-of edges but no
    ///    spouse relationship. Listed once with their own children.
    /// 3. True singletons — a profile with no edges at all (no spouse, no
    ///    parent-of, not a child of anyone). Renders as a one-person sheet.
    ///
    /// Profiles that are children in some couple/single-parent family are
    /// covered there — they do not produce a separate family on their own
    /// (unless they're also a parent or spouse, in which case they appear
    /// in their own family too).
    ///
    /// Output is ordered deterministically: couples (by header name), then
    /// single-parent units (by parent name), then singletons (by display
    /// name). Stable across calls so test snapshots match.
    static func enumerateFamilies(snapshot: FamilyGraphSnapshot) -> [FamilyUnit] {
        var units: [FamilyUnit] = []
        var coveredAsParent: Set<String> = []

        // 1. Couples — dedupe by unordered pair.
        var seenPairs: Set<UnorderedPair> = []
        let spouseRels = snapshot.relationships.filter { $0.type == .spouse }
        var coupleUnits: [FamilyUnit] = []
        for rel in spouseRels {
            let pair = UnorderedPair(rel.from, rel.to)
            guard !seenPairs.contains(pair) else { continue }
            seenPairs.insert(pair)
            guard let a = snapshot.profiles[rel.from] else { continue }
            let b = snapshot.profiles[rel.to]
            let (father, mother) = orderAsCouple(a: a, b: b, marriage: rel)
            let children = childrenOfCouple(
                fatherID: father?.id,
                motherID: mother?.id,
                in: snapshot
            )
            coupleUnits.append(FamilyUnit(
                father: father,
                mother: mother,
                children: children,
                marriage: rel
            ))
            if let id = father?.id { coveredAsParent.insert(id) }
            if let id = mother?.id { coveredAsParent.insert(id) }
        }
        coupleUnits.sort { $0.headerName.localizedCaseInsensitiveCompare($1.headerName) == .orderedAscending }
        units.append(contentsOf: coupleUnits)

        // 2. Single-parent units — anyone who is a `from` on a parent edge
        //    but didn't participate in a spouse relationship above.
        let parentEdgeFroms = Set(
            snapshot.relationships
                .filter { $0.type == .parent }
                .map(\.from)
        )
        var singleParentUnits: [FamilyUnit] = []
        for parentID in parentEdgeFroms.sorted() where !coveredAsParent.contains(parentID) {
            guard let parent = snapshot.profiles[parentID] else { continue }
            let asMother = parent.gender == .female
            let children = snapshot.childrenOf(parentID)
                .sorted { lhs, rhs in
                    let l = lhs.birthDate?.bestYear ?? Int.max
                    let r = rhs.birthDate?.bestYear ?? Int.max
                    if l != r { return l < r }
                    return lhs.displayName < rhs.displayName
                }
            singleParentUnits.append(FamilyUnit(
                father: asMother ? nil : parent,
                mother: asMother ? parent : nil,
                children: children,
                marriage: nil
            ))
            coveredAsParent.insert(parentID)
        }
        singleParentUnits.sort { $0.headerName.localizedCaseInsensitiveCompare($1.headerName) == .orderedAscending }
        units.append(contentsOf: singleParentUnits)

        // 3. True singletons — no edges at all. Profiles that appear only as
        //    children in some other family are NOT singletons; they're
        //    rendered in that family.
        var hasAnyEdge: Set<String> = []
        for rel in snapshot.relationships {
            hasAnyEdge.insert(rel.from)
            hasAnyEdge.insert(rel.to)
        }
        let singletonUnits = snapshot.profiles.values
            .filter { !hasAnyEdge.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { profile -> FamilyUnit in
                let asMother = profile.gender == .female
                return FamilyUnit(
                    father: asMother ? nil : profile,
                    mother: asMother ? profile : nil,
                    children: [],
                    marriage: nil
                )
            }
        units.append(contentsOf: singletonUnits)

        return units
    }

    /// Internal helper — unordered pair of profile ids, used to dedupe
    /// spouse relationships listed in either direction.
    private struct UnorderedPair: Hashable {
        let a: String
        let b: String
        init(_ x: String, _ y: String) {
            if x <= y { self.a = x; self.b = y } else { self.a = y; self.b = x }
        }
    }

    /// Resolve the family unit that a Family Group Sheet should render for
    /// the supplied profile id. Returns nil only if the id isn't in the
    /// snapshot. See DESIGN.md §7.9.3.
    ///
    /// Precedence:
    /// 1. Subject has a spouse → emit subject + first spouse + their children
    ///    (subject is one of the two parents).
    /// 2. Subject has parents → emit the parents and the subject's siblings
    ///    (subject is one of the children).
    /// 3. Otherwise → emit the subject as a standalone single-person unit.
    static func family(forProfileID profileID: String, in snapshot: FamilyGraphSnapshot) -> FamilyUnit? {
        guard let subject = snapshot.profiles[profileID] else { return nil }

        // Case 1 — subject has a spouse: this is their own marriage.
        if let firstSpouseRel = firstSpouseRelationship(for: profileID, in: snapshot) {
            let otherID = firstSpouseRel.from == profileID ? firstSpouseRel.to : firstSpouseRel.from
            let spouse = snapshot.profiles[otherID]
            let (father, mother) = orderAsCouple(a: subject, b: spouse, marriage: firstSpouseRel)
            let children = childrenOfCouple(
                fatherID: father?.id,
                motherID: mother?.id,
                in: snapshot
            )
            return FamilyUnit(
                father: father,
                mother: mother,
                children: children,
                marriage: firstSpouseRel
            )
        }

        // Case 2 — subject has parents: emit the parents' family.
        let parents = snapshot.parentsOf(profileID)
        if !parents.isEmpty {
            let father = parents.first { $0.gender == .male }
            let mother = parents.first { $0.gender == .female }
            // If gender doesn't disambiguate, fall back to first/second parent.
            let resolvedFather = father ?? (mother == nil ? parents.first : nil)
            let resolvedMother = mother ?? (father == nil && parents.count > 1 ? parents.dropFirst().first : nil)
            let marriage = marriageBetween(
                resolvedFather?.id,
                resolvedMother?.id,
                in: snapshot
            )
            let children = childrenOfCouple(
                fatherID: resolvedFather?.id,
                motherID: resolvedMother?.id,
                in: snapshot
            )
            return FamilyUnit(
                father: resolvedFather,
                mother: resolvedMother,
                children: children,
                marriage: marriage
            )
        }

        // Case 3 — standalone subject. Place them in the slot matching
        // their gender so the column label is sensible; default to father.
        let asMother = subject.gender == .female
        return FamilyUnit(
            father: asMother ? nil : subject,
            mother: asMother ? subject : nil,
            children: [],
            marriage: nil
        )
    }

    // MARK: - Resolution helpers

    private static func firstSpouseRelationship(
        for profileID: String,
        in snapshot: FamilyGraphSnapshot
    ) -> Relationship? {
        snapshot.relationships.first { rel in
            rel.type == .spouse && (rel.from == profileID || rel.to == profileID)
        }
    }

    private static func marriageBetween(
        _ a: String?,
        _ b: String?,
        in snapshot: FamilyGraphSnapshot
    ) -> Relationship? {
        guard let a, let b else { return nil }
        return snapshot.relationships.first { rel in
            guard rel.type == .spouse else { return false }
            return (rel.from == a && rel.to == b) || (rel.from == b && rel.to == a)
        }
    }

    /// Order a couple into (father, mother) slots using gender first, then
    /// the marriage edge's `from`/`to` direction as a fallback.
    private static func orderAsCouple(
        a: Profile,
        b: Profile?,
        marriage: Relationship
    ) -> (Profile?, Profile?) {
        guard let b else {
            return a.gender == .female ? (nil, a) : (a, nil)
        }
        if a.gender == .male || b.gender == .female {
            return (a, b)
        }
        if b.gender == .male || a.gender == .female {
            return (b, a)
        }
        // Gender unknown for both — use the marriage relationship's direction.
        if marriage.from == a.id {
            return (a, b)
        }
        return (b, a)
    }

    /// Children that share both supplied parents. When only one parent id
    /// is supplied, returns that parent's children. Sorted by birth year.
    private static func childrenOfCouple(
        fatherID: String?,
        motherID: String?,
        in snapshot: FamilyGraphSnapshot
    ) -> [Profile] {
        let fatherKids: Set<String> = fatherID
            .map { Set(snapshot.childrenOf($0).map(\.id)) } ?? []
        let motherKids: Set<String> = motherID
            .map { Set(snapshot.childrenOf($0).map(\.id)) } ?? []

        let ids: Set<String>
        switch (fatherID, motherID) {
        case (.some, .some): ids = fatherKids.intersection(motherKids)
        case (.some, .none): ids = fatherKids
        case (.none, .some): ids = motherKids
        case (.none, .none): ids = []
        }

        return ids
            .compactMap { snapshot.profiles[$0] }
            .sorted { lhs, rhs in
                let l = lhs.birthDate?.bestYear ?? Int.max
                let r = rhs.birthDate?.bestYear ?? Int.max
                if l != r { return l < r }
                return lhs.displayName < rhs.displayName
            }
    }

    // MARK: - Source / note collection

    /// All distinct citations referenced by any profile in the unit, in
    /// the order they're first encountered (profiles in unit order, then
    /// fields in `ProfileField.allCases` order, then sources in their
    /// stored order). De-duplicated by structural equality.
    static func collectCitations(for unit: FamilyUnit) -> [Citation] {
        var seen: Set<Citation> = []
        var ordered: [Citation] = []
        for profile in unit.allMembers {
            for field in ProfileField.allCases {
                guard let sources = profile.sources[field] else { continue }
                for source in sources {
                    guard let citation = source.citation, !citation.isEmpty else { continue }
                    if seen.insert(citation).inserted {
                        ordered.append(citation)
                    }
                }
            }
        }
        return ordered
    }

    /// Notes attached to any profile in the unit, sorted by created date
    /// (newest first to mirror the workbench).
    static func collectNotes(for unit: FamilyUnit, from notes: [WorkbenchNote]) -> [WorkbenchNote] {
        let memberIDs = Set(unit.allMembers.map(\.id))
        return notes
            .filter { note in
                if case let .profile(id) = note.attachedTo { return memberIDs.contains(id) }
                return false
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
