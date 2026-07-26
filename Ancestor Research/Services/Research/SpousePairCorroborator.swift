import Foundation

/// #CPC-Change1 — the pure joiner for cross-profile corroboration
/// (`AncestorApp/CROSS_PROFILE_CORROBORATION_SPEC.md`).
///
/// Two tree-linked spouses each independently hold a marriage-index record
/// citing the same GRO reference. This corroborator answers, deterministically
/// and from data alone, the spec's two questions:
///
///   1. Record-pair unity — are the two records two sides of ONE registered
///      marriage? (tier: `.reciprocal` when both post-Mar-1912 spouse-surname
///      columns cross-agree; `.samePagePrior` when a column is absent and the
///      tree edge supplies the prior. A present-but-CONTRADICTING column is a
///      contradiction, never a downgrade.)
///   2. Couple identity — is that marriage THIS couple's? (anchor: `.strong`
///      when a party's own recorded birth window validates the marriage year
///      or a linked child's birth-MMN matches the maiden side; `.weak` when
///      only a death-year precedence constraint binds; `.none` otherwise.)
///
/// PURE by construction: no database, no wire, no model — the I/O halves
/// (`CorroborationSweep`, the in-run annotation step) resolve records,
/// exclusions, and the district canonicaliser, and pass everything in as
/// data. Fail closed, refuse ambiguity (spec invariant (c)): `.ambiguous` is
/// terminal for the pass and is never degraded to a weaker emission.
nonisolated enum SpousePairCorroborator {

    // MARK: - Types

    /// One member of the spouse pair, as the caller resolved them.
    struct PairMember {
        let profileID: String
        /// Recorded surname PLUS derived maiden surname(s) — marriage indexes
        /// file a bride under her pre-marriage surname while this tree often
        /// stores wives under married surname, so every surname comparison in
        /// the ladder tests against the set (spec §1). Uppercased by `init`.
        let surnames: Set<String>
        /// PROFILE-RECORDED birth window only — never relative-derived
        /// fallbacks (a 27-year child-derived window would validate almost
        /// any marriage year and make the strong anchor vacuous; spec §1).
        let recordedBirthYearRange: ClosedRange<Int>?
        let deathYear: Int?
        /// Human-readable name for trace/card text (a raw profile id on a
        /// review card is unreadable). Falls back to the id.
        let displayLabel: String?

        var label: String { displayLabel ?? profileID }

        init(
            profileID: String,
            surnames: Set<String>,
            recordedBirthYearRange: ClosedRange<Int>? = nil,
            deathYear: Int? = nil,
            displayLabel: String? = nil
        ) {
            self.profileID = profileID
            self.surnames = Set(surnames.map {
                $0.trimmingCharacters(in: .whitespaces).uppercased()
            }.filter { !$0.isEmpty })
            self.recordedBirthYearRange = recordedBirthYearRange
            self.deathYear = deathYear
            self.displayLabel = displayLabel
        }
    }

    /// A linked child's birth-registration evidence, caller-resolved (the
    /// `childEvidenceMMNLookup` read path). An MMN that matches exactly one
    /// member's surname set — and not the other's — uniquely identifies the
    /// maiden side and is a strong anchor.
    struct ChildMMNAnchor {
        let mothersMaidenName: String
        let birthYear: Int?
    }

    /// Caller-resolved exclusions (dismissed leads, discarded evidence, open
    /// disputes) — data in, so rejection memory and CL6 parity are honoured
    /// without the corroborator touching a database.
    struct Exclusions {
        let excludedSubjectRecordIDs: Set<String>
        let excludedPartnerRecordIDs: Set<String>
        /// An open spouseIdentity/timeline dispute on either member, or an
        /// open fieldValue dispute on the edge's marriage fields.
        let hasOpenDispute: Bool

        static let none = Exclusions(
            excludedSubjectRecordIDs: [], excludedPartnerRecordIDs: [],
            hasOpenDispute: false
        )
    }

    enum Tier: String {
        case reciprocal
        case samePagePrior
    }

    enum Anchor: Equatable {
        case strong(String)
        case weak(String)
        case none

        var isStrong: Bool { if case .strong = self { return true }; return false }
    }

    struct Finding {
        let edgeID: String
        let subjectProfileID: String
        let partnerProfileID: String
        let canonicalKey: String
        let tier: Tier
        let anchor: Anchor
        let subjectRecordID: String
        let partnerRecordID: String
        /// ALL record ids that collapsed into each representative
        /// (transcription variants / re-fetches of one index line,
        /// representative included). Lead resolution must walk these — a
        /// duplicate transcription's lead staying open after acceptance was
        /// observed live on the demonstrator (Mary's second 2130a row).
        let subjectCollapsedRecordIDs: [String]
        let partnerCollapsedRecordIDs: [String]
        /// Year-granularity event span. GRO quarterly indexes include late
        /// clergy returns, so `earliest` is widened by one quarter — a MAR
        /// quarter opens into the prior year (spec §1).
        let proposedEarliestYear: Int
        let proposedLatestYear: Int
        /// Epistemic label for the citation: "registered Dec quarter 1915".
        let registrationLabel: String
        /// Canonical district, empty when the index carried none.
        let proposedLocation: String?
        /// Guard-by-guard reasoning, for the review card and the sweep log.
        let trace: [String]
    }

    enum Outcome {
        case found(Finding)
        /// Includes near-miss diagnostics ("near-miss:" prefix) — same
        /// year|volume|page but district/quarter drift; surfaced for
        /// observation, never auto-joined.
        case none(reason: String)
        /// Terminal for the pass — never degraded to a weaker emission.
        case ambiguous(reason: String)
    }

    // MARK: - Entry point

    static func corroborate(
        subjectMarriages: [(id: String, record: MarriageRecord)],
        partnerMarriages: [(id: String, record: MarriageRecord)],
        subject: PairMember,
        partner: PairMember,
        childMMNAnchors: [ChildMMNAnchor] = [],
        edgeID: String,
        exclusions: Exclusions = .none,
        districtResolver: ((String) -> String?)? = nil
    ) -> Outcome {
        var trace: [String] = []

        // Guard 0 — CL6 parity: never argue with an open dispute.
        if exclusions.hasOpenDispute {
            return .none(reason: "open dispute on a pair member or the edge")
        }

        // Guard 1 — rejection memory: drop excluded records before keying.
        let subjectSide = subjectMarriages.filter {
            !exclusions.excludedSubjectRecordIDs.contains($0.id)
        }
        let partnerSide = partnerMarriages.filter {
            !exclusions.excludedPartnerRecordIDs.contains($0.id)
        }
        guard !subjectSide.isEmpty, !partnerSide.isEmpty else {
            return .none(reason: "no marriage records on both sides after exclusions")
        }

        // Guard 2 — canonical keying + per-side collapse (Decision 13):
        // dedup by record id, collapse same-key entries whose identity
        // agrees, drop keys with conflicting identities on one side.
        guard let subjectByKey = collapsePerSide(subjectSide, districtResolver: districtResolver, trace: &trace),
              let partnerByKey = collapsePerSide(partnerSide, districtResolver: districtResolver, trace: &trace)
        else {
            return .none(reason: "no keyable marriage records (vol/page missing)")
        }

        // Guard 3 — unique shared canonical key.
        let shared = Set(subjectByKey.keys).intersection(partnerByKey.keys)
        if shared.isEmpty {
            if let nearMiss = nearMissReason(
                subjectSide: subjectSide, partnerSide: partnerSide,
                districtResolver: districtResolver
            ) {
                return .none(reason: nearMiss)
            }
            return .none(reason: "no shared reference key")
        }
        guard shared.count == 1, let key = shared.first,
              let subjectEntry = subjectByKey[key], let partnerEntry = partnerByKey[key]
        else {
            return .ambiguous(reason: "\(shared.count) distinct shared reference keys — refusing all (when in doubt, split)")
        }
        trace.append("shared canonical key \(key)")

        guard let components = SamePageCouplePairing.canonicalComponents(
            subjectEntry.record, districtResolver: districtResolver
        ) else {
            return .none(reason: "shared entry lost its key components")
        }
        let marriageYear = components.year

        // Guard 4 — year sanity (Decision 12). Margins are marriage-specific:
        // marriages are indexed in the ceremony's quarter, so the death guard
        // takes NO lag margin; the birth guards refuse only impossibility
        // (minMarriageAge floor / maxAdultAgeYears ceiling over the recorded
        // window's most permissive reading).
        for member in [subject, partner] {
            if let death = member.deathYear, marriageYear > death {
                return .none(reason: "marriage \(marriageYear) after \(member.label)'s death \(death)")
            }
            if let birth = member.recordedBirthYearRange {
                if marriageYear - birth.lowerBound < IdentityConstraints.minMarriageAge {
                    return .none(reason: "marriage \(marriageYear) before \(member.label) could be \(IdentityConstraints.minMarriageAge)")
                }
                if marriageYear - birth.upperBound > IdentityConstraints.maxAdultAgeYears {
                    return .none(reason: "marriage \(marriageYear) beyond \(member.label)'s plausible adult span")
                }
            }
        }
        trace.append("year sanity passed for both members")

        // Guard 5 — tier assignment (spec §1, Question 1).
        let tier: Tier
        switch assessTier(
            subjectRecord: subjectEntry.record, partnerRecord: partnerEntry.record,
            subject: subject, partner: partner, trace: &trace
        ) {
        case .contradiction(let reason):
            return .none(reason: reason)
        case .tier(let t):
            tier = t
        }

        // Guard 6 — anchor assessment (spec §1, Question 2).
        let anchor = assessAnchor(
            marriageYear: marriageYear, subject: subject, partner: partner,
            childMMNAnchors: childMMNAnchors, trace: &trace
        )

        // Build the finding. MAR-quarter registrations widen into the prior
        // year (late clergy returns).
        let quarter = components.quarter
        let earliest = quarter == "MAR" ? marriageYear - 1 : marriageYear
        let label: String
        if quarter.isEmpty {
            label = "registered \(marriageYear)"
        } else {
            let title = quarter.prefix(1) + quarter.dropFirst().lowercased()
            label = "registered \(title) quarter \(marriageYear)"
        }

        return .found(Finding(
            edgeID: edgeID,
            subjectProfileID: subject.profileID,
            partnerProfileID: partner.profileID,
            canonicalKey: key,
            tier: tier,
            anchor: anchor,
            subjectRecordID: subjectEntry.id,
            partnerRecordID: partnerEntry.id,
            subjectCollapsedRecordIDs: subjectEntry.allIDs,
            partnerCollapsedRecordIDs: partnerEntry.allIDs,
            proposedEarliestYear: earliest,
            proposedLatestYear: marriageYear,
            registrationLabel: label,
            proposedLocation: components.district.isEmpty ? nil : components.district,
            trace: trace
        ))
    }

    // MARK: - Guard 2: per-side collapse

    /// Returns nil when NO record on the side could be keyed at all;
    /// otherwise a key → representative map with Decision-13 collapse
    /// applied (conflicting identities at one key drop that key).
    private static func collapsePerSide(
        _ side: [(id: String, record: MarriageRecord)],
        districtResolver: ((String) -> String?)?,
        trace: inout [String]
    ) -> [String: (id: String, record: MarriageRecord, allIDs: [String])]? {
        var grouped: [String: [(id: String, record: MarriageRecord)]] = [:]
        var keyedAny = false
        for entry in side {
            guard let key = SamePageCouplePairing.canonicalReferenceKey(
                entry.record, districtResolver: districtResolver
            ) else { continue }
            keyedAny = true
            grouped[key, default: []].append(entry)
        }
        guard keyedAny else { return nil }

        var byKey: [String: (id: String, record: MarriageRecord, allIDs: [String])] = [:]
        for (key, entries) in grouped {
            // Dedup re-fetches of the same row id — but keep every DISTINCT
            // caller id (evidence rows carry their own ids for the same
            // underlying row) so lead resolution can walk all of them.
            var seen = Set<String>()
            var unique: [(id: String, record: MarriageRecord)] = []
            for e in entries where seen.insert(e.record.common.id).inserted {
                unique.append(e)
            }
            // Collapse transcription variants of one index line: surnames
            // must agree, given names must agree on first token (either may
            // be absent). Anything else — e.g. two sisters' lines sharing
            // the page — is a same-side ambiguity: drop the key.
            let surnames = Set(unique.compactMap { normToken($0.record.common.surname) })
            let givenFirstTokens = Set(unique.compactMap { firstToken($0.record.common.givenName) })
            guard surnames.count <= 1, givenFirstTokens.count <= 1 else {
                trace.append("dropped key \(key): conflicting identities on one side")
                continue
            }
            let allIDs = entries.map(\.id).reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            byKey[key] = (id: unique[0].id, record: unique[0].record, allIDs: allIDs)
        }
        return byKey
    }

    // MARK: - Guard 3: near-miss diagnostics

    private static func nearMissReason(
        subjectSide: [(id: String, record: MarriageRecord)],
        partnerSide: [(id: String, record: MarriageRecord)],
        districtResolver: ((String) -> String?)?
    ) -> String? {
        for s in subjectSide {
            guard let sPage = SamePageCouplePairing.canonicalPageKey(s.record, districtResolver: districtResolver),
                  let sFull = SamePageCouplePairing.canonicalReferenceKey(s.record, districtResolver: districtResolver)
            else { continue }
            for p in partnerSide {
                guard let pPage = SamePageCouplePairing.canonicalPageKey(p.record, districtResolver: districtResolver),
                      let pFull = SamePageCouplePairing.canonicalReferenceKey(p.record, districtResolver: districtResolver)
                else { continue }
                if sPage == pPage && sFull != pFull {
                    let sd = s.record.district ?? "—"
                    let pd = p.record.district ?? "—"
                    return "near-miss: same year/volume/page but full keys differ (district/quarter drift: \"\(sd)\" vs \"\(pd)\") — observe, never auto-join"
                }
            }
        }
        return nil
    }

    // MARK: - Guard 5: tier

    private enum TierAssessment {
        case tier(Tier)
        case contradiction(String)
    }

    /// A spouse column is compared as its LAST whitespace token (FreeBMD
    /// post-1912 columns are surname-only; fuller strings still end in the
    /// surname) against the other party's surname set at the gate-4
    /// similarity threshold.
    private static func assessTier(
        subjectRecord: MarriageRecord,
        partnerRecord: MarriageRecord,
        subject: PairMember,
        partner: PairMember,
        trace: inout [String]
    ) -> TierAssessment {
        let subjectColumn = lastToken(subjectRecord.spouseName)
        let partnerColumn = lastToken(partnerRecord.spouseName)

        // A PRESENT column that contradicts the other party's surname set is
        // a contradiction — it names a third party — regardless of tier.
        if let c = subjectColumn, !matchesSet(c, partner.surnames) {
            return .contradiction("subject-side spouse column \"\(c)\" contradicts partner surnames \(partner.surnames.sorted())")
        }
        if let c = partnerColumn, !matchesSet(c, subject.surnames) {
            return .contradiction("partner-side spouse column \"\(c)\" contradicts subject surnames \(subject.surnames.sorted())")
        }

        if subjectColumn != nil && partnerColumn != nil {
            trace.append("reciprocal spouse columns agree")
            return .tier(.reciprocal)
        }

        // Same-page-prior: at least one column absent. The same-page-inferred
        // partner surname, where present, must not contradict either.
        for (inferred, against, side) in [
            (lastToken(subjectRecord.partnerSurnameFromSamePage), partner.surnames, "subject"),
            (lastToken(partnerRecord.partnerSurnameFromSamePage), subject.surnames, "partner"),
        ] {
            if let inferred, !matchesSet(inferred, against) {
                return .contradiction("\(side)-side same-page partner \"\(inferred)\" contradicts the pair")
            }
        }
        trace.append("same-page prior (spouse column absent on at least one side)")
        return .tier(.samePagePrior)
    }

    // MARK: - Guard 6: anchor

    private static func assessAnchor(
        marriageYear: Int,
        subject: PairMember,
        partner: PairMember,
        childMMNAnchors: [ChildMMNAnchor],
        trace: inout [String]
    ) -> Anchor {
        // Strong (a): a party's recorded birth window validates the marriage
        // year. Guard 4 already refused impossibilities, so presence of a
        // recorded window IS validation.
        for member in [subject, partner] where member.recordedBirthYearRange != nil {
            let detail = "birth-window(\(member.label))"
            trace.append("strong anchor: \(detail)")
            return .strong(detail)
        }

        // Strong (b): a linked child's birth-MMN uniquely matches the maiden
        // side — the MMN must match exactly one member's surname set (the
        // mother's maiden side) and not the other's, with the child's birth
        // in a plausible span at/after the marriage.
        for child in childMMNAnchors {
            guard let mmn = lastToken(child.mothersMaidenName) else { continue }
            if let birthYear = child.birthYear {
                guard birthYear >= marriageYear, birthYear <= marriageYear + 25 else { continue }
            }
            let matchesSubject = matchesSet(mmn, subject.surnames)
            let matchesPartner = matchesSet(mmn, partner.surnames)
            if matchesSubject != matchesPartner {
                let detail = "child-MMN(\(child.mothersMaidenName))"
                trace.append("strong anchor: \(detail)")
                return .strong(detail)
            }
        }

        // Weak: a death year the marriage actually precedes (guard 4 passed).
        for member in [subject, partner] {
            if let death = member.deathYear {
                let detail = "death-year precedence (\(member.label) d.\(death))"
                trace.append("weak anchor: \(detail)")
                return .weak(detail)
            }
        }

        trace.append("no anchor: neither party's dated facts test the marriage year")
        return .none
    }

    // MARK: - Name helpers

    private static func normToken(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces).uppercased(), !t.isEmpty else { return nil }
        return t
    }

    private static func firstToken(_ s: String?) -> String? {
        guard let n = normToken(s) else { return nil }
        return n.components(separatedBy: .whitespaces).first
    }

    private static func lastToken(_ s: String?) -> String? {
        guard let n = normToken(s) else { return nil }
        return n.components(separatedBy: .whitespaces).last
    }

    private static func matchesSet(_ token: String, _ surnames: Set<String>) -> Bool {
        surnames.contains { ScoringRules.nameSimilarity(token, $0) >= 0.7 }
    }
}
