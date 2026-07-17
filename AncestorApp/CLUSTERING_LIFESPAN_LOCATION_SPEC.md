# CLUSTERING_LIFESPAN_LOCATION_SPEC

**Status:** accepted-direction 2026-07-17. Mini-spec for the two remaining
over-split defects in `ClusteringEngine` (ROADMAP "clustering lifespan /
identity-constraint hardening", items a + b — Barbara Ayre class). Core surgery,
not a patch: both make MORE records attach, so both must be paired with a
location discriminator or they trade over-split for over-merge.

Invariant (unchanged): **prefer over-split to over-merge** — a person's records
split into two clusters is user-fixable; two people merged is not.

## Background — the attach mechanics

`assignmentScore = date×0.4 + location×0.3 + household×0.3`; a record attaches
to its best cluster at `score ≥ 0.4`. `date = 1.0` inside the cluster's lifespan
window. So **a record inside the window attaches on date ALONE (0.4)** — location
barely gates today. That is why widening the window (item a) is dangerous without
a location fix, and why item (b) alone under-credits real geographic consistency.

## Item (a) — record-type-aware seed lifespan (over-split)

**Defect:** a non-birth seed gets lifespan `(year−80, year+5)` (ClusteringEngine
`seedClusters` no-birth branch + `assignRecords` new-cluster fallback). The `+5`
forward bound is only right for a *terminal* event (death/burial): a marriage or
census subject lives on for decades, so their later records fall outside the
window (`date=0`) and seed their own clusters — over-split.

**Fix:** a `seedLifespan(year:record:)` helper, forward bound by record kind:
- **birth / baptism** → `(year, year + 110)` — born now, full life ahead.
- **death / burial / military / probate** → `(year − 110, year + postDeathMargin)`
  — terminal; born up to a lifespan before, nothing after (+ lag margin).
- **census** → age-anchored when the record carries age/birthYear:
  `(birth, birth + 110)`; else `(year − 90, year + 110)`.
- **marriage / parish / pedigree / other non-terminal** → `(year − 90, year + 90)`
  — an adult at the event; born up to ~90y before, may live ~90y after.

Constants: `maxLifespanYears = 110`, `maxAdultAgeYears = 90`, existing
`postDeathMarginYears = 2`.

## Item (b) — same-county credit, including foreign counties (over-split)

**Defect:** `locationConsistency` only scores relative to the SUBJECT's home
county. Two records in the same *foreign* county (e.g. both Yorkshire, home DBY)
each fail the local checks and fall through to `0.0` — so a subject who lived
outside the home county has their own records scored as geographically
contradictory, and over-splits.

**Fix:** derive each district's county via the national
`FreeBMDDistrictCatalogue` (`district(named:)?.chapmanCode`) — no hardcoded
regions — and grant **0.7 when the record's county equals any cluster district's
county, home or foreign**. Sits right after the exact-district (1.0) tier; the
existing home-county tiers remain for the partial/unknown cases.

## Item (a)+(b) safety — the location veto (prevents the new over-merge)

Widening the window (a) means a same-name record in a *different* county, decades
later, would now sit inside the window and attach on date alone (`0.4`). That is
the exact over-merge the ROADMAP gate forbids. So attachment gains one veto,
mirroring the existing death-cap veto in `assignmentScore`:

> If the record's county is derivable AND every located record in the cluster has
> a derivable county AND the record's county matches NONE of them → **refuse
> (score 0.0)**.

This makes location a real discriminator: the widened window only ever pulls in
same-county or unknown-county records. Cross-county migration therefore
over-splits (two clusters, user merges) rather than risking a namesake merge —
consistent with the invariant. Unknown counties stay permissive (no veto), so the
change never *tightens* today's behaviour for location-less records.

## Tests (gate)

- **(a) over-split fixed:** a marriage seed + a same-county census ~15y later now
  land in ONE cluster (previously two).
- **(b) over-split fixed:** two records in the same FOREIGN county (home DBY, both
  Yorkshire) cluster together (previously `location=0` → split).
- **over-merge NOT introduced:** a same-name record in a DIFFERENT known county,
  same era, does NOT attach (veto) even though the widened window now covers its
  year.
- **terminal unchanged:** a death seed keeps its forward `+margin` bound; the
  infant-death-vs-later-marriage fixture (item c, already shipped) still splits.
- **location-less permissive:** a record with no derivable district/county still
  attaches on date+household as before (no veto).
- SANDWICH_AUDIT cross-check: wider lifespans + same-county credit cannot push an
  unrelated (different-county) record over `0.4`.
