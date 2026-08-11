# Regions data — bundled place catalogues

These JSON files are the **private inputs** to the app's location model
(LOCATION_MODEL_SPEC, Guiding rule "One entry point"). All place data flows out
through `PlaceAuthorityRegistry` / `PlaceResolver`; nothing else should read
these files ad-hoc. Each file has exactly one loader:

| File | Loader (single owner) | Role |
|------|-----------------------|------|
| `uk-places.json` | `LocationGazetteer.shared` | ~300 curated gazetteer entries (counties, major towns, all Derbyshire detail) keyed `CHAPMAN:Place` (`DBY:Crich`). Powers the `LocationPicker` typeahead and `PlaceResolver.resolve(placeText:)`. Optional E3 hierarchy fields (`parentID`/`validFrom`/`validTo`) are present in the schema but unpopulated in this starter set. |
| `freebmd-districts.json` | `FreeBMDDistrictCatalogue.shared` | ~1125 GRO registration districts with their parish lists and FreeBMD district codes. The parish→registration-district authority (`Hognaston` ∈ `Ashbourne`) behind `RegistrationDistrictResolver`, the birth-conflict guard (Slice B), and `Profile.birthRegistrationDistrict` (Slice C). |
| `uk-chapman-codes.json` | `UKChapmanCodes.shared` | The 94 UK county Chapman codes (`DBY` → Derbyshire) + umbrella expansions. Feeds `ChapmanCodeResolver` and county-name ↔ code lookups. |
| `county-adjacency.json` | `RegionConfig` | County adjacency graph for `.adjacent`-scope search fan-out. |

`PlaceAuthorityRegistry` derives the typed `PlaceAuthority` hierarchy from the
first three (gazetteer entries + FreeBMD districts + Chapman codes); it does not
own a raw file of its own.

## Removed

- `fs-place-ids.json` — a 56-county FamilySearch place-id extract from the
  abandoned FS place crawl. It had **zero code references** and was deleted in
  Slice A (2026-08-11). FamilySearch is a tree read/write integration, not a
  records/place source (see memory `project_familysearch_beta_program`); if FS
  place resolution is ever revived it should resolve **into** the canonical
  `PlaceAuthority` ids, not reintroduce a parallel id space. History has the file
  if needed.
