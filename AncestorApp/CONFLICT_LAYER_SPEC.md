# CONFLICT_LAYER_SPEC — Evidence-Conflict Layer (GPS Element 4)

**Status: Proposed — awaiting review (drafted 2026-07-13 from the DS audit + three-design competition; detection-first won 9/9/9).** Commits will reference `#CL-Change1`…`#CL-Change6` of this spec.

**Governing invariant — detection-completeness:** after this layer ships, every pair of accepted (fact-grade) assertions about one subject is in exactly one of three states — (a) *provably compatible* (same witness, or precision refinement), (b) *deterministically resolved* with a recorded rule ID and per-rung trace, or (c) an **open dispute row visible to the user**. There is no fourth state. Silence is a bug.

**What this layer is:** the missing *producer* for the dormant dispute machinery (`field_disputes` / `FieldDispute` / `DisputeReason` / `ConflictResolutionView` — built, tested, and never written to in production, per DS-13), plus a witness-identity substrate that makes convergence honest, a deliberately tiny bulletproof resolution ladder, and a GPS criterion 4 that can actually fire.

**What this layer is not:** scorer-gate repair (DS-01/02/04/05/06/10/11/16–19/21/22/23/27 are separate campaigns — this layer is the *net under* those gates, not their fix), a dossier UI (T9 consumes a read contract only), FamilySearch work, cluster-merge adjudication, or MLX anything (decision log #2).

**Provenance:** three competing designs (detection-first / resolution-first / hypothesis-generalisation) were judged by three lenses (invariant-fit, buildability, gps-fidelity). Detection-first won all three at 9/10. The judges' graft lists are folded in below and marked **⟨Gn⟩** where they amend the base design; where a graft conflicted with the base, the graft won. All file/line references below re-verified against the working tree 2026-07-13.

---

## 1. Motivation — SANDWICH_AUDIT_2026-07.md findings this spec resolves

The conflict-evidence cluster of the DS audit found that the system detects contradictions in several places and **loses every one of them**: no producer writes disputes, run discrepancies dead-end in an unread envelope, losing values are buried in `field_sources`, and GPS criterion 4 is a constant. Disposition map (findings quoted by ID from `AncestorApp/SANDWICH_AUDIT_2026-07.md`):

| Finding | Defect | Resolution here | Change |
|---|---|---|---|
| **DS-03** (high) | Multiple transcriptions of the same GRO/enumeration entry count as independent lineages → one wrong row self-corroborates to `.probable` | WitnessKey counting in ConvergenceEngine; conservative unknown-≠-independent matching; GRO keys carry name components ⟨G1⟩ | CL4 |
| **DS-07 / DS-14** (high) | GPS criterion 4 keys on `.impossible` records inside clusters, which `ClusteringEngine.swift:21` pre-filters — the unmet branch is unreachable | Criterion rewired to open disputes + rival confirmed clusters + inconclusive value candidates + run discrepancies; rule-resolved disputes count as *met with evidence*, rule ID cited | CL3 |
| **DS-08** (high) | Equal-precision fact-vs-fact conflicts resolve by arrival order (first-writer-wins); the promised "multi-hypothesis pivot" exists only for birthDate | Equal-precision conflict now opens a dispute (CL1); R2 quality dominance resolves tier/directness-dominant cases; `.deathYearCandidate` owns the true ties (CL5) | CL1, CL5 |
| **DS-09** (high) | Date overwrite has no provenance axis — a precise community-tier date permanently blocks a later precise primary-tier date | R2 (originality-first ⟨G7⟩) consulted by `shouldOverwriteDateField` after the span test; meanwhile the buried alternative surfaces as a dispute from CL1 | CL1, CL5 |
| **DS-12** (high) | Marriage record naming a different spouse scores `.fact` and applies as a silent no-op (`ApplyEngine.swift:94`) | The silent `guard … return` becomes an F4b `spouseIdentity` dispute + reported outcome (CL1); investigation affordance (CL6). Scorer half (mismatch → softFail) is a **companion repair, out of scope** — §7.1 | CL1, CL6 |
| **DS-13** (high) | The dispute layer has no producer; `research_discrepancies` has no INSERT; `recordAlternativeFact` preserves conflicts as data and loses them as signal | The core deliverable: apply-time producer (CL1), standing sweep + backfill (CL2), discrepancy persistence + envelope inclusion (CL3) | CL1–CL3 |
| **DS-15** (high) | Death record contradicting later alive-evidence caught only if death already known at scoring time; never retroactive; no audit rule reads LifeEvents vs deathDate | F3 in the standing sweep is retroactive and order-independent; `RecordAfterDeathRule` joins the audit registry (CL2); the same predicate contradicts wrong `.deathYearCandidate`s (CL5). Prevention half (`subject.aliveAsOf`) is a **companion repair, out of scope** — §7.1 | CL2, CL5 |
| **DS-20 / DS-24** (medium) | ConvergenceEngine never compares values — GPS criterion 3 pools contradictions as corroboration; birth-vs-census-implied 14 years apart co-exist in one cluster | Per-ValueGroup scoring enforced structurally (`scoreValueGroups`, raw `score()` goes internal) — value partition in CL3, witness counting in CL4 | CL3, CL4 |
| **DS-25** (medium) | Multi-hypothesis machinery covers only birthDate; competing precise death years dead-end with no owner | `.deathYearCandidate` full ladder (generator/grader/deficit/apply), entered from field_sources *or* an open F1 dispute; locations deliberately dispute-only (§7 non-goal) | CL5 |
| **DS-26** (medium) | Mutually exclusive parent proposals co-exist and can both be accepted — two biological mothers, invisible to every audit rule forever | Accept-time F4a dispute + pre-computed warning (CL1); `ParentsPerRoleRule` + sweep backfill catches existing damage (CL2); engine-seeded `.parentIdentityCandidate` with choose-one UI ⟨G5,G10⟩ (CL5/CL6) | CL1, CL2, CL5, CL6 |
| **DS-02** (partial) | Two same-enumeration-year census records — a physical impossibility for one person — coexist in one cluster and corroborate each other | In-cluster same-enumeration-year impossibility check ⟨G13⟩: new `findContradiction` split trigger + sweep arm over persisted life_events | CL2 |
| **DS-01/02/16/17** (context) | Wrong-identity records reach `.fact` through gate weaknesses | **Not fixed here** (gate-repair campaigns). This layer is their safety net: once a wrong death/census/burial is applied, F1/F3/F5 detect the collision with the subject's *other* accepted evidence and surface it — the audit's "survives every deterministic check" claim stops being true | CL1, CL2 |

---

## 2. Decision log

1. **Detection-completeness is the anchor** — every conflict ends provably-compatible, rule-resolved-with-recorded-ID, or open-and-visible; no fourth state. This is the deterministic sandwich and when-in-doubt-split restated for evidence. Detection scope is *never* derived backwards from what the resolution ladder can adjudicate (the rejected resolution-first design's inversion): acknowledgment obligations exist precisely where rules cannot weigh.
2. **The layer is 100 % deterministic; MLX narrates, never resolves.** The T9 dossier may later paraphrase a dispute's `reasoning` and `ladder_trace` strings; it never grades, resolves, suppresses, or seeds one. No new model surface.
3. **Leads are not assertions.** A `.lead` record that disagrees with the tree stays in Triage (already surfaced there); it becomes dispute-eligible only at accept/apply. This resolves DS-13's "the worse the conflict the less the machinery sees" paradox without polluting disputes with unvetted namesakes: within-tolerance conflicts are caught at apply, out-of-tolerance ones are already human-visible as leads.
4. **Default disposition = open + surfaced.** Resolution rules exist only where bulletproof (§4.6). Explicitly rejected as resolution rules: majority-of-witnesses voting (correlated errors — census age and memorial often share one family informant), recency, death-vs-later-alive auto-correction (the later sighting could be the namesake — DS-02's whole point), and convergence-level dominance alone (DS-03 showed convergence can be inflated; post-CL4 it is a severity *input*, never a decider).
5. **Reuse the dormant machinery — this layer is the missing producer.** `field_disputes` (v1 schema, `ProjectDatabase.swift:139`), `FieldDispute`/`DisputeReason` (`noOverlap`/`approximateOverlap`/`valueMismatch` — designed for exactly this) at `AncestorKit/Sources/AncestorKit/FieldTypes.swift:75/:94`, `addFieldDispute`/`resolveFieldDispute` (`ProjectDatabase.swift:3373/:3400`), the resolution flow at `AppState.swift:1888`, `Ancestor Research/Views/Conflicts/ConflictResolutionView.swift`, snapshot dispute loading (`ProjectDatabase.swift:1421`), and `DiscrepancySeverityTable` all exist and are tested. Nothing on the consumer side is rebuilt.
6. **WitnessKeys are computed, never persisted** ⟨G9⟩. Key derivation will improve (FS collection mapping, future piece/folio data); persisting keys would create a second source of truth. `evidence_json` on dispute rows stores *record references*, never keys; `witness_summary` is a point-in-time display cache recomputed on every upsert, not identity.
7. **Ladder ordering is originality-first** ⟨G7⟩: `EvidenceDirectness` before `SourceTrustTier` (directness is the GPS-canonical primary axis; tier breaks directness ties, not the reverse), and event-proximity decides only when every losing value's delta lies within the losing record-class's own error band — an out-of-band delta is not explainable as informant error and must stay open.
8. **Witness-gated reopen** ⟨G3⟩: a resolved dispute reopens only when a *new* WitnessKey (not already among `competing_sources`) asserts a conflicting value. Another transcription of an already-weighed original never re-litigates.
9. **Identity questions never become value-candidate kinds.** Spouse/parent identity conflicts get disputes + investigation seeding, not value ladders. Engine-origin identity candidates use a **distinct kind `.parentIdentityCandidate`** ⟨G10⟩ — `.parentCandidates` is user-seeded-only by documented contract (`ResearchHypothesis.swift:269`, `HypothesisEngine+ParentCandidates.swift:5-15`; §5.15 Decision E1) and the engine must never touch it. When seeding an identity candidate set, **the tree is a witness too** ⟨G11⟩: the existing accepted edge enters as a candidate with its own provenance, so the incumbent has no silent home-field advantage. Rival candidates render as **one choose-one card** ⟨G5⟩ — accepting one auto-marks rivals `.contradicted`; never parallel Accept buttons.
10. **Documented resolution, not just a verdict** ⟨G2⟩: every dispute row (open or resolved) carries a per-rung `ladder_trace` — each rule evaluated, its outcome, and why (e.g. `"R2c: not fired — census delta 4 exceeds ±3 error band"`). This is the written proof argument GPS element 4 requires, and the verbatim-groundable input the T9 dossier needs. A rule-resolved dispute counts *toward* GPS criterion 4 as met-with-evidence, rule ID cited in the reason string.

---

## 3. Conceptual model

```
Attestation  = one (value, origin, record-ref) claim about a subject fact
               — a field_sources row, a life_event, a relationship edge, or an
               incoming fact-grade ScoredRecord at apply time.

WitnessKey   = deterministic identity of the UNDERLYING original register
               entry an attestation transcribes. Two attestations with the
               same WitnessKey are ONE witness (DS-03's "one GRO line
               transcribed three times"). Computed, never persisted (§2.6).

ValueGroup   = attestations grouped by asserted value (dates: by year-range;
               strings: by normalised text). Convergence is scored per
               ValueGroup over distinct WitnessKeys — never across values.

Conflict     = two ValueGroups for the same (subject, fact) whose values are
               incompatible (disjoint date ranges; mismatching normalised
               strings; timeline impossibility; two identities in one
               biological role; record-spouse ∉ edge-spouses; two facts from
               one enumeration year).

Dispute      = the persisted, user-visible representation of a Conflict
               (field_disputes row). Lifecycle:
               open → resolved(.accepted | .rule | .manual | .deferred)
               → reopened ONLY by a new WitnessKey asserting a conflicting
               value (§2.8). A resolved row is history — preserved for undo
               and the dossier; reopening opens a NEW row.
```

---

## 4. Components

### 4.1 C1 — `WitnessIdentity` (record-lineage identity)

**New file:** `AncestorKit/Sources/AncestorKit/Research/WitnessIdentity.swift` (AncestorKit so future viewers/dossier can read it; pure function of record fields, no app dependencies).

```swift
struct WitnessKey: Hashable {            // deliberately NOT Codable — never persisted (§2.6)
    let archiveClass: ArchiveClass       // .groIndex, .censusEnumeration(year),
                                         // .parishRegister, .cwgcRegister,
                                         // .probateCalendar, .memorial(sourceRecordID)
    let eventShape: String               // "birth" | "death" | "marriage" | …
    let year: Int?
    let quarter: String?                 // normalised ("Mar"/"Jun"/"Sep"/"Dec")
    let district: String?                // uppercased, whitespace-collapsed
    let volume: String?                  // normalised (strip leading zeros/spaces)
    let page: String?
    let surnameNorm: String?             // ⟨G1⟩ REQUIRED for .groIndex keys
    let givenInitial: String?            // ⟨G1⟩ REQUIRED for .groIndex keys
}
```

**⟨G1⟩ GRO keys must include name components.** A GRO index vol/page identifies a *page* holding 2–4 entries, not a single line. Without `surnameNorm + givenInitial`, two siblings registered in the same quarter/district/vol/page would collapse to one witness and R0 could misread a genuine two-person conflict as transcription variance. This is a correctness requirement, not a nicety.

**Derivation** (`WitnessIdentity.key(for: SourceRecord, sourceInfo: SourceInfo) -> WitnessKey`):

- **Archive class comes from the lineage payload, not re-derivation** ⟨G4⟩: `SourceLineage.independentTranscription(of:)` (`AncestorKit/Sources/AncestorKit/Research/SourceLineage.swift:7-16`) already declares the underlying original — FreeBMD declares `of: "GRO-indexes"` (`FreeBMDSource.swift:37`) → `.groIndex`; FreeCen declares `of: "Census-enumeration-books"` (`FreeCenSource.swift:19`) → `.censusEnumeration(year)`. For FamilySearch (`.communityEdited`, no payload), a **static collection→original mapping table** inside `WitnessIdentity.swift` maps the collection title already carried in `rawFields` (e.g. "England and Wales Birth Registration Index" → GRO indexes; census collections → enumeration books). CWGC (`.primaryRecord`) → `.cwgcRegister`; FindAGrave → `.memorial(record.common.id)` (each memorial its own — derivative — witness); parish → `.parishRegister` + parish name; probate → `.probateCalendar` + year. **Never from LLM output** (the source-trust-is-URL-derived invariant extends to witness identity).
- **BMD index rows**: `BirthRecord`/`DeathRecord`/`MarriageRecord` already carry `quarter/district/volume/page` (`AncestorKit/Sources/AncestorKit/Research/RecordTypes.swift:44-47, :72-75, :100-103`). FamilySearch constructs these as nil today (DS-03 verifier) — see the matching rule.
- **Census**: `CensusRecord` (`RecordTypes.swift:142-154`) has no piece/folio/schedule, so the key is `(censusYear, district?, parish?)` **plus the domain rule: one person is enumerated once per census year** — two same-year census attestations *for the same subject* are one witness by definition; if they materially disagree they are an F5/T-D conflict, never two corroborations.

**Matching rule (conservative direction):** two keys denote the same witness when all mutually non-nil components are equal AND `archiveClass + eventShape + year` agree — with the ⟨G1⟩ exception that for `.groIndex` keys `surnameNorm` and `givenInitial` are always derivable, are always compared, and must both match. Missing components (FS's nil vol/page) therefore *match* a present-component key with the same class/shape/year/quarter/district/name. **When independence cannot be proven, it is not counted** — the conservative direction for corroboration, mirroring when-in-doubt-split. FreeBMD's "SMITH John, Belper, Q2 1860, 7b/143" and FS's vol-less transcription of the same GRO row collapse to one witness; the sibling "SMITH Sarah" on the same page does not.

`SourceLineage` stays as-is (the per-transcriber display label); convergence *counting* moves to WitnessKey (C5).

### 4.2 C2 — `ConflictDetector` (the producer's brain)

**New file:** `Ancestor Research/Services/Research/ConflictDetector.swift`. Pure, nonisolated, fully unit-testable. Input: a profile + its `field_sources` + `life_events` + relationship edges (+ optionally one incoming candidate attestation). Output: `[DetectedConflict]` — typed findings each carrying kind, field, competing attestations, `DisputeReason`, severity, a deterministic reasoning string, and the detecting producer (for `detected_by` ⟨G6⟩).

**Detection rules:**

| ID | Rule | Incompatibility test | DisputeReason / kind |
|----|------|---------------------|----------------------|
| **F1** | Date-field conflict (`birthDate`, `deathDate`) | Parse every attested raw via `GenealogicalDate(parsing:)`; two values conflict when year-ranges are **disjoint** or overlap only partially with neither containing the other. Strict containment = refinement, *not* a conflict (matches ApplyEngine's narrower-span rule = R1). | `.noOverlap` / `.approximateOverlap` |
| **F2** | Location-field conflict (`birthLocation`, `deathLocation`) | Normalised inequality after collapse (case, whitespace, trailing county). Severity `.note` unless a county derives for both sides via the existing chapman-derivation chain and the counties differ → `.conflict`. **No hardcoded regions.** | `.valueMismatch`, kind `fieldValue` |
| **F3** | Timeline: death vs later-alive evidence (DS-15) | `deathDate.latest < year(of any life_event of type census/residence/occupation/militaryService/religion)` or `< relationship.marriageDate.earliest`. Symmetric arm: burial/probate life-event year vs later sightings. | `.valueMismatch`, kind `timeline` |
| **F4a** | Parent-role conflict (DS-26) | ≥2 `type == .parent, subtype == .biological` edges with the same role (father/mother) pointing at distinct profile identities. | kind `parentRole` |
| **F4b** | Spouse-identity conflict (DS-12) | An accepted marriage attestation whose record spouse-surname matches **no** existing spouse edge's surname (the exact predicate that today silently no-ops at `ApplyEngine.swift:94`). | kind `spouseIdentity` |
| **F5** | Same-witness transcription disagreement | Two attestations reducing to one WitnessKey but asserting different values. A *transcription* conflict — graded low, auto-resolvable by R0. Requires C1; ships CL4. | `.valueMismatch` |
| **T-D** | Same-enumeration-year impossibility ⟨G13⟩ | Two census facts for one subject from the *same* census year (in persisted tree state, or inside one cluster pre-apply). One person is enumerated once per year; material disagreement = conflict, never corroboration. Does **not** require WitnessKey — censusYear equality suffices; ships CL2. | `.valueMismatch`, kind `timeline` |

Severity for F1/F2 comes from **`DiscrepancySeverityTable`** — unchanged (`severity(…)` at `DiscrepancySeverityTable.swift:16`, raw values `none/note/refinement/conflict/correction` from `AncestorKit/Sources/AncestorKit/Research/DiscrepancySeverity.swift`) — with the convergence parameter finally live from CL4: the incoming ValueGroup's witness-counted convergence feeds `applyConvergenceUpgrade` (`DiscrepancySeverityTable.swift:50`), turning the audit's "latent-but-correct" branch into a working feature (a corroborated multi-witness discrepant value upgrades `.conflict → .correction`). CL1–CL3 grade with lineage-based convergence interim — stated explicitly so nobody mistakes the interim for the design.

### 4.3 C3 — `DisputeStore` (persistence + identity; ProjectDatabase extension)

Extends the existing `addFieldDispute`/`resolveFieldDispute` pair (`ProjectDatabase.swift:3373/:3400`) with an **idempotent upsert**, because detection runs repeatedly (apply, run-end, sweep):

- `upsertDispute(profileID:, conflict: DetectedConflict) -> Int64` — key: at most **one open dispute per `(entity_id, kind, field)`** (unique partial index `WHERE resolution IS NULL`, §5). A newly detected competing value *joins* the open dispute's `competing_sources` set (recomputing severity + `witness_summary`); an identical re-detection is a no-op.
- **Reopen semantics ⟨G3⟩:** a new conflicting value against a *resolved* dispute opens a new row **only when its WitnessKey is not already represented among the resolved row's `competing_sources`** (keys recomputed from the stored record references — §2.6). Another transcription of an already-adjudicated witness updates nothing.
- `openDisputes(profileID:)`, `openDisputeCount()`, `allOpenDisputes()`, `allDisputes(profileID:)` — the surfacing queries (the last is the T9 dossier contract).
- Every write stamps `detected_by` ⟨G6⟩ (`'applyEngine' | 'runSweep' | 'consistencySweep'`) — cheap provenance that lets us audit producer coverage against the detection-completeness claim.
- Resolution writes stay on the existing `resolveFieldDispute` transaction path (undo-compatible; dispute rows already cascade on `created_by_transaction_id`, `ProjectDatabase.swift:1751/:1832`).

### 4.4 C4 — Detection triggers (complementary producers)

Detection-completeness requires all of them; each covers the others' blind spots.

**T-A. Apply-time (`detected_by = 'applyEngine'`) — the primary producer.** In `ApplyEngine`:

- `applyDateField` / `applyStringField` else-branches (`ApplyEngine.swift:107-126, :128-148` — alternative-fact writes at `:123/:145`): before `recordAlternativeFact`, run the F1/F2 incompatibility test between candidate and existing + attested values. Compatible-but-not-narrower → alternative fact only (today's behaviour). **Incompatible → alternative fact + `upsertDispute`** (fixes DS-13 part 3: the conflict is preserved as data AND as signal). The 1900-vs-1901 deathDate scenario opens a dispute at the moment it happens.
- `applyMarriageToSubjectSpouseEdge` (`ApplyEngine.swift:72-104`) — the silent `guard let edge = matched else { return }` at `:94` becomes `else { upsert F4b spouseIdentity dispute referencing the record; append a WriteFailure-grade notice to the returned outcome }`. The strongest wrong-person signal (DS-12) now leaves a trace on the exact path where it is discarded today.
- `acceptParentProposal` (`ApplyEngine.swift:258`): before link/create, check the snapshot for an existing biological parent of the same role with a different identity → the accept still proceeds (human decided), but an F4a `parentRole` dispute opens immediately (DS-26's two-mothers state can no longer exist invisibly), and the ClusterReview accept UI renders the pre-computed warning ("subject already has a mother: BOWN").
- `applyAcceptedPendingFact` (PendingFactsReview path, which deliberately bypasses the overwrite policy): same F1/F2 hook after the write.

**T-B. Run-time (`detected_by = 'runSweep'`).** `ResearchPipeline.detectDiscrepancies` (`ResearchPipeline.swift:2415`) output stops dead-ending:

- Persist `state.discrepancies` into the never-inserted `research_discrepancies` table (created v1 at `ProjectDatabase.swift:262` — already has `severity`; v41 adds `run_id`), and include them in `RunRequestWatcher.buildResultEnvelope` (`RunRequestWatcher.swift:525`) so MCP/result JSON carries them.
- Severity ≥ `.conflict` rows for **fact-grade** records additionally `upsertDispute` (the record asserts a value that will conflict on apply; surfacing pre-apply lets ClusterReviewView badge the record "conflicts with tree: 1901").
- Scope note: detectDiscrepancies' `.fact`-only filter is *retained* (leads-are-not-assertions, §2.3), and its field coverage stays birth/death year — F2/F3/F4 coverage comes from T-A and T-C, not from widening this function.

**T-C. Standing sweep (`detected_by = 'consistencySweep'`) — `ConflictSweep`.** **New file:** `Ancestor Research/Services/Research/ConflictSweep.swift`. Runs `ConflictDetector` over **every profile**: all field_sources vs canonical values (F1/F2), life_events + edges vs deathDate (F3 — the *retroactive*, order-independent death-vs-later-alive detection DS-15 proves is missing), same-enumeration-year life_events (T-D tree-state arm ⟨G13⟩), parent-role scan (F4a), accepted marriage attestations vs spouse edges (F4b), and — from CL4 — same-witness disagreements (F5). Properties:

- Idempotent (upsert identity, C3). Read-only except dispute rows.
- Triggered: once per project open (cheap — indexed reads; skippable via a `project_meta` high-water mark), after every research-run apply batch, after GEDCOM import, and manually from the Audit surface ("Scan for conflicts").
- One-shot backfill on v41 migration completion, patterned on `reconcileProfileDateFields` (`ProjectDatabase.swift:3551`) — existing trees get their latent contradictions surfaced on first launch. This is the layer's single biggest honesty win: DS-15/DS-26-shaped damage already in user trees becomes visible.

**T-D. Cluster-level (pre-apply) ⟨G13⟩.** `ClusteringEngine.findContradiction` (`ClusteringEngine.swift:311`) gains a split trigger: **two census records with the same `censusYear` in one cluster force a split** (physically impossible for one person). Over-splitting is safe (when-in-doubt-split); this catches DS-02 fusion before apply, not only in persisted tree state. ClusterReviewView badges the affected cluster.

### 4.5 C5 — Witness-aware convergence (`ConvergenceEngine` changes)

- `ConvergenceEngine.score` (`ConvergenceEngine.swift:21`): replace `Set<SourceLineage>` cardinality (`:29-31`) with **distinct-WitnessKey-family count** (grouping via C1's conservative matcher). Trust-weighted score sums **once per witness** (max tier within the witness family), not once per transcription. FreeBMD + FS + FindAGrave copies of one GRO row = 1 witness → `.singleSource`-tier arithmetic, not `.probable` (DS-03 dead).
- **Per-value contract enforced structurally:** new `ConvergenceEngine.scoreValueGroups(records:, valueOf:, sourceInfoMap:)` partitions records into ValueGroups first and returns per-value levels; the raw `score()` becomes internal. Callers can no longer pool contradicting records as corroboration (DS-20/DS-24 mechanism). Value partition ships CL3 (with interim lineage counting); the witness-family counter swaps in at CL4.
- Directness caps (`adjustForDirectness`, `ConvergenceEngine.swift:116`) and rarity demotion unchanged.
- `sourcingStrength` gains `independentWitnessCount` alongside the existing lineage count (UI badge honesty).

### 4.6 C6 — Deterministic resolution ladder (`DisputeResolver`)

**New file:** `Ancestor Research/Services/Research/DisputeResolver.swift`. Runs at detection time (T-A/T-C call it before persisting an open dispute). A conflict is auto-resolved **only** if a rule fires; the resolution persists as a new `DisputeResolution` case `.rule(id: String, accepted: FieldSource)` (Codable-additive beside `accepted/manual/deferred`, `FieldTypes.swift:100-103`). Auto-resolved disputes are still *written* (resolved state) — the dossier's conflict section needs them; nothing is silent. **Every evaluation — fired or not — appends to `ladder_trace`** ⟨G2⟩: `[{rung, outcome, detail}]`, e.g. `{"rung":"R2c","outcome":"not-fired","detail":"census delta 4 exceeds ±3 error band"}`.

Rules, in evaluation order — **only these; everything else stays open:**

- **R3 — User-authoritative shield (evaluated first).** Any competing attestation with a user-manual origin (`SourceOrigin` tier `.userAuthoritative`, `AncestorKit/Sources/AncestorKit/SourceOrigin.swift:63`; the string policy already treats empty-origin as user-authoritative, `ApplyEngine.swift:196`) → no auto-resolution in either direction; the dispute stays open for the human. (Check-before-overwrite.)
- **R0 — Same witness (from F5; live from CL4).** All competing attestations reduce to one WitnessKey → transcription disagreement, not evidence conflict. Keep the value from the highest-tier transcription; tier tie → keep the value carrying more citation detail (non-nil vol/page/quarter count); still tied → stays open at severity `.note`. Bulletproof because one register entry has one true reading — and ⟨G1⟩'s name components guarantee "one register entry" means one *line*, not one page.
- **R1 — Precision subsumption.** One value's year-range strictly contains the other's → refinement. Never opens a dispute at all (filtered in F1). This is ApplyEngine's existing narrower-span rule restated; no change in write behaviour.
- **R2 — Quality dominance for dates, originality first ⟨G7⟩.** Resolves DS-09. Three sub-rungs, each traced:
  - **R2a — Originality:** compare each ValueGroup's best `EvidenceDirectness` (`primary 3 > directTranscription 2 > derivative 1`, `AncestorKit/Sources/AncestorKit/Research/EvidenceDirectness.swift:10`). One value strictly higher than every rival → it wins. Directness is the GPS-canonical primary axis.
  - **R2b — Tier:** directness tied at the top → strictly higher best `SourceTrustTier` (URL/plugin-derived as today, via `SourceTierRegistry`) against every rival wins. Tier breaks directness ties — never the reverse.
  - **R2c — Event proximity, error-band-gated:** both tied → a fixed per-field record-class table decides — for `deathDate`: {death registration, CWGC register} = proximate; {burial, memorial, probate} = downstream; {census} = irrelevant. For `birthDate`: {birth registration, baptism} = proximate; {census-implied, marriage-age-implied, memorial} = downstream. **Fires only when every losing value's delta from the winner lies within the losing record-class's own error band** (reusing `DiscrepancySeverityTable` tolerances — census ±3, death-age ±1, memorial ±2). An out-of-band delta is not explainable as informant error → R2 does not fire → open dispute.
  - Worked examples: CWGC "14 July 1918" (primary directness, primary tier) beats FindAGrave "1919" (derivative, community) at R2a → auto-resolve, profile field corrected via the normal `editProfile` transaction. Two FreeBMD quarters (DS-08's core case): identical directness, tier, and proximity → **no rule fires; stays open** and feeds C7.
  - `ApplyEngine.shouldOverwriteDateField` (`ApplyEngine.swift:171`) is extended to consult R2 *after* the span test: strictly-narrower still wins; same-span → R2; R2 inconclusive → alternative fact + dispute (replacing today's silent first-writer-wins). Dates get the provenance axis the string policy already has (`shouldOverwriteStringField`, `:205`), without ever letting a lower-quality record displace a higher one.

**Explicitly NOT resolution rules** (§2.4): majority-of-witnesses voting, death-vs-later-alive auto-correction, recency, convergence-level dominance alone.

### 4.7 C7 — Candidate hypotheses: generalising the proven `.birthYearCandidate` pattern

- **New kind `case deathYearCandidate(profileID: String, year: Int)`** in `HypothesisKind` (`AncestorKit/Sources/AncestorKit/Research/ResearchHypothesis.swift:189`; `.birthYearCandidate` precedent at `:262`), with **new file** `Ancestor Research/Services/Research/HypothesisEngine+DeathYearCandidate.swift` mirroring the birth file's structure exactly (three static methods + three central-switch arms at `HypothesisEngine.swift:73/:106/:242` — the enum's own doc comment describes this recipe):
  - *Generator:* ≥2 distinct precise years across `Profile.sources[.deathDate]` **or** an open F1 `deathDate` dispute (the dispute layer is the second entry condition — this is how DS-08/DS-25's buried alternatives get an owner). Emits one hypothesis per candidate year, ascending, stable IDs, all sharing one **`candidate_group_id`** ⟨G5⟩.
  - *Grader (deterministic):* candidate year Y is **contradicted** by any accepted alive-evidence (life_event census/residence/military) dated > Y (reuses F3's predicate); **supported** when a census year falls strictly *between* the competing candidates and the subject is present (alive at 1911 decides 1905-vs-1913), or when age-at-death arithmetic (deathYear − recordedAge vs known birth year, ±1) fits Y and misfits every competitor; **inconclusive** otherwise. Margins mirror the birth grader's decisive-margin/corroboration-margin discipline.
  - *Deficit ladder:* level 1 — FreeCen probes for census years inside the discriminating window between min and max candidate years; level 2 — probate probe (probate year ≥ death year, usually within 2).
  - *Apply:* `ApplyEngine.applyDeathYearCandidate` clones `applyBirthYearCandidate` (`ApplyEngine.swift:402`), preferring the attested FieldSource's raw for month detail. Accepting resolves the linked dispute (`.accepted(chosenSource)`) and auto-marks the group's rivals `.contradicted` ⟨G5⟩.
- **`candidate_group_id` + choose-one UI ⟨G5⟩:** nullable column on `research_hypotheses` (v41). All rival candidates in a group render as **one card** with a choose-one control; accepting one marks every rival in the group `.contradicted` in the same transaction. The UI never shows parallel Accept buttons for members of one group. Applies to `.birthYearCandidate` (retrofit — its generator stamps the group ID from CL5), `.deathYearCandidate`, and `.parentIdentityCandidate`.
- **Automatic ladder re-adjudication ⟨G12⟩:** when a linked candidate hypothesis flips to `.supported` with all rivals `.contradicted`, `DisputeResolver` re-runs against the linked dispute and surfaces a **proposed resolution** on the dispute row — requiring the human Accept click, never auto-applied. (Consistent with the `acceptBirthYearCandidate` precedent: hypothesis verdicts propose; humans accept.)
- **Spouse identity (F4b) and parent identity (F4a) do NOT get value-candidate kinds** (§2.9). Instead:
  - F4a disputes seed a **new engine-origin kind `.parentIdentityCandidate`** ⟨G10⟩ — *not* `.parentCandidates`, whose user-seeded-only contract (`ResearchHypothesis.swift:269`, `HypothesisEngine+ParentCandidates.swift:5-15`) the engine must never break. The new kind reuses the same grader machinery (confirmed-parent conflict checks + the no-self-confirmation rule, `HypothesisEngine+ParentCandidates.swift:123/:642`: *supported requires linkage back to the subject*) but regenerates freely without colliding with Epic 13 seeds. **The candidate set always includes the tree's existing accepted edge as a candidate with its own provenance** ⟨G11⟩.
  - F4b disputes surface with a one-tap "investigate as second marriage" affordance seeding the already-enumerated future kind `.secondMarriage(afterYear:)` (`ResearchHypothesis.swift:291` area) — **built in CL6 only if trivial, else deferred**; the dispute row itself is the non-negotiable deliverable.
- **Location conflicts get no hypothesis kind** (deliberate): no probe deterministically discriminates two place strings; honest open dispute + human is the ceiling (§7).

### 4.8 C8 — Surfacing

1. **Per-profile (exists, goes live):** `SharedProfileLayout` dispute section (`Ancestor Research/Views/Profile/SharedProfileLayout.swift:165-186`) + `ConflictResolutionView` (`Ancestor Research/Views/Conflicts/`) + the `AppState.swift:1888` resolution flow — all functional today with zero producers. CL1 makes them light up. Extend the snapshot dispute load (`ProjectDatabase.swift:1421`) to carry the new `severity`/`kind`/`witness_summary` columns; the snapshot's `[ProfileField: FieldDispute]` map keys stay valid because C3 guarantees ≤1 open dispute per (field, kind). Non-field kinds (`timeline`/`parentRole`/`spouseIdentity`) render in a new "Conflicts" section of the profile layout; resolution actions: pick-a-value (F1/F2), mark-not-the-same-person → discard the offending attestation (F3/F4b), choose-parent via the candidate card / keep-both-flag-adoptive (F4a), defer. **ConflictResolutionView renders the `witness_summary` weighing inputs** ⟨G8⟩ (per value: independent witness count, best tier, best directness, proximity class) — the user sees the weighing, not just the verdict.
2. **Project-level:** a **Disputes list** in the Audit surface (`Ancestor Research/Views/Audit/` — currently `AuditPlaceholderView.swift` + `SourcingIntegrityView.swift`) — all open disputes, severity-desc, count badge on the tab; plus two new registry `AuditRule`s (`AncestorKit/Sources/AncestorKit/AuditRule.swift:57-80`): `ParentsPerRoleRule` and `RecordAfterDeathRule` — thin wrappers over F4a/F3 so the audit pass and the sweep can never disagree.
3. **GPS honesty:** `GPSScorer.criterion4ConflictResolution` (`GPSScorer.swift:156`) is rewritten: `met = openDisputes(subject).isEmpty && !hasRivalConfirmedClusters(result) && noInconclusiveValueCandidateHypotheses(subject) && runDiscrepancies(severity ≥ .conflict).isEmpty`. Reason strings enumerate what is open ("2 unresolved conflicts: deathDate (1900 vs 1901), two mother candidates") — and **resolved disputes count toward met with their evidence cited** ("1 conflict resolved: deathDate by R2a — CWGC primary over community memorial"), which is what "resolution of conflicting evidence" means in GPS. Rival-confirmed-clusters = ≥2 clusters with `matchQuality` ≥ confirmed and disjoint identity anchors — the John 1840/41 pair finally holds criterion 4 open. `BulkReviewView.frictionTier`'s `.conflict` tier keys off the same predicate (its current one is equally unreachable, DS-14 verifier). Criterion 3 (`GPSScorer.swift:135`) switches to `scoreValueGroups` per field (DS-20).
4. **ClusterReviewView:** records carrying a run-time discrepancy ≥ `.conflict` get a "conflicts with tree" badge before apply; cluster Apply shows "will open N disputes"; T-D same-year-census splits are badged.
5. **MCP (read-only surface):** `get_profile` gains a `disputes` array; new resource `ancestor://profile/{id}/disputes`. The §14.3 auto-approval gate (`FieldResearcherMCP/Sources/MCPServer.swift` — `evaluateApproval` at `:2657`, `would_create_dispute` refusal at `:2756`, `autoApprovableFields` at `:2432`) keeps its recomputed refusal and **adds** "open dispute exists on target field → refuse" (timeline/parentRole disputes aren't derivable from field_sources alone, which is all the gate reads today). Evidence Firewall unchanged: disputes are written only by the app; MCP reads.
6. **T9 dossier tie-in (contract only, no dossier design):** the dossier's conflict section is a render of `allDisputes(profileID:)` — open + resolved-with-rule + resolved-by-user, each with its deterministic `reasoning` string, per-rung `ladder_trace`, and `witness_summary`. MLX may paraphrase those strings; the strings themselves are the fallback and the source of truth.

---

## 5. Schema — migration `v41_conflict_layer` (single migration; ships with CL-Change1)

Current migration head is `v40_run_request_resume_audit` (`ProjectDatabase.swift:1248`), so v41 is next. `field_disputes` is empty in every production database (DS-13: zero production writers ever), so every change is additive and risk-free. Changes 2–6 need **no further migration**.

```sql
ALTER TABLE field_disputes ADD COLUMN entity_kind TEXT NOT NULL DEFAULT 'profile';
ALTER TABLE field_disputes ADD COLUMN kind TEXT NOT NULL DEFAULT 'fieldValue';
      -- 'fieldValue' | 'timeline' | 'parentRole' | 'spouseIdentity'
ALTER TABLE field_disputes ADD COLUMN severity TEXT;          -- DiscrepancySeverity raw
ALTER TABLE field_disputes ADD COLUMN detected_by TEXT;       -- ⟨G6⟩ 'applyEngine'|'runSweep'|'consistencySweep'
ALTER TABLE field_disputes ADD COLUMN evidence_json TEXT;     -- non-FieldSource competitors BY REFERENCE:
      -- life_event IDs (F3/T-D), relationship IDs + record refs (F4a/F4b). Never WitnessKeys (§2.6).
ALTER TABLE field_disputes ADD COLUMN ladder_trace TEXT;      -- ⟨G2⟩ JSON [{rung, outcome, detail}]
ALTER TABLE field_disputes ADD COLUMN witness_summary TEXT;   -- ⟨G8⟩ JSON per-value {witnesses, bestTier,
      -- bestDirectness, proximityClass}; display cache, recomputed on every upsert
ALTER TABLE field_disputes ADD COLUMN resolved_at DATETIME;
CREATE UNIQUE INDEX idx_field_disputes_open
      ON field_disputes(entity_id, kind, field) WHERE resolution IS NULL;

ALTER TABLE research_hypotheses ADD COLUMN candidate_group_id TEXT;   -- ⟨G5⟩ (table: v26, ProjectDatabase.swift:813)
CREATE INDEX idx_research_hypotheses_group ON research_hypotheses(candidate_group_id);

ALTER TABLE research_discrepancies ADD COLUMN run_id TEXT;
      -- NOTE: severity already exists in the v1 schema (ProjectDatabase.swift:269) — base design corrected.

-- project_meta keys: 'conflict_sweep_high_water' (sweep skip), 'v41_conflict_backfill_done' (one-shot flag)
```

Type changes (AncestorKit — all Codable-additive, old JSON decodes fine):
- `FieldDispute` (`FieldTypes.swift:75`) gains `kind`, `severity`, `detectedBy` (decode-defaulted).
- `DisputeResolution` (`FieldTypes.swift:100`) gains `case rule(id: String, accepted: FieldSource)`.
- `HypothesisKind` (`ResearchHypothesis.swift:189`) gains `.deathYearCandidate(profileID:year:)` and `.parentIdentityCandidate(…)` (+ discriminator arms).

No changes to `ScoredRecord`, no changes to the Evidence Firewall write surface, no new writable MCP tables.

---

## 6. Changes

Each change is independently shippable and gated by `xcodebuild test`. Ordering is load-bearing: producer before sweep before reporting before witness identity before resolution before seeding — CL1 ships the honesty win with **zero write-outcome changes** (R2 deferred to CL5), so the first gate is pure additive detection.

### Change 1 — CL1: producer core (L)

**Scope:** v41 migration (§5); `ConflictDetector` F1/F2/F4a/F4b; `DisputeStore` upsert + witness-gated-reopen scaffolding + `detected_by`/`ladder_trace`/`witness_summary` writes; ApplyEngine hooks T-A (date/string else-branches, marriage no-op → F4b dispute + outcome notice, parent-proposal pre-check + warning, pending-fact post-write hook); `DisputeResolver` with R3 shield + R1 filter + trace plumbing (R0 inert until CL4, R2 until CL5 — every persisted dispute still records the evaluated rungs); `ConflictResolutionView` + `SharedProfileLayout` dispute section go live; snapshot load extended.

**Acceptance criteria:**
1. Applying a second same-span conflicting deathDate opens exactly one dispute (`kind='fieldValue'`, reason from `GenealogicalDate` comparison, `detected_by='applyEngine'`, both competing sources present, `ladder_trace` recording R3/R1 evaluations); re-applying is idempotent (no second row; unique partial index holds).
2. `applyMarriageToSubjectSpouseEdge` with a mismatching record spouse-surname writes a `spouseIdentity` dispute and a reported outcome — the `ApplyEngine.swift:94` silent return is gone.
3. `acceptParentProposal` onto an occupied biological role proceeds AND opens a `parentRole` dispute; the accept UI shows the pre-computed warning.
4. End-to-end resolution: pick-a-value in `ConflictResolutionView` → `resolveFieldDispute` transaction → canonical field updated → dispute resolved `.accepted` → undo restores both.
5. **Zero write-outcome change:** `shouldOverwriteDateField`/`shouldOverwriteStringField` behaviour is byte-identical (regression tests over the apply fixtures); the only new persistence is dispute rows.
6. A conflict against a user-manual (`.userAuthoritative`) value is never auto-resolved (R3), in either direction.
7. v41 migrates a copy of a real project DB green; `FieldDispute` old-JSON decode passes.

**Blast radius:** `ProjectDatabase.swift` (migration + DisputeStore + snapshot), `ApplyEngine.swift`, new `ConflictDetector.swift`/`DisputeResolver.swift`, `FieldTypes.swift` (2 types), `ConflictResolutionView.swift`, `SharedProfileLayout.swift`. Publisher/viewers: zero (disputes are Mac-local evidence-layer data). Python parity: none — twin format untouched; `compare_twins.py`/`compare_gaps.py` stay green as the no-op proof.

### Change 2 — CL2: standing sweep, retroactivity, audit rules (M)

**Scope:** `ConflictSweep` (F1/F2 over existing field_sources, F3 death-vs-later-alive, F4a, F4b, T-D same-enumeration-year tree-state arm); v41 one-shot backfill; sweep triggers (project open with high-water mark, post-apply, post-import, manual); Audit **Disputes list** + `ParentsPerRoleRule`/`RecordAfterDeathRule` in the registry; profile "Conflicts" section for non-field kinds; `ClusteringEngine.findContradiction` same-enumeration-year split trigger ⟨G13⟩ + cluster badge. **After CL2 the detection-completeness invariant holds for existing trees.**

**Acceptance criteria:**
1. A profile with deathDate 1905 and an accepted 1911 census LifeEvent (DS-15's exact scenario) gets an open `timeline` dispute from the sweep, `detected_by='consistencySweep'` — regardless of write order, retroactively on first launch after migration.
2. A profile with two biological mothers (DS-26 damage) is flagged by both the sweep and `ParentsPerRoleRule`; the two can never disagree (shared predicate).
3. Two same-`censusYear` life_events on one profile open a `timeline` dispute; two same-`censusYear` records in one cluster force a split and a badge.
4. Sweep is idempotent: second run adds zero rows; high-water mark skips an unchanged project.
5. Backfill runs exactly once (`project_meta` flag) and completes on the largest fixture tree within an acceptable project-open budget.
6. Audit tab shows open-dispute count; list sorts severity-desc; rows deep-link to the owning profile's resolution UI.

**Blast radius:** new `ConflictSweep.swift`, `ClusteringEngine.swift` (one new split rule — run behaviour changes only by over-splitting, which is the safe direction), `AuditRule.swift` (+2 rules), `Views/Audit/`, `SharedProfileLayout.swift`. Python parity: F3's predicate is the same census-after-death impossibility Python enforces at scoring time (`ScoringRules.validateRecord` ← `agent/scorer.py`); the sweep generalises it to tree state — new territory, no Python counterpart to diverge from.

### Change 3 — CL3: honest reporting (M)

**Scope:** GPS criterion 4 rewrite (open disputes + rival confirmed clusters + inconclusive value candidates + run discrepancies; met-with-evidence framing for resolved disputes); criterion 3 switches to `scoreValueGroups` (value partition now; interim lineage counting per §4.5 — stated in code comment); `research_discrepancies` persistence (`run_id` stamped) + envelope inclusion in `buildResultEnvelope`; ClusterReviewView conflict badges + "will open N disputes" on Apply; `BulkReviewView.frictionTier` rewire.

**Acceptance criteria:**
1. The John 1840/41 rival-cluster pair holds criterion 4 unmet with a reason string naming both candidate years — the DS-07/DS-14 unreachable branch is now covered by a test.
2. A profile whose only conflict was rule-resolved reports criterion 4 met with the rule ID in the reason string.
3. Contradicting values for one field can no longer pool: criterion 3 on the DS-24 fixture (birth 1881 + census-implied 1895) reports per-value levels, not `.confirmed`.
4. Run discrepancies appear in `research_discrepancies` (with `run_id`) and in the MCP result envelope; a ≥ `.conflict` fact-grade discrepancy also upserts a dispute (`detected_by='runSweep'`).
5. `BulkReviewView`'s `.conflict` friction tier is reachable (test with an open dispute).

**Blast radius:** `GPSScorer.swift`, `ConvergenceEngine.swift` (scoreValueGroups façade), `ResearchPipeline.swift` (persist call), `RunRequestWatcher.swift` (envelope), `ClusterReviewView.swift`, `BulkReviewView.swift`. GPS is a reporting surface (DS-20 verifier: it gates no writes), so this change alters no apply behaviour.

### Change 4 — CL4: witness identity (M)

**Scope:** `WitnessIdentity.swift` (C1, with ⟨G1⟩ name components and ⟨G4⟩ lineage-payload + static FS collection mapping); `ConvergenceEngine` witness-family counting swaps in behind `scoreValueGroups`; F5 same-witness detection + R0 goes live; `DiscrepancySeverityTable` convergence-upgrade path fed with per-value witness convergence; `sourcingStrength.independentWitnessCount`; witness-gated reopen ⟨G3⟩ now enforced with real keys.

**Acceptance criteria:**
1. FreeBMD "SMITH John, Belper Q2 1860 7b/143" + FS vol-less transcription of the same row + FindAGrave copy = **1 witness** → `.singleSource`-tier arithmetic (DS-03 test).
2. Two GRO entries sharing vol/page but differing in `surnameNorm`/`givenInitial` (siblings on one page) = **2 witnesses**; a value disagreement between them is a genuine conflict, not R0 variance ⟨G1⟩.
3. Two same-year census attestations for one subject reduce to one witness; material disagreement lands as F5, auto-resolved by R0 where one transcription is higher-tier, traced in `ladder_trace`.
4. A resolved dispute does NOT reopen when another transcription of an already-weighed witness arrives; it DOES reopen (new row) when a genuinely new WitnessKey asserts a conflicting value ⟨G3⟩.
5. No WitnessKey is ever serialised (compile-level: not Codable; test greps persistence payloads).
6. UI badge shows `independentWitnessCount` where it previously showed lineage count.

**Blast radius:** new `AncestorKit/.../WitnessIdentity.swift`, `ConvergenceEngine.swift`, `ConflictDetector.swift` (F5), `DisputeResolver.swift` (R0), `DiscrepancySeverityTable` call sites. AncestorKit addition is app-facing only; published schema untouched. Python parity: Python has no witness-identity concept (its convergence counts lineages the same flawed way — DS-03 is a shared gap, and per `feedback_swift_is_what_ships` the fix lands Swift-only; the twin/GEDCOM formats carry no convergence data so parity tooling is unaffected).

### Change 5 — CL5: deterministic resolution + death disambiguation (L)

**Scope:** R2 quality-dominance ladder (R2a originality / R2b tier / R2c error-band-gated proximity ⟨G7⟩) wired into `shouldOverwriteDateField`; `.deathYearCandidate` (generator/grader/deficit/apply + three `HypothesisEngine` switch arms at `:73/:106/:242`); `candidate_group_id` stamped by both year-candidate generators + **choose-one card UI** ⟨G5⟩ (accepting one marks rivals `.contradicted`, one transaction); accepting a candidate resolves its linked dispute; **automatic ladder re-adjudication → proposed resolution** ⟨G12⟩.

**Acceptance criteria:**
1. CWGC span-0 date displaces an earlier FindAGrave span-0 date via R2a; the dispute persists as resolved `.rule(id:"R2a", …)` with full `ladder_trace`; the DS-09 scenario test goes green.
2. Two FreeBMD quarters: no R2 rung fires (trace shows R2a/R2b tie, R2c same-class), dispute stays open, `.deathYearCandidate` group generated with shared `candidate_group_id`.
3. A census delta outside the losing class's error band blocks R2c (trace records the band arithmetic) → open dispute ⟨G7⟩.
4. Alive-in-1911 evidence contradicts a 1905 death candidate (grader reuses F3's predicate); a census year strictly between two candidates supports the survivor.
5. Choose-one card: accepting one candidate marks all group rivals `.contradicted` atomically; the UI renders exactly one accept control per group ⟨G5⟩.
6. When a linked candidate flips `.supported` with all rivals `.contradicted`, the dispute shows a **proposed** resolution; nothing is written until the human clicks Accept ⟨G12⟩.
7. R3 still shields user-authoritative values from R2 in both directions.

**Blast radius:** `ApplyEngine.swift` (**first write-behaviour change of the programme** — confined to same-span date conflicts, previously silent first-writer-wins), `DisputeResolver.swift`, new `HypothesisEngine+DeathYearCandidate.swift`, `HypothesisEngine.swift` (3 arms), `ResearchHypothesis.swift` (kind), `ResearchViewModel` accept flow, candidate card view. Python parity: none — Python has no overwrite policy or hypothesis framework; the birth-candidate pattern being generalised is Swift-native (spec §5.x lineage).

### Change 6 — CL6: investigation seeding + MCP surface (M)

**Scope:** F4a disputes seed engine-origin `.parentIdentityCandidate` sets ⟨G10⟩ including the incumbent tree edge as a candidate with its own provenance ⟨G11⟩; grader enforces supported-requires-linkage-back-to-subject (no self-confirmation — reusing `HypothesisEngine+ParentCandidates.swift:123/:642` machinery); MCP `disputes` array in `get_profile` + `ancestor://profile/{id}/disputes` resource + §14.3 open-dispute refusal; F4b "investigate as second marriage" affordance (build `.secondMarriage(afterYear:)` only if trivial, else defer — the dispute row is the deliverable).

**Acceptance criteria:**
1. An F4a dispute yields one candidate group containing BOTH mothers — the accepted edge (provenance: its `existence` FieldSource, E4) and the record-derived rival — rendered as one choose-one card; `.parentCandidates` rows (user-seeded) are untouched by generation/regeneration (contract test).
2. A candidate identity is graded `.supported` only via linkage back to the subject (child's birth-MMN, household co-presence); a bare index row stays `.inconclusive`.
3. `get_profile` over MCP returns open + resolved disputes read-only; attempting any dispute write through MCP fails (firewall unchanged).
4. §14.3 gate refuses auto-approval on any field carrying an open dispute, including `timeline`/`parentRole` kinds the field_sources recomputation cannot see; refusal reason code names the dispute.
5. Choosing a candidate resolves the F4a dispute and (if the loser was a ghost created by the rival accept) routes the loser through the existing edge-removal transaction — undo-compatible.

**Blast radius:** `ResearchHypothesis.swift` (kind), new/extended grader file, `HypothesisEngine.swift`, `FieldResearcherMCP/Sources/MCPServer.swift` (read surface + gate clause), candidate card view. FieldResearcherMCP builds standalone (`swift build`). Python parity: none.

---

## 7. Non-goals (explicit)

### 7.1 Companion gate repairs — OUT of this spec, tracked in SANDWICH_AUDIT triage ⟨G14⟩

Named here with pointers so triage does not lose them; they are scorer/subject-construction changes, not conflict-layer work, and bundling them would muddy CL gates:

- **DS-12 scorer half:** `RecordScorer` marriage clause — a record spouse-surname *contradicting* the known spouse should `.softFail` the familyContext gate (symmetric with the census clause at `RecordScorer.swift:866-869`) instead of falling to the terminal `.skip` at `RecordScorer.swift:954`. Contradiction is negative evidence, not absence of information. The conflict layer guarantees the trace either way (F4b).
- **DS-15 prevention half:** derive a `subject.aliveAsOf` lower bound from accepted LifeEvents in `ResearchSubject.fromProfile` (`ResearchSubject.swift:399`; today `deathYearFrom` reads only `profile.deathDate` at `:545`), so the scorer stops *accepting* death records the tree already contradicts — complementing CL2's retroactive detection.

### 7.2 Everything else

1. **No dossier design** — T9 consumes `allDisputes()` + `ladder_trace` + `witness_summary`; contract only (§4.8.6).
2. **No MLX involvement** in detection, grading, or resolution; narration elsewhere, later.
3. **No FamilySearch work** — the static collection→original mapping (§4.1) is a local table; no FS client, no FS spec coupling.
4. **No scorer-gate repairs** beyond §7.1's named pointers: name-ladder fixes (DS-04/05/06), tolerances (DS-01/02/23), parish parent-check port (DS-10), location validation (DS-11), geography literals (DS-17/19), married-surname axes (DS-18), GPS criteria 1/2 (DS-21/22), analyser port (DS-27) are separate campaigns.
5. **No cluster-merge adjudication** — clustering keeps when-in-doubt-split; rival clusters are *reported* (criterion 4), never auto-merged. The only clustering change is one additional split trigger (T-D), in the safe direction.
6. **No `locationCandidate` hypothesis kind** (undiscriminable by probes — honest dispute is the ceiling) and **no `spouseIdentityCandidate` value kind** (identity ≠ field value; F4b gets dispute + optional `.secondMarriage` investigation).
7. **No majority-vote / recency / convergence-alone resolution rules** — rejected as not bulletproof (§2.4).
8. **No WikiTree write-back of resolutions** (account blocked; local-only per existing convention).
9. **No new MCP write surface** — disputes are app-written; the Evidence Firewall (`pending_facts` + `leads` only) is untouched.
10. **No persisted WitnessKeys** (§2.6) and no `SourceLineage` schema change — the enum and its payloads stand; C1 merely starts *reading* the `of:` payload nothing consumed before (DS-03 verifier).

---

## 8. Python-parity note

The conflict layer is **new, Swift-first territory** — Python has no dispute persistence, no overwrite policy, no hypothesis framework, and shares the DS-03 lineage-counting gap. There is therefore no port-faithfully obligation here (`feedback_port_from_python` governs porting existing rules; `feedback_swift_is_what_ships` governs where new behaviour lands). Where the layer *reuses* ported predicates it must not fork them: F3/T-D reuse the census-after-death impossibility semantics already ported into `ScoringRules.validateRecord` (from `agent/scorer.py`), and F1's refinement test reuses ApplyEngine's narrower-span rule. The twin/GEDCOM interchange formats carry no dispute or convergence data, so `compare_twins.py` / `compare_gaps.py` must stay green throughout as the no-op proof — run them at every CL gate.

---

## Appendix A — integration-point map (verified against the working tree 2026-07-13)

| Surface | Location |
|---|---|
| v40 migration head (v41 goes after) | `Ancestor Research/Services/ProjectDatabase.swift:1248` |
| `field_disputes` v1 table / open-index | `ProjectDatabase.swift:139` / `:157` |
| `addFieldDispute` / `resolveFieldDispute` | `ProjectDatabase.swift:3373` / `:3400` |
| Snapshot dispute load | `ProjectDatabase.swift:1421` |
| `reconcileProfileDateFields` (backfill pattern) | `ProjectDatabase.swift:3551` |
| `research_discrepancies` (no INSERT anywhere; has `severity`) | `ProjectDatabase.swift:262` |
| `research_hypotheses` table (v26) | `ProjectDatabase.swift:813` |
| `FieldDispute` / `DisputeReason` / `DisputeResolution` | `AncestorKit/Sources/AncestorKit/FieldTypes.swift:75` / `:94` / `:100` |
| ApplyEngine: date/string else-branches | `Ancestor Research/Services/Research/ApplyEngine.swift:107-126` / `:128-148` |
| ApplyEngine: marriage silent no-op | `ApplyEngine.swift:72-104` (guard at `:94`) |
| ApplyEngine: parent accept / edge create | `ApplyEngine.swift:258` / `:314` |
| ApplyEngine: overwrite policies / birth-candidate apply | `ApplyEngine.swift:171` + `:205` / `:402` |
| Dispute resolution flow (app) | `Ancestor Research/ViewModels/AppState.swift:1888` |
| `ConflictResolutionView` | `Ancestor Research/Views/Conflicts/ConflictResolutionView.swift` |
| Profile dispute section | `Ancestor Research/Views/Profile/SharedProfileLayout.swift:165-186` |
| `ConvergenceEngine.score` / lineage set / directness cap | `Ancestor Research/Services/Research/ConvergenceEngine.swift:21` / `:29-31` / `:116` |
| GPS criteria 1–5 | `Ancestor Research/Services/Research/GPSScorer.swift:95/:115/:135/:156/:184` |
| `detectDiscrepancies` / result envelope | `Ancestor Research/Services/Research/ResearchPipeline.swift:2415` / `RunRequestWatcher.swift:525` |
| `ClusteringEngine` impossible-filter / split rules | `Ancestor Research/Services/Research/ClusteringEngine.swift:21` / `:311` |
| HypothesisEngine central switches | `Ancestor Research/Services/Research/HypothesisEngine.swift:73/:106/:242` |
| `HypothesisKind` enum / `.birthYearCandidate` / `.parentCandidates` user-only contract | `AncestorKit/Sources/AncestorKit/Research/ResearchHypothesis.swift:189` / `:262` / `:269` |
| ParentCandidates grader (no-self-confirmation) | `Ancestor Research/Services/Research/HypothesisEngine+ParentCandidates.swift:123/:642` |
| Audit registry | `AncestorKit/Sources/AncestorKit/AuditRule.swift:57-80` |
| Audit views (Disputes list lands here) | `Ancestor Research/Views/Audit/` |
| MCP gate: evaluateApproval / dispute refusal / field set | `FieldResearcherMCP/Sources/MCPServer.swift:2657` / `:2756` / `:2432` |
| `SourceLineage` (+ `of:` payload) | `AncestorKit/Sources/AncestorKit/Research/SourceLineage.swift:7-16` |
| BMD vol/page/quarter fields / `CensusRecord` shape | `AncestorKit/Sources/AncestorKit/Research/RecordTypes.swift:44-47, :72-75, :100-103` / `:142-154` |
| `EvidenceDirectness` / `DiscrepancySeverity` / `SourceOrigin.userAuthoritative` | `AncestorKit/.../Research/EvidenceDirectness.swift:10` / `.../Research/DiscrepancySeverity.swift:4` / `.../SourceOrigin.swift:63` |
| Severity table + convergence upgrade | `Ancestor Research/Services/Research/DiscrepancySeverityTable.swift:16/:50` |
| New files | `AncestorKit/.../Research/WitnessIdentity.swift`, `Services/Research/ConflictDetector.swift`, `Services/Research/ConflictSweep.swift`, `Services/Research/DisputeResolver.swift`, `Services/Research/HypothesisEngine+DeathYearCandidate.swift` |

*Evidence base: `AncestorApp/SANDWICH_AUDIT_2026-07.md` (DS findings + verifier corrections, 2026-07-13); three-design competition output (detection-first base + nine-graft consolidated review, 2026-07-13); code citations re-verified against the working tree 2026-07-13. Line references that had drifted in the competition text (HypothesisEngine switches, `research_discrepancies.severity`) are corrected above.*
