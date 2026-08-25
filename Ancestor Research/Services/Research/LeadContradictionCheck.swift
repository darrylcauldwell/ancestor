import Foundation
import AncestorKit

/// #25 — display-time check: is a Triage lead already CONTRADICTED by the
/// facts applied to its subject since the lead was minted?
///
/// Leads are scored once, at discovery; the profile keeps moving. A census
/// lead dated after the subject's applied death, or a death lead for someone
/// the tree now shows dying in a different year, is Triage cruft the human
/// has to reject by hand (owner dogfood 2026-08-24: John Wheeldon sr's 1891
/// census lead, scored eleven days before his Sep 1881 death was applied).
///
/// Pure and I/O-free — same contract as `LeadFilter` — so it can run per row
/// at display time against the CURRENT applied vitals. It composes the same
/// `IdentityConstraints` rules the scorer's impossibility checks use, so
/// display and scoring can never disagree about what "contradicted" means.
/// Suppression is display-side only: the lead's persisted status is never
/// touched (dismiss/restore own that).
nonisolated enum LeadContradictionCheck {

    /// A human-readable reason this lead cannot be its subject, or nil when
    /// nothing applied contradicts it.
    static func contradiction(lead: Lead, profile: Profile?) -> String? {
        guard let profile else { return nil }
        let birthYear = profile.birthDate?.bestYear
        let deathYear = profile.deathDate?.bestYear
        let kind = eventKind(of: lead)
        let eventYear = eventYear(of: lead)

        // A death ends a life: census/marriage (or any dated event that is
        // not itself death-shaped) after the applied death is a namesake.
        if kind != "death",
           IdentityConstraints.eventAfterDeath(eventYear: eventYear, deathYear: deathYear),
           let ey = eventYear, let dy = deathYear {
            return "died \(dy) — a \(kind == "other" ? "record" : kind) in \(ey) is a namesake"
        }

        // A person dies once: a death-shaped lead whose year is far from the
        // applied death year is a different person.
        if kind == "death" {
            let leadDeath = lead.deathYear ?? eventYear
            if IdentityConstraints.distinctDeaths(leadDeath, deathYear),
               let ly = leadDeath, let dy = deathYear {
                return "died \(dy) — a death in \(ly) is a different person"
            }
        }

        // Nothing is recorded about a person before they exist: an event
        // clearly predating the applied birth is a namesake. Guard with the
        // same margin the constraints use for born-after-death jitter.
        if kind == "census" || kind == "marriage",
           let ey = eventYear, let by = birthYear, ey < by - 2 {
            return "born \(by) — a \(kind) in \(ey) predates their birth"
        }

        return nil
    }

    /// Coarse event-kind bucket from the lead's evidence/relationship text —
    /// heuristic inherited from the retired `LeadDiscoveryEngine.eventKind`.
    static func eventKind(of lead: Lead) -> String {
        let hay = (lead.evidence + " " + (lead.relationship ?? "")).lowercased()
        if hay.contains("marriage") || hay.contains("spouse") { return "marriage" }
        if hay.contains("death") || hay.contains("probate") || hay.contains("burial") { return "death" }
        if hay.contains("census") { return "census" }
        if hay.contains("birth") || hay.contains("christen") || hay.contains("baptis") { return "birth" }
        return "other"
    }

    /// The lead's own event year: household-lead ids carry the census year as
    /// their suffix (`lead_hh_<NAME>_<year>`); otherwise the first plausible
    /// year token in the evidence text.
    static func eventYear(of lead: Lead) -> Int? {
        if lead.id.hasPrefix("lead_hh_"),
           let suffix = lead.id.split(separator: "_").last,
           let year = Int(suffix), (1500...2100).contains(year) {
            return year
        }
        if let match = lead.evidence.firstMatch(of: #/\b(1[5-9]\d\d|20\d\d)\b/#),
           let year = Int(match.output.1) {
            return year
        }
        return nil
    }
}
