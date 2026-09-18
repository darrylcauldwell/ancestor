import Foundation

/// Decision-core pair follow-up — the tree-wide static twin of the
/// run-time exclusivity pass.
///
/// The pipeline's exclusivity pass only heals a profile when that profile is
/// re-researched; every profile not re-run since the decision-core rules
/// shipped can still hold mutually exclusive `fact` verdicts (the founding
/// specimens: Harry Marshall's 1999+2006 namesake probates, Mary E Land's two
/// marriages, Elizabeth Shaw's eleven births). This audit runs the SAME
/// deterministic rules (`RecordScorer.applyExclusivityAcrossStore` — slots,
/// registration-twin candidates, familyContext discriminator, ghost rivals)
/// over each profile's stored evidence with an empty batch, and reports the
/// facts the pass would demote. The one-click fix applies exactly those
/// demotions through `saveEvidence` (verdict-only; `user_status` and
/// `applied_at` preserved) — so Health and a re-research run always agree.
nonisolated struct ContradictoryFactsAudit {

    /// One demoted fact, shaped for display.
    struct DemotedFact: Identifiable, Sendable, Equatable {
        let sourceRecordID: String
        /// Human slot label ("death", "census 1891", "marriage").
        let slotLabel: String
        /// Best display line for the record — the stored citation when
        /// present, else the scorer summary.
        let detail: String
        /// The exclusivity reason the pass attached.
        let reason: String
        /// This record's content is ON THE TREE. The pass would still demote
        /// it, and the user needs to know that, but the one-click must not do
        /// it for them — see `Demotions.appliedHeldBack`.
        let isApplied: Bool
        var id: String { sourceRecordID }
    }

    /// What the pass would do, split by whether it is safe to do automatically.
    struct Demotions: Sendable {
        /// The pass would demote these and none is on the tree — the one-click
        /// may write them.
        let demotable: [ScoredRecord]
        /// The pass would demote these too, but their content is APPLIED to a
        /// profile. Demoting the evidence under an applied fact asserts the
        /// TREE is wrong, which is a genealogical judgement and the user's to
        /// make; a Health one-click that did it silently would leave a
        /// confirmed fact on the profile with its backing quietly reduced to a
        /// lead, days after the fact, with nothing linking the two. Reported,
        /// never written.
        let appliedHeldBack: [ScoredRecord]

        var all: [ScoredRecord] { demotable + appliedHeldBack }
        var isEmpty: Bool { demotable.isEmpty && appliedHeldBack.isEmpty }
    }

    /// A profile whose accepted facts contradict each other.
    struct Finding: Identifiable, Sendable, Equatable {
        let profileID: String
        let profileName: String
        let demotions: [DemotedFact]
        var id: String { profileID }

        /// Rows the one-click will NOT touch because they are on the tree.
        var appliedHeldBack: [DemotedFact] { demotions.filter(\.isApplied) }
        /// Rows the one-click will write.
        var demotable: [DemotedFact] { demotions.filter { !$0.isApplied } }

        /// Compact per-slot summary: "census 1891 ×3 · probate ×2".
        var slotSummary: String {
            var counts: [(label: String, count: Int)] = []
            for d in demotions {
                if let i = counts.firstIndex(where: { $0.label == d.slotLabel }) {
                    counts[i].count += 1
                } else {
                    counts.append((d.slotLabel, 1))
                }
            }
            return counts
                .map { $0.count == 1 ? $0.label : "\($0.label) ×\($0.count)" }
                .joined(separator: " · ")
        }
    }

    /// The stored fact rows the run-time pass would demote — with their
    /// appended `.exclusivity` gate, ready to re-persist. Empty when the
    /// store is internally consistent.
    /// `profile` is REQUIRED, with no default, on purpose. It is what
    /// `EvidenceRecord.wasApplied(to:)` needs for its citation-fingerprint
    /// fallback, and several apply paths (parent-unlock among them) land a
    /// record's facts WITHOUT stamping `applied_at` — so `appliedAt != nil`
    /// alone under-counts. A defaulted parameter is how the applied guard came
    /// to be missing here in the first place; making every call site name it
    /// forces the decision to be visible. Pass `nil` only when there genuinely
    /// is no profile in hand, and accept that the guard then degrades to the
    /// `applied_at` stamp.
    static func demotions(in evidence: [EvidenceRecord], profile: Profile?) -> Demotions {
        let live = evidence.filter { $0.userStatus != .discarded }
        // The guard, hoisted: it decides who may ACT on the verdict below, and
        // — since the contest is over live CLAIMS — who is in the contest.
        let appliedIDs = Set(live.filter { $0.wasApplied(to: profile) }.map(\.sourceRecordID))
        // An APPLIED row is a claim on the tree whatever the scorer last
        // decided about it, so it contests its slot even at `.lead`. Contesting
        // `.fact` rows alone meant a slot holding an applied fact beside an
        // applied row the pass had since demoted read as UNRIVALLED, and the
        // contradiction went unreported (owner dogfood 2026-08-25: Emma
        // Gladwin's Dec-1867 7b/513 and Dec-1865 7b/515 birth registrations,
        // both cited on her birth date at once). Such a row can only ever be
        // REPORTED — the split below keeps every applied row out of `demotable`.
        // `applyExclusivity` builds its slots from `verdict == .fact` alone, so
        // an applied `.lead` has to enter the contest AS a claim or it is
        // filtered straight back out and the slot reads unrivalled again.
        // Re-stamping is safe here because the split below reads `appliedIDs`,
        // not the verdict, when deciding what the one-click may write.
        let facts = live
            .filter { $0.verdict == .fact || appliedIDs.contains($0.sourceRecordID) }
            .map { row -> ScoredRecord in
                let scored = row.asScoredRecord
                guard scored.verdict != .fact else { return scored }
                return ScoredRecord(id: scored.id, record: scored.record, verdict: .fact,
                                    gates: scored.gates, summary: scored.summary)
            }
        guard !facts.isEmpty else { return Demotions(demotable: [], appliedHeldBack: []) }
        // Ghost rivals: leads the pass previously demoted keep their slot
        // contested — a lone stored fact in a ghost-contested slot is the
        // flip-flop legacy state and demotes too. User-discarded rows never
        // block ("not them" resolves the contest) and never demote; an applied
        // lead is already a live rival above, so it must not also ghost-rival
        // itself.
        let ghosts = live
            .filter { $0.verdict == .lead && !appliedIDs.contains($0.sourceRecordID) }
            .map(\.asScoredRecord)
            .filter(RecordScorer.isExclusivityGhost)
        // Deliberately UNEXEMPTED — the pass's own applied-exemption argument
        // is left unset. The pipeline exempts applied rows from demotion so a
        // run cannot take back the user's decision; this audit's job is to
        // REPORT, and an applied fact that contradicts another is exactly what
        // the user needs told. The split below is what keeps the one-click from
        // acting on it.
        let demoted = RecordScorer.applyExclusivityAcrossStore(
            batch: [], storedFacts: facts, storedGhosts: ghosts
        ).demotedStored

        // The guard. The exclusivity verdict is unchanged — what changes is
        // who is allowed to act on it.
        return Demotions(
            demotable: demoted.filter { !appliedIDs.contains($0.id) },
            appliedHeldBack: demoted.filter { appliedIDs.contains($0.id) })
    }

    /// Display-shaped finding for one profile; nil when consistent.
    ///
    /// Applied rows ARE reported — the contradiction is real and the user must
    /// see it — but they carry `isApplied` so the surface can say plainly that
    /// the one-click will not touch them.
    static func finding(
        profileID: String, profileName: String, evidence: [EvidenceRecord],
        profile: Profile?
    ) -> Finding? {
        let demoted = demotions(in: evidence, profile: profile)
        guard !demoted.isEmpty else { return nil }
        let heldBackIDs = Set(demoted.appliedHeldBack.map(\.id))
        let rowByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.sourceRecordID, $0) })
        let rows = demoted.all.map { rec in
            DemotedFact(
                sourceRecordID: rec.id,
                slotLabel: slotLabel(for: rec.record),
                detail: rowByID[rec.id]?.citationFull
                    ?? (rec.summary.isEmpty ? rec.record.recordType.rawValue : rec.summary),
                reason: rec.gates.last { $0.gate == .exclusivity }?.reason
                    ?? "competing candidates",
                isApplied: heldBackIDs.contains(rec.id))
        }
        return Finding(profileID: profileID, profileName: profileName, demotions: rows)
    }

    /// "census-1891" → "census 1891"; non-slot records fall back to type.
    static func slotLabel(for record: SourceRecord) -> String {
        guard let slot = RecordScorer.exclusivitySlot(for: record) else {
            return record.recordType.rawValue
        }
        return slot.replacingOccurrences(of: "-", with: " ")
    }
}

// MARK: - Census leads carrying a household

/// Attention items for a census record that is still an UNAPPLIED LEAD but
/// already carries a loaded household roster.
///
/// The shipped `censusUnabsorbed` sweep fires on APPLIED evidence, so a lead
/// holding a full roster is silent on every surface: Emma Gladwin's 1891
/// FreeCen lead sat unapplied from 21 Jul to 25 Aug 2026 while naming an
/// unrecorded sibling, an unrecorded grandchild (and so an unrecorded married
/// daughter), and contradicting two applied GEDCOM birthplaces. A roster this
/// informative must be a work item whether or not the record has been applied
/// — the apply is the very decision the roster informs.
///
/// Two shapes, deliberately separate rules so they land in the right Health
/// bucket: kin the tree doesn't hold is a GAP (evidence present, not carried
/// across); a roster row disagreeing with an applied fact is an ISSUE (the
/// stored data may be wrong). Neither is `.research` — `.research` is not
/// rendered in Health at all.
///
/// Read-only and network-free: this names the work, it never applies anything.
/// A lead is a proposal, so the gate is strict — the roster must actually place
/// THIS person in the household, as FAMILY. Without that, a namesake's family
/// (or a house the subject only boarded in) reads as "kin missing from the
/// tree" and the sweep becomes noise.
///
/// Callers pair this with `censusUnabsorbedFindings`, which covers the applied
/// half. The two disagree about one record shape — a `.savedAsLead` census that
/// was never actually applied reads as applied to that sweep (the historical
/// status quirk) and as unapplied here — so a caller listing both should drop
/// this rule's finding for a profile the other sweep already reported.
nonisolated enum CensusLeadAttentionAudit {
    static let unabsorbedRuleID = "censusLeadUnabsorbed"
    static let contradictionRuleID = "censusLeadContradiction"

    /// How many household names a message lists before it elides.
    private static let namesShown = 4

    /// Tree lookup by surname, built ONCE per sweep. `matchesTreeWide` requires
    /// the roster surname to equal a profile's birth or married surname, so a
    /// surname bucket is a complete candidate set — a narrowing that cannot
    /// change any answer, only the cost of reaching it (a tree-wide scan per
    /// roster row is quadratic in the tree).
    struct TreeIndex {
        private let bySurname: [String: [Profile]]

        init(_ snapshot: FamilyGraphSnapshot) {
            var index: [String: [Profile]] = [:]
            for profile in snapshot.profiles.values where !profile.isDeleted {
                var keys: Set<String> = []
                for surname in [profile.lastName, profile.marriedSurname] {
                    let key = (surname ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    keys.insert(key)
                }
                for key in keys { index[key, default: []].append(profile) }
            }
            bySurname = index
        }

        func candidates(for member: HouseholdMember) -> [Profile] {
            guard let surname = member.name.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .last.map(String.init) else { return [] }
            return bySurname[surname] ?? []
        }
    }

    /// Findings for one subject's lead census records. `index` is shared across
    /// the sweep; build it once from the same snapshot.
    static func findings(
        for subject: Profile, evidence: [EvidenceRecord], index: TreeIndex
    ) -> [AuditResult] {
        var out: [AuditResult] = []
        for ev in evidence {
            // UNAPPLIED is the condition, not the verdict: a `.fact` census
            // nobody has applied yet holds its household just as silently as a
            // `.lead` does. Only `.impossible` is excluded — the scorer has
            // already ruled that household is somebody else's.
            guard case .census(let census) = ev.record,
                  ev.verdict != .impossible,
                  ev.userStatus != .discarded,
                  !ev.wasApplied(to: subject) else { continue }
            // Kin rows only. A servant or boarder sharing the address is not a
            // relative the tree is missing, and a subject enumerated AS a
            // boarder is not in their own family's house at all.
            let household = (census.household ?? []).filter {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                    && !isNonKinRole($0.relationship)
            }
            guard household.count > 1 else { continue }
            guard let subjectIndex = household.firstIndex(where: {
                isSubjectRow($0, subject: subject, censusYear: census.censusYear)
            }) else { continue }

            var missing: [String] = []
            var clashes: [String] = []
            var clashingProfileIDs: [String] = []

            func noteClash(_ member: HouseholdMember, _ profile: Profile) {
                guard let clash = birthplaceClash(member: member, profile: profile) else { return }
                clashes.append(clash)
                clashingProfileIDs.append(profile.id)
            }

            for (position, member) in household.enumerated() {
                if position == subjectIndex {
                    noteClash(member, subject)
                    continue
                }
                guard let match = index.candidates(for: member).first(where: {
                    CensusRelationshipReconciler.matchesTreeWide(
                        member: member, profile: $0, censusYear: census.censusYear)
                }) else {
                    missing.append(describe(member, censusYear: census.censusYear))
                    continue
                }
                noteClash(member, match)
            }

            if !clashes.isEmpty {
                out.append(AuditResult(
                    profileID: subject.id, profileName: subject.displayName,
                    severity: .warning, category: .issue,
                    ruleID: contradictionRuleID,
                    message: "\(subject.displayName)'s \(census.censusYear) census lead contradicts the tree: \(clashes.joined(separator: "; ")). Settle it before the lead is applied — or discard the lead if the household is a namesake's.",
                    relatedProfileIDs: clashingProfileIDs))
            }
            if !missing.isEmpty {
                out.append(AuditResult(
                    profileID: subject.id, profileName: subject.displayName,
                    severity: .warning, category: .gap,
                    ruleID: unabsorbedRuleID,
                    message: "\(subject.displayName)'s \(census.censusYear) census lead names \(missing.count) household member\(missing.count == 1 ? "" : "s") not on the tree (\(elide(missing))) — review the lead on their profile.",
                    relatedProfileIDs: []))
            }
        }
        return out
    }

    /// Household roles that are NOT kin. Deliberately a short, unambiguous list
    /// — an unrecognised or blank role stays in scope, because the roles a
    /// household story turns on (Grandson, Mo-Law, Niece) are open-ended and
    /// missing one of those is the failure this audit exists to prevent.
    static func isNonKinRole(_ relationship: String) -> Bool {
        let role = relationship.lowercased()
        return ["servant", "serv", "boarder", "lodger", "visitor", "visr",
                "apprentice", "inmate", "patient", "employee", "governess"]
            .contains { role.contains($0) }
    }

    /// Whether a roster row IS the subject. The tree-wide test (name plus year
    /// or birth town) decides on its own merits; the source's own "this is your
    /// search hit" flag additionally admits the role-scoped fallback, which is
    /// name-only when either side is undateable — safe here because the
    /// candidate set is exactly one profile.
    static func isSubjectRow(_ member: HouseholdMember, subject: Profile, censusYear: Int) -> Bool {
        if CensusRelationshipReconciler.matchesTreeWide(
            member: member, profile: subject, censusYear: censusYear) { return true }
        return member.isTarget == true
            && CensusRelationshipReconciler.matchesRoleScoped(
                member: member, profile: subject, censusYear: censusYear)
    }

    /// A roster row's birthplace against the profile's recorded one, when both
    /// are present and name different towns. Same divergence test the census
    /// absorb capsule shows, so the two surfaces cannot disagree about what
    /// counts as a different place.
    static func birthplaceClash(member: HouseholdMember, profile: Profile) -> String? {
        let row = (member.birthPlace ?? "").trimmingCharacters(in: .whitespaces)
        let tree = (profile.birthLocation ?? "").trimmingCharacters(in: .whitespaces)
        guard !row.isEmpty, !tree.isEmpty,
              AppState.placesDivergeAtTown(row, tree) else { return nil }
        return "\(profile.displayName) is recorded born \(tree) but enumerated born \(row)"
    }

    /// "Sarah Ann GLADWIN (Daur, b.~1874)" — enough for the user to recognise
    /// the person without opening the record.
    static func describe(_ member: HouseholdMember, censusYear: Int) -> String {
        var bits: [String] = []
        let role = member.relationship.trimmingCharacters(in: .whitespaces)
        if !role.isEmpty { bits.append(role) }
        if let year = member.birthYear ?? member.age.map({ censusYear - $0 }) {
            bits.append("b.~\(year)")
        }
        return bits.isEmpty ? member.name : "\(member.name) (\(bits.joined(separator: ", ")))"
    }

    private static func elide(_ names: [String]) -> String {
        guard names.count > namesShown else { return names.joined(separator: ", ") }
        return names.prefix(namesShown).joined(separator: ", ")
            + " and \(names.count - namesShown) more"
    }
}
