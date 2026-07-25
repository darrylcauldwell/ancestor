import Foundation

/// Deterministic mining of a census household roster into proposed FAMILY
/// links for the subject — the "roster → link" half of census absorption
/// (complementing `CensusAgeEnrichment`'s "roster → enrich existing" half).
///
/// A census records a **dwelling, not a family**: Head, Wife, Son and Daughter
/// share the schedule with boarders, lodgers, visitors and servants. So this
/// never "adds everyone" — it reads the "Relationship to Head" column, keeps
/// only the unambiguous nuclear-family rows, and resolves each one's
/// relationship **relative to the subject** (whose own household role is read
/// from the `isTarget` row). Non-family co-residents are excluded outright;
/// ambiguous kin (in-law, grand-, step-, foster, adopted, possessive
/// "wife's …") are left for a human, never auto-classified — consistent with
/// "when in doubt, split".
///
/// Output is a set of PROPOSALS. Nothing is written here: the caller presents
/// them for human confirmation, exactly like the existing household-discovery
/// path. The father/mother-vs-son/daughter distinction is left to the caller,
/// which has each member's `sex`.
public nonisolated struct CensusFamilyLinker {

    /// A proposed family edge: `member` relates to the subject as `relation`.
    public struct Link: Sendable, Equatable {
        public let member: HouseholdMember
        /// The member's relationship TO THE SUBJECT (not to the Head).
        public let relation: CensusRelation
        public init(member: HouseholdMember, relation: CensusRelation) {
            self.member = member
            self.relation = relation
        }
    }

    /// How a roster row relates to the Head, once ambiguous / non-family forms
    /// are filtered out.
    private enum Category { case head, spouse, child, parent, sibling }

    /// Proposed family links for the subject, derived from the household roster.
    ///
    /// The subject's own row is identified by `isTarget`; without exactly one
    /// target row (whose role we can classify) we can't anchor the relative-role
    /// mapping and return `[]` — safe, no guessed links. Only subjects who are
    /// the Head, the Head's spouse, or a child of the Head are mapped here: the
    /// two common research shapes (an adult in their own household; a child in
    /// their parents' household). Any other subject role returns `[]`.
    public static func familyLinks(household: [HouseholdMember]) -> [Link] {
        let targets = household.filter { $0.isTarget == true }
        guard targets.count == 1,
              let subject = targets.first,
              let subjectCat = category(of: subject.relationship)
        else { return [] }

        return household.compactMap { member -> Link? in
            if member.isTarget == true { return nil }   // the subject's own row
            guard !member.name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard let memberCat = category(of: member.relationship),
                  let relation = relate(subject: subjectCat, member: memberCat)
            else { return nil }
            return Link(member: member, relation: relation)
        }
    }

    /// The member's relation to the subject, or nil when it falls outside the
    /// safe nuclear scope (grandparent, uncle/aunt, in-law by position, …).
    private static func relate(subject: Category, member: Category) -> CensusRelation? {
        switch subject {
        case .head:
            // The Head's roster relations ARE the subject's relations.
            switch member {
            case .spouse:  return .spouse
            case .child:   return .child
            case .parent:  return .parent
            case .sibling: return .sibling
            case .head:    return nil        // a second Head → a different family unit
            }
        case .spouse:
            switch member {
            case .head:    return .spouse
            case .child:   return .child     // child of the couple
            case .parent, .sibling, .spouse: return nil   // head's parent/sibling = in-law → skip
            }
        case .child:
            switch member {
            case .head:    return .parent    // Head → the subject's father/mother
            case .spouse:  return .parent    // Head's wife → the subject's mother (step- filtered out earlier)
            case .child:   return .sibling   // another child of the Head → sibling
            case .parent:  return nil        // Head's parent = the subject's grandparent → out of scope
            case .sibling: return nil        // Head's sibling = the subject's uncle/aunt → out of scope
            }
        case .parent, .sibling:
            return nil                        // senior/lateral subject → out of MVP scope
        }
    }

    /// Classify a roster "Relationship to Head" string into a nuclear category,
    /// or nil to EXCLUDE it (non-family co-resident, or ambiguous kin we won't
    /// auto-link). Order matters: modifier forms (possessive, in-law, grand-,
    /// step-, foster, adopted) and non-family roles are filtered BEFORE the base
    /// matches, so "grandson" isn't read as a child nor "son-in-law" as a son.
    private static func category(of role: String) -> Category? {
        let r = role.lowercased().trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return nil }
        // Possessive ("wife's sister", "son's wife") — a relation of a relation.
        if r.contains("'") { return nil }
        // Ambiguous kin — present in the dwelling, but never auto-classified.
        if r.contains("in law") || r.contains("in-law") { return nil }
        if r.contains("grand") || r.contains("step") || r.contains("foster") || r.contains("adopt") { return nil }
        // Non-family co-residents (reuse the enrichment path's vetted list).
        if CensusAgeEnrichment.isNonFamilyRole(r) { return nil }
        // Base nuclear roles.
        if r.contains("head") { return .head }
        if r.contains("wife") || r.contains("husband") { return .spouse }
        if r.contains("son") || r.contains("daughter") { return .child }
        if r.contains("father") || r.contains("mother") { return .parent }
        if r.contains("brother") || r.contains("sister") { return .sibling }
        return nil
    }
}
