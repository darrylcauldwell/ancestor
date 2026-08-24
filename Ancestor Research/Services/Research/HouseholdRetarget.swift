import Foundation
import AncestorKit

/// Re-derive the `isTarget` marking on a census household roster for the
/// profile whose event actually holds it.
///
/// A roster is fetched ONCE (from whichever family member's record the
/// detail page was loaded through) and then folded onto several relatives'
/// events; copying the fetched record's own principal marking with it puts
/// "this is you" on the wrong person (owner dogfood 2026-08-24: John
/// Wheeldon jr's 1861 event arrived with his MOTHER marked as the target,
/// because the household was fetched via Ruth's record URL).
///
/// Matching mirrors the #28 rules — given-name prefix + surname suffix on
/// either the maiden or married surname — plus birth-year discrimination,
/// because a same-named father and son in one household (John 37 / John 12)
/// is common. When no single member can be identified, ALL flags are
/// cleared: an unmarked roster is honest, a wrongly-marked one misleads.
nonisolated enum HouseholdRetarget {

    static func retarget(
        _ household: [HouseholdMember], to profile: Profile
    ) -> [HouseholdMember] {
        guard !household.isEmpty else { return household }
        let targetIndex = matchIndex(
            in: household,
            givenName: profile.firstName ?? "",
            maidenSurname: profile.lastName ?? "",
            marriedSurname: profile.marriedSurname ?? "",
            birthYear: profile.birthDate?.bestYear)
        return household.enumerated().map { index, m in
            HouseholdMember(
                name: m.name, relationship: m.relationship,
                age: m.age, birthYear: m.birthYear,
                birthPlace: m.birthPlace, occupation: m.occupation,
                sex: m.sex, maritalStatus: m.maritalStatus,
                birthCounty: m.birthCounty,
                isTarget: index == targetIndex ? true : nil)
        }
    }

    /// The single member who can be the subject, or nil when none or several
    /// qualify. Name-eligible members are filtered first; if more than one
    /// remains (father + son), the subject's birth year must discriminate
    /// (closest match, and within ±3 — census-age slop).
    ///
    /// #33: also the marking core for `pendingFactHousehold` — MCP-submitted
    /// rosters used name matching alone, so "John Wheeldon 37 / John Wheeldon
    /// 12" both arrived marked as the subject. One selection rule, two
    /// callers, no drift.
    static func matchIndex(
        in household: [HouseholdMember],
        givenName: String, maidenSurname: String, marriedSurname: String,
        birthYear: Int?
    ) -> Int? {
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0 == " " }
                .split(separator: " ").joined(separator: " ")
        }
        let given = norm(givenName).split(separator: " ").first.map(String.init) ?? ""
        let maiden = norm(maidenSurname)
        let married = norm(marriedSurname)
        guard !given.isEmpty, !maiden.isEmpty || !married.isEmpty else { return nil }

        let eligible = household.indices.filter { i in
            let name = norm(household[i].name)
            guard name.hasPrefix(given) else { return false }
            return (!maiden.isEmpty && name.hasSuffix(maiden))
                || (!married.isEmpty && name.hasSuffix(married))
        }
        if eligible.count == 1 { return eligible[0] }
        guard eligible.count > 1, let profileYear = birthYear else { return nil }

        let scored = eligible.compactMap { i -> (Int, Int)? in
            guard let by = household[i].birthYear else { return nil }
            let delta = abs(by - profileYear)
            return delta <= 3 ? (i, delta) : nil
        }
        // Unique best only — two members equally close is unresolvable.
        let best = scored.min { $0.1 < $1.1 }
        guard let best, scored.filter({ $0.1 == best.1 }).count == 1 else { return nil }
        return best.0
    }
}
