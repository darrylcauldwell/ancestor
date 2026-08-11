import Foundation
import AncestorKit

/// Slice E (LOCATION_MODEL_SPEC Part II) — the "un-muddle": a one-pass normaliser
/// that proposes structured location codes for profiles whose birth/death place
/// is freeform text carrying no code yet, so the whole tree converges on the one
/// place authority the picker (Slice D) now writes for new input.
///
/// **Deterministic tier only, and review-gated.** It resolves each freeform place
/// through the canonical `PlaceResolver` / `LocationGazetteer` and proposes a code
/// ONLY on an unambiguous hit; genuinely ambiguous or unknown text is REPORTED as
/// *left-freeform*, never resolved ("when in doubt, split"). Nothing is written —
/// `report(for:)` is pure and produces a dry-run; a code lands only when the user
/// approves a specific proposal via `apply(_:in:)`. **Display strings are
/// preserved** — only the structured `*_location_code` column is filled.
///
/// The freeform tail this tier declines is exactly where a future **local-model
/// proposer** plugs in (per the spec: each model proposal still verified against
/// the authority and human-reviewed — never a blind batch write). That tier is a
/// deliberately gated follow-up; the deterministic backbone here is what makes it
/// safe to add, and already covers the structured / Chapman-suffixed bulk.
nonisolated enum LocationNormalizer {

    /// How a field's proposal was reached.
    enum Method: String, Sendable, Codable {
        /// Unambiguously resolved to a gazetteer entry — apply-eligible.
        case deterministic
        /// Resolver declined (ambiguous or unknown) — reported, not applied. The
        /// model tier's future input.
        case leftFreeform
    }

    /// One field's normalisation proposal. `confident` (deterministic + a code)
    /// is the only apply-eligible shape.
    struct Proposal: Sendable, Identifiable, Equatable {
        let id: String            // "profileID|fieldRawValue" — stable, dedupes
        let profileID: String
        let profileName: String
        let field: ProfileField   // .birthLocation | .deathLocation
        let currentText: String
        let proposedCode: String?
        let proposedDisplay: String?
        let method: Method

        var confident: Bool { method == .deterministic && proposedCode != nil }
    }

    /// A dry-run report over a set of profiles.
    struct Report: Sendable {
        var proposals: [Proposal]
        /// Freeform, code-less location fields examined.
        var scannedFields: Int

        var deterministic: [Proposal] { proposals.filter { $0.method == .deterministic } }
        var leftFreeform: [Proposal] { proposals.filter { $0.method == .leftFreeform } }
        var deterministicCount: Int { deterministic.count }
        var leftFreeformCount: Int { leftFreeform.count }
    }

    /// Build the dry-run report. Pure: reads only the profiles and the bundled
    /// gazetteer, writes nothing. Skips soft-deleted profiles, empty fields, and
    /// fields that already carry a code (nothing to normalise).
    static func report(for profiles: [Profile], gazetteer: LocationGazetteer = .shared) -> Report {
        var proposals: [Proposal] = []
        var scanned = 0
        for p in profiles where !p.isDeleted {
            let fields: [(ProfileField, String?, String?)] = [
                (.birthLocation, p.birthLocation, p.birthLocationCode),
                (.deathLocation, p.deathLocation, p.deathLocationCode),
            ]
            for (field, text, code) in fields {
                guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
                guard (code ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                scanned += 1
                let pid = "\(p.id)|\(field.rawValue)"
                if let id = PlaceResolver.resolve(placeText: raw, gazetteer: gazetteer),
                   let entry = gazetteer.entry(forID: id) {
                    proposals.append(Proposal(
                        id: pid, profileID: p.id, profileName: p.displayName, field: field,
                        currentText: raw, proposedCode: id, proposedDisplay: entry.displayName,
                        method: .deterministic))
                } else {
                    proposals.append(Proposal(
                        id: pid, profileID: p.id, profileName: p.displayName, field: field,
                        currentText: raw, proposedCode: nil, proposedDisplay: nil,
                        method: .leftFreeform))
                }
            }
        }
        return Report(proposals: proposals, scannedFields: scanned)
    }

    /// Errors from `apply`.
    enum ApplyError: Error, Equatable {
        /// A non-confident proposal reached apply — a guard against writing a
        /// left-freeform (declined) proposal.
        case notConfident
    }

    /// Commit ONE approved proposal: fill only that field's location code,
    /// preserving the display string and the other field's code. Refuses a
    /// non-confident proposal. Human-in-the-loop — a caller invokes this per
    /// proposal the user ticked, never in bulk without review.
    static func apply(_ proposal: Proposal, in db: ProjectDatabase) throws {
        guard proposal.confident, let code = proposal.proposedCode else {
            throw ApplyError.notConfident
        }
        try db.setProfileLocationCode(profileID: proposal.profileID, field: proposal.field, code: code)
    }
}
