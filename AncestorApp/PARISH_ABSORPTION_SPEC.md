# PARISH_ABSORPTION_SPEC

Absorbing the rich detail a FreeREG parish register entry carries — marriage,
baptism, burial — onto the tree, the same way census records already absorb.

Status: **ACCEPTED 2026-08-06.** Changes A–D build now (all three parish
event types). Change E (CWGC / FamilySearch attached kin) is specced for a
later phase.

---

## 1. The problem

A FreeREG record is parsed into a fully-typed `FreeREGDetail` payload
(`AncestorKit/…/FreeREGRecord.swift`) — groom + bride each with age,
condition, occupation, abode; **both** sets of parents; witnesses; church;
register reference; transcriber. That payload is persisted on
`ParishRecord.detail` and read by `CitationRenderer` and `RecordScorer`.

**On apply, almost none of it reaches the profile.** A FreeREG record is a
`.parish(ParishRecord)` case, not a `.marriage(MarriageRecord)` — and the
absorption machinery keys on the enum case:

- `AbsorptionPlan` (`Services/Research/AbsorptionPlan.swift`) emits a
  `.spouseEdge` only for `.marriage`; `.parish` falls into the `break` arm.
- `SourceRecordProjection` (`Services/Research/SourceRecordProjection.swift`)
  returns `nil` for a `.parish` marriage ("belongs on Relationship") and a
  bare event (`details: nil`) for baptism/burial.
- `ApplyEngine.impliedBirthDate` / `impliedDeathDate` both list `.parish` in
  the nil arm — so a burial's death date and a marriage-age birth never
  corroborate anything.

Net effect of applying the Ernest Cauldwell × Mary Ward 1915 marriage
(Kirk Ireton, Holy Trinity): the profile gets a possible given-name
enrichment and nothing else. Spouse, marriage date, both fathers,
occupation (collier), abode (Loscoe, Heanor), church and witnesses are all
dropped. Census, by contrast, has `applyCensusToHousehold`,
`censusHouseholdProposal`, `loadCensusHousehold`, and census-derived
occupation/residence events. Parish has no equivalent.

This is the gap. It was found by dogfooding the Triage review of a real
record (owner report 2026-08-06).

## 2. Design principles (inherited, not invented)

- **Facts absorb automatically; relatives are offered.** The census layer
  already draws this line: fact data (occupation, residence, birthplace,
  household context) lands on apply, but adding people
  (`addCensusFamily`) is a one-click **offer** on the profile card, never a
  silent auto-create. Parish absorption follows the same split. (Owner
  decision 2026-08-06.)
- **When in doubt, split.** Creating a fresh (non-placeholder) profile for a
  named relative and letting the duplicate audit surface a merge is correct;
  silently welding a namesake onto an existing edge is not. Same posture as
  `addCensusFamily`.
- **Check before overwrite.** Every field write goes through the existing
  directional overwrite policy (`ApplyEngine.applyDateField` /
  `applyStringField`); parish data is gap-fill / corroboration, never a
  clobber. A marriage-age birth is `.calculated` (a two-year span) so the
  policy can never let it displace a precise birth.
- **Deterministic core.** No AI in this path. Subject-role resolution
  (groom vs bride), parent-surname inference, and dedup are pure functions.
- **Additive + Codable-safe.** No schema migration: the typed payload
  already persists on `ParishRecord.detail`. New life events use the
  existing deterministic-ID + `INSERT OR IGNORE` idempotency.

## 3. Subject-role resolution (the shared primitive)

A parish marriage names two principals; a baptism names a child + two
parents; a burial names a deceased + relative(s). To absorb correctly we
must know **which block is the subject**. The record's `common.givenName` /
`common.surname` is the row principal — and when the record scored as a
`fact`, the name gate confirmed the principal *is* the subject.

Add pure resolvers to the typed models (`FreeREGRecord.swift`):

```
extension FreeREGMarriage {
    enum Role { case groom, bride }
    /// The role whose person-block best matches (given, surname); falls
    /// back to gender (male→groom, female→bride) when names are ambiguous.
    func role(forGiven: String?, surname: String?, gender: Gender?) -> Role
    func principal(as: Role) -> FreeREGPerson          // groom / bride
    func spouse(of: Role) -> FreeREGPerson             // the other party
    func father(of: Role) -> FreeREGPerson?            // groomFather / brideFather
    func mother(of: Role) -> FreeREGPerson?
}
```

Match is surname-first (case-insensitive), then forename, then gender
fallback. When the record is a scored fact the principal is the subject, so
the projection layer (which has the record but not the profile) resolves via
`common.givenName`/`common.surname`; the proposal layer (which has the
profile) resolves via the profile's name + gender for extra safety.

A relative's **surname** is frequently absent from the register cell
(the groom's father shares the groom's surname and the transcriber omits it):
when `father(of:).surname` is nil, inherit the principal's surname — the same
inference `ParentInferenceEngine` already makes for a BMD father.

## 4. Change A — implied birth/death dates for parish records

`ApplyEngine.impliedBirthDate(for:)` / `impliedDeathDate(for:)` stop
returning nil for `.parish`:

- **Burial** — `impliedDeathDate` = `detail.burial.deathDate`, else the
  event date/year (a burial dates a death to within days).
  `impliedBirthDate` = `birthDateFromAge(deceased.age, at: burial/death
  year)` when the deceased's age parses to an Int.
- **Baptism** — `impliedBirthDate` = `detail.baptism.birthDate` when the
  entry records an explicit birth date (late baptisms routinely do). The
  **baptism date is never treated as a birth date** — only an explicit
  `birth_date` field feeds this.
- **Marriage** — `impliedBirthDate` = `birthDateFromAge(principal.age, at:
  marriage year)`. Marriage ages are rounded ("full age", "of age"), so the
  result is honestly `.calculated` (wide span); the directional policy keeps
  it from overwriting anything precise. Needs subject-role resolution:
  parse the principal block by `common.givenName`/`common.surname`.

Age parsing tolerates the free-text transcription ("26", "26 years", "full
age" → nil). All dates ride the existing corroboration tail of
`absorptionPlan`, so they land through the same overwrite policy and carry
the record's citation.

**Tests:** burial death-date + implied birth; baptism explicit birth date;
marriage-age → calculated birth that does *not* overwrite a precise birth;
un-parseable age → no date.

## 5. Change B — parish marriage fills the spouse edge

`AbsorptionPlan.absorptionPlan` gains a `.parish`-marriage arm that
synthesizes a `MarriageRecord` from the typed detail and emits the existing
`.spouseEdge(_)`:

- `spouseName` = the other party's full display name (`spouse(of:role)`).
- `marriageDate` = `detail.marriage.marriageDate` (or `eventDate`/`eventYear`).
- `marriagePlace` = `[parish, county]` joined.
- `common` = the parish record's common (so citation + source tier are
  unchanged).

This reuses `ApplyEngine.applyMarriageToSubjectSpouseEdge` verbatim: the
marriage date/place fill only **nil** columns on the existing spouse edge,
married-surname enrichment runs, and a stated-spouse-that-matches-no-edge
opens the same DS-12 dispute. No new write path.

The edge must already exist (a spouse linked on the tree) for the fill to
land — creating the spouse when absent is Change D's job. The two compose:
Change D adds Mary Ward and her edge; a re-apply (or the same apply, edge
now present) fills the marriage date onto it.

**Tests:** synthesized `MarriageRecord` shape (subject=groom → spouse=bride
and vice-versa); date/place fill on an existing edge; no spouse column when
the other party is unnamed.

## 6. Change C — parish occupation / residence derived events

`projectToLifeEvents` fans out parish records the way it already does census
and probate:

- **Marriage** — the principal's `occupation` → a `.occupation` life event
  dated to the marriage year; the principal's `abode` → a `.residence` event
  (window closed to the marriage year, matching the census-residence
  rationale so a one-day address can't shadow a life). Subject-role resolved
  by `common` name.
- **Burial** — the primary `.burial` event carries `causeOfDeath` /
  `placeOfDeath` in `description`, and `deathDate` on the event date when the
  burial date differs.
- **Baptism** — the primary `.baptism` event is unchanged (birth date is
  handled in Change A); church/register stay in the citation.

Derived events use the discriminated deterministic ID
(`deterministicID(…, discriminator:)`) so they never collide with the
primary event or with each other, and re-apply is idempotent.

**Tests:** marriage principal occupation + abode → two derived events with
distinct stable IDs; bride-subject resolves to the bride block; empty
occupation/abode → no event; burial cause-of-death in description.

## 7. Change D — parish family proposal (the relatives offer)

The relationship half — a direct twin of `CensusHouseholdProposal`.

### 7.1 Model

```
enum ParishFamilyProposal: Equatable {
    case canAdd(links: [ParishFamilyLink], eventYear: Int, sourceID: String, kind: ParishKind)
}
struct ParishFamilyLink {          // one proposed person
    relation: .spouse | .parent | .relative
    given: String?; surname: String?; gender: Gender?
    birthYearLow/High: Int?
}
```

`AppState.parishFamilyProposal(for:evidence:)` scans the subject's **applied**
parish evidence (same applied-detection the census proposal uses: evidence
`savedAsLead`, a projected life event on the profile, or a fact citing the
record URL) and builds net-new links:

- **Marriage** (subject = groom or bride, resolved against the profile):
  - spouse = the other party (`spouse(of:role)`), surname present.
  - subject's father = `father(of:role)` (surname inherited from subject).
  - subject's mother = `mother(of:role)`.
  - the *other* party's parents are **not** proposed as the subject's kin
    (they are the spouse's parents — offered only once the spouse exists, a
    later refinement).
- **Baptism**: both parents (`baptism.father`, `baptism.mother.person`),
  surnames inherited from the child where absent.
- **Burial** ("dau of John Smith"): the named `relative` — proposed as a
  parent when `relationship` says son/daughter-of, else surfaced as a plain
  lead (no auto-relation).

Net-new filtering mirrors `censusFamilyNetNewLinks`: skip a parent whose role
is already filled, skip a spouse/parent already matched on the tree
(`ProposalDedup` / name+year match). Nothing is proposed for a role the tree
already holds.

### 7.2 Apply

`AppState.addParishFamily(links:subject:eventYear:sourceID:)` builds fresh
profiles + edges, reusing the `addCensusFamily` conventions:

- Women who married in (a wife) route the register surname to
  `marriedSurname`, leaving maiden `lastName` empty (unknown until a
  marriage/child BMD yields it) — same rule as census.
- Parents link via the `acceptParentProposal` path so dedup, the given-name
  ghost-upgrade, and the F4a parent-role dispute all fire.
- A spouse links subject↔spouse; when the edge is created, Change B's
  marriage-date fill lands on the next apply (or is applied inline).

### 7.3 Surface

A health-strip row on `SharedProfileLayout` beneath the census row:

> "1915 marriage names spouse Mary Ward + father John Cauldwell — not on the
> tree"  → **[Add 2 people]**

Same `healthStripRow` styling, same reload-on-apply as the census offer.

**Tests:** marriage groom-subject proposes bride + groom's parents, not the
bride's parents; bride-subject symmetric; baptism proposes both parents;
net-new filtering skips a filled father role; married-in wife gets
`marriedSurname` not `lastName`; burial "dau of" proposes a parent.

## 8. Change E — other record types (specced, later phase)

The same "facts absorb, relatives offered" layer extends beyond parish, but
these sources need prose parsing or a different record shape, so they are a
separate phase:

- **CWGC / military** — `additionalInfo` routinely reads "Son of John and
  Mary Smith, of Belper" / "Husband of Jane Smith". A deterministic
  next-of-kin parser (not AI) can lift parents + spouse as a proposal. Also:
  next-of-kin address → residence.
- **FamilySearch** — an FS person carries attached parents/spouse in its own
  graph; absorbing those is an FS-source concern (the persona endpoint),
  distinct from the FreeREG typed payload.
- **FindAGrave** — memorials link family members; per the link-only policy
  these become **leads**, not auto-relations.
- **Probate** — grant text names executors/relatives ("widow", "son"); weak,
  low priority.

Not built now. Listed so the roadmap carries them as gated later stages, not
a parked bucket.

## 9. Non-goals

- No change to the scorer or convergence engine — absorption reads what the
  gates already accepted.
- No auto-creation of relatives without the one-click offer (§2).
- No new persistence schema — the typed payload and life-event tables exist.
- The spouse's parents (the *other* party's parents on a marriage) are not
  absorbed onto the subject; they belong to the spouse and are a later
  refinement once the spouse profile exists.
