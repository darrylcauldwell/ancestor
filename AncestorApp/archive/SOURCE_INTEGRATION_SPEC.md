# Source Integration Specifications

**Status:** Proposed  
**Scope:** What each source offers, what we capture, and how to use every piece of data  
**Date:** 2026-04-25  

---

## 1. FreeBMD — Civil Registration Indexes

### 1.1 What FreeBMD Is

FreeBMD is a volunteer transcription of the General Register Office (GRO) quarterly index for England & Wales, covering births, deaths, and marriages from July 1837 to ~2000. It is an **index**, not certificates — it tells you a registration exists and gives the reference needed to order the full certificate.

### 1.2 Record Types

Three record types, each with different fields depending on the period:

**Births:**

| Field | Available | Period | Notes |
|-------|-----------|--------|-------|
| Surname | Always | 1837+ | |
| Given name(s) | Always | 1837+ | First two forenames from 1867; only first forename + initials 1866 |
| Quarter | Always | 1837–1983 | Mar/Jun/Sep/Dec. Annual from 1984. |
| Year | Always | 1837+ | |
| District | Always | 1837+ | Registration district name |
| Volume | Always | 1837+ | GRO volume number |
| Page | Always | 1837+ | GRO page number |
| Mother's maiden name | From Sep 1911 | Sep 1911+ | The mother's surname before marriage |

**Deaths:**

| Field | Available | Period | Notes |
|-------|-----------|--------|-------|
| Surname | Always | 1837+ | |
| Given name(s) | Always | 1837+ | |
| Quarter | Always | 1837–1983 | |
| Year | Always | 1837+ | |
| District | Always | 1837+ | |
| Volume | Always | 1837+ | |
| Page | Always | 1837+ | |
| Age at death | Mar 1866 – Q1 1969 | 1866–1969 | Integer age in years |
| Date of birth | From Jun 1969 | 1969+ | DDMMYYYY format, replaces age at death |

**Marriages:**

| Field | Available | Period | Notes |
|-------|-----------|--------|-------|
| Surname | Always | 1837+ | |
| Given name(s) | Always | 1837+ | |
| Quarter | Always | 1837–1983 | |
| Year | Always | 1837+ | |
| District | Always | 1837+ | |
| Volume | Always | 1837+ | |
| Page | Always | 1837+ | |
| Spouse's surname | From Mar 1912 | 1912+ | |

### 1.3 Search Parameters

| Parameter | Our usage | Available but unused |
|-----------|-----------|---------------------|
| Record type (Births/Deaths/Marriages/All) | Yes — mapped from `RecordType` | |
| Surname | Yes | |
| Given name(s) | Yes | |
| Start year | Yes — from `yearFrom` | |
| End year | Yes — from `yearTo` | |
| District ID | Yes — from `additionalParams["freebmd_district"]` | |
| Spouse/mother surname | **Not used** | Could search by mother's maiden name (births 1911+) or spouse surname (marriages 1912+) |
| Spouse/mother given name | **Not used** | Could narrow spouse/mother matches |
| Wildcard on surname (`*`, `?`) | **Not used** | `Cau*well` would find Cauldwell, Caldwell, Cautwell |
| Phonetic/Soundex search | **Not used** | Would find phonetic variants |
| County filter | **Not used** | Narrows the district dropdown to one county |
| Volume/Page direct lookup | **Not used** | Could search by GRO reference directly |
| Age/DOB filter (deaths) | **Not used** | Could narrow death searches by known age |

### 1.4 How to Use Every Piece of Data

**Currently captured — already used well:**

| Field | How the scorer uses it | How the strategiser could use it |
|-------|----------------------|--------------------------------|
| Surname + given name | Name gate (≥0.7 similarity) | — |
| Year | Date gate (±2 tolerance for births, lifespan check for deaths, age check for marriages) | Confirmed birth/death year narrows subsequent search ranges |
| District | Geography gate (is Derbyshire?) | Confirmed district narrows census searches to that area |
| Volume + page | Stored in rawFields for GRO certificate ordering | **Spouse identification**: two marriage entries on the same vol/page are the same couple (pre-1912) |

**Currently captured — underused:**

| Field | Current handling | Proposed improvement |
|-------|-----------------|---------------------|
| Mother's maiden name (births) | Stored as `mothersMaidenName` on `BirthRecord` | **Feed to strategiser**: if the mother's maiden name is found, create a marriage search for that maiden name to find the marriage record. Also cross-reference with census household mother-in-law surname. |
| Spouse surname (marriages) | Stored as `spouseName` on `MarriageRecord` | **Feed to strategiser**: search for the spouse's birth record. Cross-reference with census household to confirm couple. |
| Age at death (deaths) | Extracted via `Int(spouseOrMother)` check | **Feed to scorer**: calculate expected birth year from death year minus age. Compare with known birth year. Currently done in the date gate but the field name is confusing. |

**Not captured — should be:**

| Field | Value | Implementation |
|-------|-------|---------------|
| Date of birth on post-1969 deaths | Gives exact birth date, not just age | Parse the `spouse_or_mother` field: if it matches `DDMMYYYY` pattern (8 digits), treat as DOB instead of age. Extract birth year = last 4 digits. |
| Spouse surname on pre-1912 marriages via page browsing | Identifies the other half of a marriage pair | After finding a marriage result, search for another entry with the same volume and page but a different surname. That's the spouse. `ScoringRules.samePageIsSameCouple()` already exists. |

**Not used — search capabilities to add:**

| Capability | Value | Implementation |
|------------|-------|---------------|
| Wildcard surname search | Finds spelling variants (Cau*well → Cauldwell, Caldwell) | Add `additionalParams["freebmd_wildcard"]` flag. When enabled, prepend/append `*` to surname. |
| Mother's maiden name search (births) | Narrows birth searches when maiden name is known | Add `additionalParams["freebmd_mother_surname"]` field. Sent as `s_surname` in the POST form. Only effective for Sep 1911+ births. |
| Spouse surname search (marriages) | Narrows marriage searches when spouse is known | Add `additionalParams["freebmd_spouse_surname"]` field. Sent as `s_surname` in the POST form. Only effective for Mar 1912+ marriages. |

---

## 2. FreeCen — Census Records

### 2.1 What FreeCen Is

FreeCen is a volunteer transcription of England, Wales, and Scotland census records from 1841 to 1911. Coverage varies dramatically by county and year — 1861 is best at ~70%, while 1901 and 1911 are barely started (<2%).

### 2.2 Record Types

One record type (census) but the available fields change significantly by year:

**Search result fields (all years):**

| Field | Notes |
|-------|-------|
| Surname | |
| Forename(s) | Automatic abbreviation matching (Elizabeth → Eliz, William → Wm) |
| Sex | MALE/FEMALE |
| Age | Rounded to nearest 5 for adults 15+ in 1841; exact from 1851 |
| Census year | 1841–1911 |
| Census county | Chapman code |
| Census place | Registration sub-district or civil parish |

**Household detail fields by census year:**

| Field | 1841 | 1851–1881 | 1891 | 1901 | 1911 |
|-------|------|-----------|------|------|------|
| Surname | Yes | Yes | Yes | Yes | Yes |
| Forenames | Yes | Yes | Yes | Yes | Yes |
| Relationship to head | **No** | Yes | Yes | Yes | Yes |
| Marital status | Informal only | Yes (M/U/W) | Yes | Yes | Yes |
| Sex | Yes | Yes | Yes | Yes | Yes |
| Age | Rounded ≥15 | Exact | Exact | Exact | Exact |
| Occupation | Head only often | All | All | All | All |
| Birth county | Yes (Y/N format) | Yes | Yes | Yes | Yes |
| Birth place (parish) | **No** | Yes | Yes | Yes | Yes |
| Disability | **No** | Blind/Deaf | +Imbecile/Lunatic | Same | Same |
| Language | **No** | **No** | Welsh/Gaelic | Welsh/Gaelic | Welsh/Gaelic |
| Employer/Employee | **No** | **No** | Yes | Yes | Yes |
| Rooms in dwelling | **No** | **No** | <5 rooms only | All | All |
| Marriage duration | **No** | **No** | **No** | **No** | **Yes** |
| Children born alive | **No** | **No** | **No** | **No** | **Yes** |
| Children still living | **No** | **No** | **No** | **No** | **Yes** |
| Children who have died | **No** | **No** | **No** | **No** | **Yes** |

**Dwelling/reference fields (all years):**

| Field | Notes |
|-------|-------|
| Census year | |
| County | With Chapman code |
| District | Registration district |
| Civil parish | |
| Ecclesiastical parish | |
| Piece number | TNA reference |
| Enumeration district | |
| Folio | |
| Page | |
| Schedule | Household schedule number |
| House number | |
| Address/street name | |

### 2.3 Search Parameters

| Parameter | Our usage | Available but unused |
|-----------|-----------|---------------------|
| Surname | Yes | |
| Forename(s) | Yes — from `givenName` | |
| Census year | Yes — from `yearFrom` | |
| Chapman code (county) | Yes — from `additionalParams["freecen_chapman_code"]` | |
| Name Soundex | **Not used** | Phonetic matching, assumes first letter correct |
| Birth year from/to | **Not used** | Would narrow results to plausible birth year range |
| Birth county | **Not used** | Could filter to county of birth |
| Sex filter | **Not used** | Could eliminate wrong-gender matches |
| Census place | **Not used** | Could search specific parish/sub-district |
| Nearby places | **Not used** | Searches closest 100 places, crosses county boundaries |
| Marital status filter | **Not used** | Could filter to married/single/widowed |
| Occupation filter | **Not used** | Free text partial match |
| Disability filter | **Not used** | Records with disability entries |

### 2.4 How to Use Every Piece of Data

**Currently captured — already used well:**

| Field | How used | Value |
|-------|----------|-------|
| Name (surname + forenames) | Name gate scoring | Primary identification |
| Birth year | Date gate (census age tolerance ±2) | Confirms/estimates birth year |
| Birth place | Geography gate, rawFields | Confirms birth location |
| Census year + age | Computed birth year = census year - age | Key date estimation |
| Relationship | Stored on `HouseholdMember` | Identifies family structure |
| Occupation | Stored on `HouseholdMember` | Social context |
| Address + parish | Stored on `CensusRecord` | Locates the family |
| Piece/folio/page | Stored in dwelling rawFields | Reference for original image |
| Household members | Full `[HouseholdMember]` array | Family context gate, household extraction |

**Currently captured — underused:**

| Field | Current handling | Proposed improvement |
|-------|-----------------|---------------------|
| Sex (on household members) | Stored as `sex` string | **Feed to scorer**: verify gender matches subject. If census shows "F" but subject is male, that's a scoring signal. |
| Relationship (on household members) | Stored but only used for family context gate | **Feed to strategiser**: "Head" + "Wife" identifies married couple. Children's relationships confirm family structure. "Mother-in-law" triggers maiden name detection (already in `ScoringRules.maidenNameFromMotherInLaw`). |
| Birth place across census years | Stored per household member | **Feed to strategiser**: if birth place differs between censuses for the same person, flag as a note (census birthplaces are self-reported and vary — per `ScoringRules.censusBirthplaceReliability`). |

**Not captured — should be:**

| Field | Value | Implementation |
|-------|-------|---------------|
| Marital status | Distinguishes married/widowed/single. A person listed as "Widow" in 1881 but "Married" in 1871 confirms spouse died 1871–1881. | Add `maritalStatus: String?` to `HouseholdMember`. Extract from household detail parsing — it's column index 3 (after relationship) for 1851+ censuses. |
| 1911 marriage duration | How long the couple has been married. Combined with census year gives marriage year estimate. | Add `marriageDuration: Int?` to `HouseholdMember` (or to `CensusRecord` as a top-level field since it applies to the couple). Extract from 1911 household detail. **Marriage year = 1911 - duration.** |
| 1911 children born alive | Total children the mother has had, including deceased. | Add `childrenBornAlive: Int?` to `CensusRecord` (1911 only). Reveals family size — if 8 children born but only 4 in census, search for death records for the missing 4. |
| 1911 children surviving | How many are still alive at census date. | Add `childrenSurviving: Int?` to `CensusRecord`. `childrenBornAlive - childrenSurviving` = number of infant/child deaths to search for. |
| Disability | Blind, deaf-and-dumb, imbecile/lunatic. | Add `disability: String?` to `HouseholdMember`. Rarely useful for identification but can confirm matches when present. |
| Language (1891+) | Welsh/Gaelic speaker indicator. | Add `language: String?` to `HouseholdMember`. Minor identification signal for Welsh/Scottish families. |
| Employer/employee status (1891+) | Whether they employ others, are employed, or work on own account. | Add `employmentStatus: String?` to `HouseholdMember`. Social context — "employer" vs "employed" distinguishes a farmer from a farm worker. |

**Not used — search capabilities to add:**

| Capability | Value | Implementation |
|------------|-------|---------------|
| Birth year range filter | Narrow results to plausible birth year ±5 | Add `additionalParams["freecen_birth_year_from"]` and `"freecen_birth_year_to"`. Map to `search_query[start_year]` and `search_query[end_year]`. |
| Sex filter | Eliminate wrong-gender matches before scoring | Add `additionalParams["freecen_sex"]`. Map to `search_query[sex]`. Reduces false positives for common surnames. |
| Soundex search | Find name variants phonetically | Add `additionalParams["freecen_soundex"]` flag. Map to the Soundex checkbox. |
| Nearby places | Search adjacent parishes across county boundaries | Add `additionalParams["freecen_nearby"]` flag. Map to the nearby places checkbox. Useful for families who lived near county borders. |
| Dwelling navigation (next/previous) | Walk through an enumeration book to find neighbours | After fetching household detail, offer "next dwelling" / "previous dwelling" buttons. Requires parsing the navigation links from the detail page. Neighbours often appear as witnesses, employers, or relatives. |

### 2.5 The 1911 Census — Special Handling

The 1911 census is uniquely valuable because it was **self-completed** by the head of household (all previous censuses were filled in by the enumerator from verbal interviews). This means:

- Names are in the person's own handwriting/spelling
- Marriage duration is explicitly stated (not inferred)
- Fertility data (children born/surviving) is explicitly stated
- The data is more reliable for birth places and occupations

**Proposed:** When `censusYear == 1911`, the household detail parser should extract the additional columns (marriage duration, children born, children surviving, children died) and store them on the `CensusRecord`. The strategiser should use marriage duration to estimate marriage year and children counts to suggest infant death searches.

---

## 3. Find a Grave — Burial Memorials

### 3.1 What Find a Grave Is

Find a Grave is the world's largest gravesite collection with 230M+ memorial records, owned by Ancestry. Records are volunteer-contributed. Coverage is strongest for military cemeteries (CWGC, VA) and weakest for small rural churchyards.

### 3.2 Record Fields

**Search API returns (JSON):**

| Field | Notes |
|-------|-------|
| Memorial ID | Unique integer, canonical identifier |
| Name (titleName / fullName) | Display name |
| Birth date | Full date or year only or "unknown" |
| Death date | Full date or year only or "unknown" |
| Cemetery name | |
| Cemetery city/state/country | Separate fields, we join as `burialLocation` |
| Plot | Section/lot/space info (free text) |
| Is veteran | Boolean flag |
| Name for URL | URL-safe slug |

**Memorial detail page adds (HTML scrape):**

| Field | Notes |
|-------|-------|
| Birth place | City/county/state/country via itemprop="birthPlace" |
| Death place | City/county/state/country via itemprop="deathPlace" |
| Cemetery URL | Link to the cemetery's Find a Grave page |
| Biography | Free-form HTML — may contain obituary, CWGC data, family history |
| Inscription | Headstone inscription text — separate from biography |
| Plot | Section/lot info via id="plotValueLabel" |
| Burial location (address-level) | From schema.org addressLocality/addressRegion/addressCountry |
| **Family links — spouse(s)** | Linked memorial IDs with names and dates |
| **Family links — parents** | Father and mother memorial IDs |
| **Family links — children** | Derived from parent links — listed on parent's memorial |
| **Family links — siblings** | Derived from shared parents |
| **Maiden name** | Shown as "nee [name]" or in the name field |
| Photos | Headstone photos, portrait photos, cemetery photos |
| GPS coordinates | Cemetery-level lat/lng |
| Memorial creator/manager | Username and user ID |
| Creation/modification dates | |

### 3.3 Search Parameters

| Parameter | Our usage | Available but unused |
|-----------|-----------|---------------------|
| Surname (lastname) | Yes | |
| First name (firstname) | Yes — from `givenName` | |
| Birth year | Yes — from `birthYear` | |
| Death year | Yes — from `deathYear` | |
| Birth year range filter | Hardcoded to 5 | Could be configurable (exact, 1, 2, 3, 5, 10, 25) |
| Death year range filter | Hardcoded to 5 | Same |
| Location | Passed from `query.location` if set | Could default to RegionConfig.defaultLocation |
| Limit | Hardcoded to 20 | Could increase for broader searches |
| Maiden name search | **Not available** in search params | Must be found in detail page or name field |

### 3.4 How to Use Every Piece of Data

**Currently captured — already used well:**

| Field | How used | Value |
|-------|----------|-------|
| Name | Name gate scoring | Primary identification |
| Birth date / death date | Date gate (year extraction) | Confirms/estimates dates |
| Burial location | Geography gate (contains "Derby"?) | Confirms location |
| Cemetery | Stored on `BurialRecord` | Location context |
| Memorial ID | Used as record ID, detail URL construction | Unique identifier |
| Biography | Stored as `bio` from detail page | May contain family details, obituary data |
| Inscription | Stored as `inscription` | May confirm dates, relationships |
| Veteran flag | Stored as `isVeteran` | Suggests military record searches |

**Not captured — high value:**

| Field | Value | Implementation |
|-------|-------|---------------|
| **Family links — spouse** | Structured relationship: memorial ID + name + dates. Confirms marriage, identifies spouse for further research. | Parse the family links section of the memorial HTML. Look for a `<div>` or section containing "Spouse" with linked memorial IDs. Extract `(memorialID: Int, name: String, birthYear: Int?, deathYear: Int?)` for each. |
| **Family links — parents** | Structured relationship: father + mother memorial IDs. Directly answers "who are the parents?" which is the core ancestor extension question. | Same parsing approach. Look for "Father" and "Mother" sections with linked memorial IDs. If a ghost node's child has a Find a Grave memorial with parent links, the ghost is potentially resolved. |
| **Family links — children** | Listed on parent's memorial. Confirms family structure, reveals children not in our tree. | Parse "Children" section. Cross-reference with known children in `FamilyContext`. Unknown children become leads. |
| **Family links — siblings** | Derived from shared parents. Identifies family members we may not have. | Parse "Siblings" section. Each is a potential lead for tree extension. |
| **Maiden name** | The pre-marriage surname, shown as "nee X" or in the name field. Critical for female ancestor research — the maiden name is what FreeBMD birth records use. | Parse from the name field: look for "(nee|née|born) ([A-Z][a-z]+)" pattern. Also check for "Maiden Name:" in the detail page. Store as `maidenName: String?` on `BurialRecord`. |

**Proposed BurialRecord additions:**

```swift
struct BurialRecord: Codable, Sendable {
    // ... existing fields ...

    // Family links (from detail page)
    let familyLinks: [FamilyLink]?

    // Maiden name (from name field or detail page)
    let maidenName: String?
}

struct FamilyLink: Codable, Sendable {
    let memorialID: Int
    let name: String
    let relationship: FamilyLinkType
    let birthYear: Int?
    let deathYear: Int?
}

enum FamilyLinkType: String, Codable, Sendable {
    case spouse, father, mother, child, sibling
}
```

**How family links flow through the pipeline:**

1. **Search** returns basic burial records (no family links — JSON API doesn't include them)
2. **Detail fetch** for scored results extracts family links from the HTML
3. **Scorer** uses family links in the family context gate: if the memorial's parent links match the subject's known parents, that's a strong corroboration signal
4. **Strategiser** uses family links to:
   - Resolve ghost nodes: "Find a Grave memorial 12345 lists Isaac Land as father — create a profile"
   - Discover unknown relatives: "Memorial lists 3 siblings not in our tree — create leads"
   - Find maiden names: "Memorial shows Mary Smith née Jones — search FreeBMD births for Jones"
5. **Lead creation**: each unmatched family link becomes a lead with category `relationship` or `ancestorExtension`

**How maiden name flows through the pipeline:**

1. Detail fetch extracts maiden name from name field
2. If subject is female and maiden name is found:
   - Strategiser creates a FreeBMD birth search using the maiden name
   - Strategiser creates a FreeBMD marriage search to find the marriage record
   - The maiden name is stored as a confirmed fact if corroborated by another source

---

## 4. Cross-Source Corroboration

The real power comes from combining data across sources. Here's how every piece of data can cross-reference:

### 4.1 Birth Year Confirmation

| Source A | Source B | How they corroborate |
|----------|----------|---------------------|
| FreeBMD birth year | FreeCen census age | Census year - age should equal FreeBMD birth year (±2) |
| FreeBMD birth year | Find a Grave birth date | Years should match |
| FreeCen 1841 age (rounded) | FreeCen 1851 age (exact) | 1851 age - 10 should approximately match 1841 implied birth year |
| FreeBMD death age | FreeBMD birth year | Death year - age should equal birth year (±1) |

### 4.2 Marriage Confirmation

| Source A | Source B | How they corroborate |
|----------|----------|---------------------|
| FreeBMD marriage (vol/page) | FreeBMD marriage (same vol/page, different surname) | Same-page entries are the same couple |
| FreeBMD marriage year | FreeCen 1911 marriage duration | 1911 - duration should equal marriage year (±1) |
| FreeBMD spouse surname (1912+) | FreeCen household (wife's surname) | Should match |
| Find a Grave spouse link | FreeBMD marriage | Spouse name + year should corroborate |

### 4.3 Family Structure Confirmation

| Source A | Source B | How they corroborate |
|----------|----------|---------------------|
| FreeCen household members | Find a Grave family links | Same children/spouse names confirm family |
| FreeCen mother-in-law surname | FreeBMD birth (mother's maiden name) | Mother-in-law's surname = wife's maiden name |
| FreeCen 1911 children born/surviving | FreeBMD birth/death records for children | Number of births/deaths should account for the difference |
| Find a Grave parent links | FreeCen household (relationship = "son of") | Parent names should match |

### 4.4 Death Confirmation

| Source A | Source B | How they corroborate |
|----------|----------|---------------------|
| FreeBMD death year | Find a Grave death date | Years should match |
| FreeBMD death district | Find a Grave cemetery location | Same area |
| FreeBMD death age | FreeCen last census age | Age at death should be census age + years between census and death |
| Absent from census | FreeBMD death between censuses | Person disappearing from census 1871→1881 + FreeBMD death 1875 confirms death |

### 4.5 Proposed: Convergence Scoring Enhancement

When the scorer classifies a record, it should check for corroboration from already-confirmed facts:

```swift
// In RecordScorer, after the 4 gates:
let corroboration = checkCorroboration(record: record, confirmedFacts: state.confirmedFacts)
if corroboration.matchCount >= 2 {
    // Two independent sources agree — boost from lead to fact
    // (only if no gates are "impossible")
}
```

`ScoringRules.convergenceScore()` already exists:
- 1 source: 0.5 (possible)
- 2 sources: 0.75 (probable)  
- 3+ sources: 0.9+ (confirmed)

This should be wired into the verdict logic: a `lead` with 2+ corroborating sources could be promoted to `fact`.

---

## 5. Implementation Priority

| # | Change | Effort | Value |
|---|--------|--------|-------|
| 1 | **Find a Grave family links extraction** | Medium — parse HTML family section | Very high — free structured relationships |
| 2 | **FreeCen marital status extraction** | Low — add one column to household parser | High — distinguishes married/widowed/single |
| 3 | **FreeCen 1911 fertility data** | Low — add columns to 1911 household parser | High — reveals family completeness |
| 4 | **Find a Grave maiden name extraction** | Low — regex on name field | High — unlocks maiden-name birth searches |
| 5 | **FreeBMD wildcard search option** | Low — add additionalParams flag | Medium — finds spelling variants |
| 6 | **FreeBMD mother/spouse surname search** | Low — add additionalParams fields | Medium — narrows searches when names known |
| 7 | **FreeBMD post-1969 DOB extraction** | Low — pattern match on spouse_or_mother field | Medium — exact birth date for modern deaths |
| 8 | **FreeCen birth year range filter** | Low — add additionalParams | Medium — reduces false positives |
| 9 | **FreeCen sex filter** | Low — add additionalParams | Medium — reduces false positives |
| 10 | **Cross-source convergence scoring** | Medium — wire into RecordScorer | High — but depends on pipeline (Phase 5) |
| 11 | **FreeCen dwelling navigation** | Medium — parse nav links, fetch adjacent | Low — nice for manual exploration |
| 12 | **Find a Grave year range configuration** | Low — make hardcoded 5 configurable | Low |

---

## 6. Local AI Model Integration

### 6.1 Context — What We Learned Building the Python Agent

This section draws from seven iterations of building a genealogy research agent (documented in the "Building a Research Agent" blog series) and 29 chapters of The Harness Handbook.

**The critical insight from seven iterations:** Each iteration moved intelligence from the LLM to Python. Date arithmetic, geographic matching, temporal validation, match scoring — all moved to deterministic code. By iteration 7, Python does 95% of the cognitive work. The LLM does the remaining 5%: reasoning about **specific uncertainty** in a lead that no checklist can resolve.

**The Martha Barker Test:** In an 1891 census, Martha Barker is listed as "Mother-in-Law" to the Head (John). Five steps of reasoning are needed to conclude that John's wife Elizabeth's maiden name is Barker. Results:
- Qwen 7B Instruct: only spotted it when directly asked
- Qwen 14B Instruct: got close but never stated the explicit conclusion
- **DeepSeek-R1-Distill-Qwen-14B: nailed all five steps unprompted**

Same parameter count. Same hardware. Completely different result. **Model selection isn't about size — it's about what the model was trained to DO.**

**The Sandwich Architecture** (Deterministic-Probabilistic-Deterministic):
1. **Deterministic in:** Swift searches 8 sources, scores through pass/fail gates, applies coded patterns
2. **Probabilistic middle:** Reasoning model reads the lead, reasons about what to search next. Swift executes the suggestion
3. **Deterministic out:** All evidence re-scored through gates. Facts promoted/dismissed. Human reviews

**The LLM never decides what's a fact** — it only suggests what to search for. Wrong suggestion wastes one search. Wrong fact corrupts data.

### 6.2 Why Model Choice Matters

The user needs to choose the right model for their hardware and their task. This is not a "pick the biggest one" decision.

**Two model families serve different purposes:**

| Type | What it does | Examples | When to use |
|------|-------------|---------|-------------|
| **Instruction models** | Predict the next token. Good at format compliance, following templates, fast responses. | Qwen-Instruct, Llama-Instruct, Mistral-Instruct | Structured data extraction, template filling, simple Q&A |
| **Reasoning models** | Chain through logic steps before answering. Slower but handle multi-step inference. | DeepSeek-R1, QwQ, Qwen-QwQ | Genealogical analysis: "this person in the census is probably the father because..." |

**For the investigator pipeline, a reasoning model is required.** Instruction models cannot reliably perform the multi-step inferences needed (the Martha Barker test proves this). The pipeline's deterministic strategiser handles the instruction-model-level work — the LLM is only called when reasoning is needed.

### 6.3 Hardware Requirements

| Machine | Unified Memory | Models That Fit | Inference Speed (MLX) | Practical Use |
|---------|---------------|-----------------|----------------------|---------------|
| MacBook Air M2 16GB | 16GB | 7B-4bit (~5GB) | ~40 tok/s | Marginal — 7B reasoning models exist but are weak |
| MacBook Air M4 32GB | 32GB | 14B-4bit (~9GB), 7B-8bit | ~40-50 tok/s (7B), ~20 tok/s (14B) | **Sweet spot** — DeepSeek-R1 14B runs well |
| MacBook Pro M3 Max 48GB | 48GB | 14B-8bit, 27B-4bit | ~15-25 tok/s (14B) | Larger quantisation = better reasoning |
| Mac Studio M2 Ultra 192GB | 192GB | 70B-4bit, 32B-8bit | ~5-10 tok/s (70B) | Overkill for this task — 14B reasoning is sufficient |

**The minimum viable configuration is 32GB unified memory with a 14B-4bit reasoning model.** Below 32GB, the model either doesn't fit or the 7B reasoning models are too weak for reliable multi-step inference.

**The recommended model is `mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit`** — this is what the Python agent uses, validated across hundreds of genealogical investigations.

### 6.4 Hugging Face Integration

The app integrates with Hugging Face as the model source. Users browse, select, and download models within the app.

#### 6.4.1 Model Discovery

```swift
/// Fetch available models from Hugging Face Hub filtered for MLX compatibility.
actor HuggingFaceModelBrowser {
    private let http = SourceHTTPClient.shared

    /// Search for models compatible with MLX on Apple Silicon.
    func searchModels(query: String = "", reasoning: Bool = true) async throws -> [HFModelInfo] {
        // Hugging Face API: https://huggingface.co/api/models
        // Filter: library=mlx, pipeline_tag=text-generation
        // Sort: downloads (most popular first)
        var params = [
            "library": "mlx",
            "pipeline_tag": "text-generation",
            "sort": "downloads",
            "direction": "-1",
            "limit": "50",
        ]
        if !query.isEmpty { params["search"] = query }

        let url = URL(string: "https://huggingface.co/api/models?\(params.urlEncoded)")!
        let data = try await http.get(url: url)
        return try JSONDecoder().decode([HFModelInfo].self, from: data)
    }
}

struct HFModelInfo: Codable, Sendable {
    let modelId: String          // e.g., "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit"
    let author: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]?          // includes "mlx", quantisation info
    let pipeline_tag: String?
    let lastModified: String?

    /// Estimated RAM requirement based on model ID patterns.
    var estimatedRAMGB: Int {
        let id = modelId.lowercased()
        if id.contains("70b") { return 40 }
        if id.contains("32b") || id.contains("27b") { return 20 }
        if id.contains("14b") { return 9 }
        if id.contains("8b") || id.contains("7b") { return 5 }
        if id.contains("3b") { return 3 }
        if id.contains("1b") || id.contains("0.5b") { return 1 }
        return 10  // unknown — conservative estimate
    }

    /// Whether this is likely a reasoning model (vs instruction-following).
    var isReasoningModel: Bool {
        let id = modelId.lowercased()
        return id.contains("r1") || id.contains("qwq") || id.contains("reasoning")
            || id.contains("deepseek-r1") || id.contains("think")
    }

    /// Whether this model fits in the current machine's memory.
    var fitsInMemory: Bool {
        let availableGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return estimatedRAMGB < Int(availableGB) - 8  // leave 8GB for OS + app
    }
}
```

#### 6.4.2 Model Download

```swift
/// Download a model from Hugging Face Hub to local storage.
actor HFModelDownloader {
    /// Download progress (0.0–1.0).
    var progress: Double = 0

    /// Download a model's MLX files to the app's model cache directory.
    func download(modelID: String) async throws -> URL {
        // 1. Fetch file list: GET https://huggingface.co/api/models/{modelID}/tree/main
        // 2. Filter to MLX files: *.safetensors, config.json, tokenizer.json, tokenizer_config.json
        // 3. Download each file to: ~/Library/Application Support/Ancestor Research/Models/{modelID}/
        // 4. Update progress as files download
        // 5. Return the local directory URL
        ...
    }

    /// List locally cached models.
    func cachedModels() -> [CachedModel] {
        // Scan ~/Library/Application Support/Ancestor Research/Models/
        // Each subdirectory is a model ID
        ...
    }

    /// Delete a cached model to free disk space.
    func deleteModel(modelID: String) throws { ... }
}

struct CachedModel: Sendable {
    let modelID: String
    let localPath: URL
    let sizeOnDisk: Int64       // bytes
    let downloadedAt: Date
}
```

#### 6.4.3 Model Selector UI

The Settings view includes a model management section that guides the user through selection.

```
┌─────────────────────────────────────────────────────────────┐
│ Local AI Model                                              │
│                                                             │
│ ┌─ How to choose ──────────────────────────────────────┐    │
│ │                                                      │    │
│ │ The investigator uses a local AI model to reason     │    │
│ │ about research leads — suggesting which sources to   │    │
│ │ search and why. The model never decides what's a     │    │
│ │ fact — it only suggests what to look for.             │    │
│ │                                                      │    │
│ │ Choose a REASONING model (DeepSeek-R1, QwQ), not     │    │
│ │ an instruction model (Instruct, Chat). Reasoning     │    │
│ │ models chain through logic steps — essential for     │    │
│ │ genealogical analysis like inferring maiden names    │    │
│ │ from census relationships.                           │    │
│ │                                                      │    │
│ │ Your Mac: 32GB unified memory                        │    │
│ │ Recommended: 14B-4bit reasoning model (~9GB)         │    │
│ │ Maximum: ~20GB model (leaves 12GB for system)        │    │
│ │                                                      │    │
│ └──────────────────────────────────────────────────────┘    │
│                                                             │
│ Current model: DeepSeek-R1-Distill-Qwen-14B-4bit    [Loaded]│
│ RAM usage: ~9GB                                             │
│                                                             │
│ ┌─ Available Models ──────────────────────────────────┐     │
│ │                                                      │    │
│ │ ★ DeepSeek-R1-Distill-Qwen-14B-4bit    9GB  [Cached]│    │
│ │   Reasoning · 14B · 4-bit · Recommended              │    │
│ │                                                      │    │
│ │   DeepSeek-R1-Distill-Qwen-7B-4bit     5GB  [Download]   │
│ │   Reasoning · 7B · 4-bit · Fits your Mac             │    │
│ │                                                      │    │
│ │   QwQ-32B-4bit                         20GB [Download]│   │
│ │   Reasoning · 32B · 4-bit · Fits your Mac            │    │
│ │                                                      │    │
│ │   Llama-3.1-70B-4bit                   40GB [Too large]   │
│ │   Instruction · 70B · 4-bit · Needs 48GB+            │    │
│ │                                                      │    │
│ │ [Browse Hugging Face...]                              │    │
│ └──────────────────────────────────────────────────────┘    │
│                                                             │
│ Without a model, the investigator uses deterministic        │
│ rules only — slower but still functional.                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**UI elements:**

| Element | Purpose |
|---------|---------|
| "How to choose" card | Explains reasoning vs instruction, shows machine RAM, recommends model size |
| Current model status | Shows loaded model, RAM usage, load/unload button |
| Available models list | Cached models first, then downloadable. Each shows: name, size, type badge (Reasoning/Instruction), fit indicator |
| "★ Recommended" badge | On the model matching the Python reference (DeepSeek-R1-Distill-Qwen-14B-4bit) |
| "Fits your Mac" / "Too large" | Based on `fitsInMemory` check |
| Download progress | Progress bar during model download |
| "Browse Hugging Face..." | Opens the model browser with pre-filtered search (MLX + text-generation) |
| Fallback note | "Without a model, the investigator uses deterministic rules only" |

#### 6.4.4 Model Selection Guidance

The "How to choose" card adapts to the user's hardware:

**16GB Mac:**
```
Your Mac has 16GB unified memory.
A 7B-4bit model (~5GB) will fit, but 7B reasoning models
have limited capability for complex genealogical analysis.
Consider upgrading to 32GB for the recommended 14B model.
Without a model, the investigator uses deterministic rules only.
```

**32GB Mac (most common):**
```
Your Mac has 32GB unified memory.
Recommended: 14B-4bit reasoning model (~9GB).
This is the same model used in the proven Python research agent
across hundreds of genealogical investigations.
Maximum model size: ~20GB (leaves 12GB for system + app).
```

**48GB+ Mac:**
```
Your Mac has 48GB unified memory.
Recommended: 14B-8bit reasoning model (~14GB) for higher
accuracy, or 27B-4bit for broader reasoning.
The 14B-4bit model is also proven and uses less RAM.
```

#### 6.4.5 Model Tags and Filtering

The model browser shows badges based on Hugging Face tags:

| Badge | Colour | Meaning | How detected |
|-------|--------|---------|-------------|
| **Reasoning** | Blue | Chain-of-thought reasoning model | Tags contain "r1", "qwq", "reasoning", "think" |
| **Instruction** | Grey | Instruction-following model | Tags contain "instruct", "chat" |
| **Recommended** | Gold star | Matches the proven Python reference model | `modelId == "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit"` |
| **Fits** | Green | Estimated RAM < available - 8GB | `fitsInMemory == true` |
| **Too large** | Red | Estimated RAM > available - 8GB | `fitsInMemory == false` |
| **Cached** | Checkmark | Already downloaded locally | Exists in model cache directory |

### 6.5 MLX Swift Runtime

#### 6.5.1 Model Loading

```swift
/// Local model inference via MLX Swift.
actor LocalInferenceService {
    private var model: (any MLXModel)?
    private var tokenizer: (any MLXTokenizer)?
    private var modelID: String?

    /// Current readiness.
    var readiness: SourceReadiness {
        if model != nil { return .ready }
        let availableGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        if availableGB < 16 {
            return .unavailable(reason: "Requires at least 16GB unified memory (have \(availableGB)GB)")
        }
        return .unavailable(reason: "No model loaded — select one in Settings")
    }

    /// Load a model from local cache.
    func loadModel(from path: URL) async throws {
        // MLX Swift: load safetensors + tokenizer from directory
        // This is the equivalent of Python's mlx_lm.load(MODEL_NAME)
        ...
    }

    /// Unload the current model to free memory.
    func unloadModel() {
        model = nil
        tokenizer = nil
        modelID = nil
    }
}
```

#### 6.5.2 Inference

```swift
extension LocalInferenceService {
    /// Generate a text response from a prompt.
    /// Equivalent to Python's ask() function.
    func ask(systemPrompt: String, userPrompt: String, maxTokens: Int = 2048) async throws -> String? {
        guard let model, let tokenizer else { return nil }

        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt],
        ]

        // Apply chat template (model-specific formatting)
        let formatted = tokenizer.applyChatTemplate(messages, addGenerationPrompt: true)

        // Generate
        let response = try await model.generate(formatted, maxTokens: maxTokens)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generate a JSON response with retry logic.
    /// Equivalent to Python's ask_json() function.
    /// Retries up to 3 times, appending a JSON reminder on failure.
    func askJSON<T: Decodable>(
        systemPrompt: String,
        userPrompt: String,
        type: T.Type,
        maxTokens: Int = 2048,
        retries: Int = 2
    ) async throws -> T? {
        for attempt in 0...retries {
            let prompt = attempt == 0 ? userPrompt :
                userPrompt + "\n\nIMPORTANT: Respond with valid JSON only. No markdown, no explanation, just the JSON object."

            guard let response = try await ask(systemPrompt: systemPrompt, userPrompt: prompt, maxTokens: maxTokens) else {
                return nil
            }

            if let parsed = extractAndDecode(response, as: type) {
                return parsed
            }
        }
        return nil
    }

    /// Extract JSON from a response that may contain markdown fences or extra text.
    /// Ported from Python's _extract_json().
    private func extractAndDecode<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        let decoder = JSONDecoder()

        // 1. Try direct decode
        if let data = text.data(using: .utf8), let result = try? decoder.decode(type, from: data) {
            return result
        }

        // 2. Extract from ```json ... ``` blocks
        if let jsonBlock = extractCodeBlock(from: text, language: "json"),
           let data = jsonBlock.data(using: .utf8),
           let result = try? decoder.decode(type, from: data) {
            return result
        }

        // 3. Extract from ``` ... ``` blocks
        if let codeBlock = extractCodeBlock(from: text, language: nil),
           let data = codeBlock.data(using: .utf8),
           let result = try? decoder.decode(type, from: data) {
            return result
        }

        // 4. Find first { or [ and matching } or ]
        if let jsonSubstring = extractBracketedJSON(from: text),
           let data = jsonSubstring.data(using: .utf8),
           let result = try? decoder.decode(type, from: data) {
            return result
        }

        return nil
    }
}
```

#### 6.5.3 Three-Tier Routing in Swift

The investigator pipeline uses the tiered architecture from the blog:

```swift
/// Route a research question to the appropriate tier.
/// Tier 1 (deterministic) → Tier 2 (local reasoning) → Tier 3 (API, future)
/// Route up only when you hit the wall below.
enum InferenceTier {
    case deterministic      // ScoringRules + ResearchStrategiser. Free, instant, reliable.
    case localReasoning     // MLX model. Free (electricity), ~20s/call. Deep focused reasoning.
    case apiReasoning       // Claude/GPT-4 API. Per-token cost, fast. Future work.
}

extension ResearchPipeline {
    /// Determine which tier to use for strategy suggestions.
    func selectTier(localModel: LocalInferenceService) -> InferenceTier {
        // Tier 2 only if model is loaded and ready
        if case .ready = localModel.readiness {
            return .localReasoning
        }
        // Fall back to deterministic
        return .deterministic
    }
}
```

**The LLM never decides what's a fact.** It only suggests what to search for. The deterministic scorer makes all fact/lead/impossible decisions. This is the sandwich architecture — deterministic bread, probabilistic filling.

### 6.6 Prompt Management

Prompts are bundled as `.txt` resource files, not inline strings. This allows iteration without rebuilding the app.

```
Ancestor Research/
├── Resources/
│   └── Prompts/
│       ├── investigation_system.txt      ← Lead investigation system prompt
│       ├── cluster_system.txt            ← Family cluster investigation prompt
│       ├── strategy_system.txt           ← Strategy suggestion prompt
│       └── ancestor_extension_system.txt ← Finding parents prompt
```

**Loading prompts:**

```swift
extension LocalInferenceService {
    static func loadPrompt(named name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Prompts"),
              let content = try? String(contentsOf: url) else {
            fatalError("Missing prompt resource: \(name).txt")
        }
        return content
    }
}
```

The prompts are ported verbatim from Python — they contain the genealogy-specific reasoning instructions, available source list, parameter formats, and JSON output schema. See INVESTIGATOR_SPEC.md §9 for the prompt content.

### 6.7 What This Spec Does NOT Cover

- **Core ML conversion** — MLX models can be converted to Core ML for Neural Engine acceleration. Future optimisation.
- **Tier 3 (API) integration** — Claude/GPT-4 API for broad reasoning. Future work when local model hits the wall (>50 families, large context).
- **Model fine-tuning** — training a genealogy-specific model. The general reasoning model works well enough.
- **Streaming inference** — showing tokens as they generate. Nice for UX but not needed for the pipeline (which processes the full response).
- **Multiple model slots** — loading different models for different tasks (e.g., 7B for simple extraction, 14B for reasoning). One model at a time is sufficient.

---

## 7. CWGC — Commonwealth War Graves Commission

### 7.1 What CWGC Is

CWGC maintains records of ~1.7 million Commonwealth service members who died during WWI (1914–1918) and WWII (1939–1945). Records cover all Commonwealth nations — UK, Canada, Australia, New Zealand, South Africa, India, and others. Deaths include all causes during service, not just combat.

### 7.2 Record Fields

**CSV Export (19 columns):**

| Column | Extracted by Python? | Notes |
|--------|---------------------|-------|
| Id | Yes (`casualty_id`) | Unique identifier |
| Surname | Yes (combined into `name`) | |
| Forename | Yes (combined into `name`) | |
| Initials | **No** | Middle initials — useful for disambiguation |
| AgeAtDeath | Yes (`age`, 0 → nil) | |
| Honours | **No** | Military decorations (MC, MM, DSO, etc.) |
| DateOfDeath | Yes (`date_of_death`) | DD/MM/YYYY reformatted to readable |
| DateOfDeath2 | **No** | Secondary/approximate death date |
| Rank | Yes (`rank`) | |
| Regiment | Yes (`regiment`, merged with SecondaryRegiment) | |
| SecondaryRegiment | Yes (appended to `regiment`) | |
| Unit | Yes (`unit`, merged with SecondaryUnit) | |
| SecondaryUnit | Yes (appended to `unit`) | |
| CountryOfService | Yes (`country_of_service`) | |
| ServiceNumber | Yes (`service_number`) | |
| Burial | **No** | Burial country — separate from cemetery |
| Cemetery | Yes (`cemetery_memorial`) | Cemetery or memorial name |
| GraveRef | Yes (`grave_ref`) | Plot/row/grave reference |
| AdditionalInfo | Yes (`additional_info`) | Often contains next-of-kin: parents, spouse, hometown |

**Detail Page (HTML scrape) adds:**

| Field | Notes |
|-------|-------|
| Cemetery URL | Link to the cemetery/memorial page |
| Country | Country where buried/commemorated |
| CWGC URL | Permalink to casualty page |
| Certificate URL | Link to PDF certificate |

**Certificate PDF contains:**
- All fields above in formatted layout
- **Next-of-kin information** — e.g., "Son of John and Elizabeth Cauldwell, of Turnditch, Derby; husband of Ellen Cauldwell, of Well Banks, Kirk Ireton, Derby"
- Cemetery photo
- This is the most genealogically valuable data — names parents and spouse with addresses

### 7.3 What We Should Capture

| Field | Current | Proposed |
|-------|---------|----------|
| Initials | Not extracted | Extract — helps distinguish common forename+surname combinations |
| Honours | Not extracted | Extract — military decorations are genealogically significant |
| DateOfDeath2 | Not extracted | Extract — captures approximate dates when exact is unknown |
| Burial country | Not extracted from CSV | Extract — already available from detail page as `country` |
| AdditionalInfo parsing | Stored as raw string | **Parse next-of-kin** — regex for "Son/Daughter of [Name] and [Name], of [Place]" and "husband/wife of [Name], of [Place]". This gives us parent names, spouse name, and addresses. |

### 7.4 How to Use Every Piece of Data

| Data | Pipeline usage |
|------|---------------|
| Name + rank + regiment | Name gate scoring + confirmation of identity |
| Date of death | Date gate — compare with known death year |
| Age at death | Calculate birth year: `deathYear - age`. Cross-reference with FreeBMD birth. |
| Cemetery location | Geography gate — is this person buried where expected? |
| Service number | Unique identifier — confirms it's the same person across records |
| **Additional info (next-of-kin)** | **Highest value** — extract parent names → resolve ghost nodes. Extract spouse name → confirm marriage. Extract hometown → confirm geography. |
| Honours | Store on profile — enrichment data |
| Regiment + unit | Cross-reference with regimental histories. Confirm service location matches death location. |
| Grave reference | Store for future cemetery visit planning |

---

## 8. Probate Calendar — England & Wales

### 8.1 What Probate Is

The Probate Calendar is a government service (probatesearch.service.gov.uk) containing grants of probate and letters of administration for England & Wales. The digital service covers ~1996 onwards plus WWI/WWII soldier wills. Pre-1996 records require physical archive visits.

### 8.2 Record Types

| Type | What it means |
|------|--------------|
| PROBATE | Deceased left a will, executor appointed |
| ADMINISTRATION | No will, administrator appointed by court |
| ADMON/WILL | Will exists but executor unable/unwilling to act |
| Soldier wills | WWI/WWII military personnel — separate collection |

### 8.3 Record Fields

| Nuxeo Property | Python dict key | Notes |
|---------------|----------------|-------|
| `hmctsgrant:surname` | `surname` | |
| `hmctsgrant:firstnames` | `first_names` | |
| `hmctsgrant:dateofdeath` | `death_date` | ISO → YYYY-MM-DD |
| `hmctsgrant:dateofprobate` | `probate_date` | ISO → YYYY-MM-DD |
| `hmctsgrant:dateofbirth` | `birth_date` | ISO → YYYY-MM-DD |
| `hmctsgrant:estateage_atdeath` | `age_at_death` | Integer |
| `hmctsgrant:estateaddressline1-4` | `address` | 4 lines joined |
| `hmctsgrant:estatepostcode` | `postcode` | |
| `hmctsgrant:estatetitle` | `title` | Honorific |
| `hmctsgrant:grantdocTypeoOfName` | `grant_type` | PROBATE/ADMINISTRATION/ADMON/WILL |
| `hmctsgrant:registryofficename` | `registry` | Probate office name |
| `hmctsgrant:probatenumber` | `probate_number` | Grant reference |
| `hmctsgrant:regimentnumber` | `regiment_number` | Soldier wills only |
| Nuxeo `uid` | `document_id` | For ordering copies |

### 8.4 Search Parameters

| Parameter | Used? | Notes |
|-----------|-------|-------|
| Surname | Yes | Uppercased |
| First name | Yes | Uppercased |
| Death date min/max | Yes | From `year_from`/`year_to` |
| Grant type filter | **Not used** | Could filter for soldier wills only |
| Sort by/order | **Not used** | Hardcoded empty |
| Page size | Internal | Max 1000 |

### 8.5 What We Should Capture

| Field | Current | Proposed |
|-------|---------|----------|
| Grant type as search filter | Not used | Add `additionalParams["probate_grant_type"]` — filter for "SOLDIER_WILLS" to find military probate specifically |
| Estate value | Not extracted | Probe API for `hmctsgrant:estatevalue` — may exist in the Nuxeo schema |
| Executor/administrator names | Not extracted | Probe for `hmctsgrant:executor*` — would name family members responsible for the estate |

### 8.6 How to Use Every Piece of Data

| Data | Pipeline usage |
|------|---------------|
| Death date + birth date | Confirms both vital dates. Cross-reference with FreeBMD. |
| Age at death | Calculate birth year if birth date missing. Cross-reference with census age. |
| Address + postcode | Confirms location at time of death. Cross-reference with census address. |
| Grant type | Context — "ADMINISTRATION" means no will, suggests less prosperous or sudden death. |
| Regiment number | Cross-reference with CWGC record for the same person. |
| Probate date vs death date | Gap indicates time to settle estate — may reveal family complications. |

---

## 9. Wirksworth.org.uk — Derbyshire Local History

### 9.1 What Wirksworth Is

A local history website for the Wirksworth area of Derbyshire, containing ~20,000 people in Ince's Pedigrees (1799–1860) and ~104,000 parish register entries (baptisms, marriages, burials from ~1600s to 1800s). This is a Derbyshire-specific resource — highly valuable for this project's primary research area.

### 9.2 Record Types

**Pedigrees (two formats):**

Narrative format (prose):
| Field | Extracted? | Notes |
|-------|-----------|-------|
| Name | Yes | Via regex |
| Birth year | Yes | From "born YYYY" |
| Death year | **No** | Not reliably parsed from narrative |
| Spouse | Yes | From "married [Name]" |
| Marriage year | Yes | From "married [Name] YYYY" |
| Occupation | Yes | Matched against hardcoded list |
| Location | **No** | "of Turnditch" patterns not parsed |
| Parents | **No** | Not parsed from narrative |
| Source text | Yes | Raw matched text (200 chars) |

Structured PRE format (indented):
| Field | Extracted? | Notes |
|-------|-----------|-------|
| Name | Yes | From generation-number + name |
| Birth year | Yes | From `bpt (date)` or `b YYYY` |
| Death year | Yes | From `d YYYY` |
| Baptism date | Yes | Full date string |
| Spouse | Yes | From `m [Name]` |
| Marriage year | Yes | From `m (date)` |
| Generation | Yes | Indentation level |
| Burial date | **No** | `bd` regex exists but result discarded |
| Parents | **No** | Encoded in generation numbering but not extracted |
| Location | **No** | Not parsed |

**Parish Registers (104K entries — UNIMPLEMENTED):**

`search_parish()` is a stub. The data contains:
| Record type | Fields |
|------------|--------|
| Baptisms | Date, child's name, parent names, abode, occupation |
| Marriages | Date, groom name, bride name, witnesses, abode |
| Burials | Date, name, age, abode |

### 9.3 What We Should Capture

| Gap | Value | Implementation |
|-----|-------|---------------|
| **Implement `search_parish()`** | Unlocks 104,000 records — baptisms name parents (ancestor extension), marriages name both parties | Spider register pages or build a surname index. Highest-impact change for this source. |
| Parse parent-child from generation numbers | Structured pedigrees encode parentage via indentation | Generation N+1 under N implies parent-child relationship. Build tree structure. |
| Extract death year from narrative | "died YYYY", "obt YYYY", "buried YYYY" patterns | Add regex patterns to narrative parser |
| Extract burial date | `bd` notation already matched but discarded | Store the captured value |
| Extract locations | "of Turnditch", "of Kirk Ireton" patterns | Regex for "of [Place]" — would enable geography gate scoring |

---

## 10. FreeREG — Parish Registers

### 10.1 What FreeREG Is

A volunteer transcription of parish registers — baptisms (31.9M records), marriages (9.7M), burials (23.6M) — totalling 65.2 million records. Primarily covers pre-civil-registration (before 1837) records, which are the ONLY source for births, marriages, and deaths before the GRO system.

### 10.2 Record Fields by Type

**Baptisms:**
| Field | Notes |
|-------|-------|
| Baptism date | Full date |
| Birth date | Sometimes recorded separately |
| Child's forename and surname | |
| Father's forename | **Names the father — critical for ancestor extension** |
| Mother's forename | **Names the mother** |
| Father's occupation | Sometimes |
| Abode/residence | Where the family lived |
| Parish, county | Where baptised |
| Source register reference | |

**Marriages:**
| Field | Notes |
|-------|-------|
| Marriage date | Full date |
| Groom's name, age, condition | Bachelor/widower |
| Groom's occupation, residence | |
| Bride's name, age, condition | Spinster/widow — **maiden name** |
| Bride's occupation, residence | |
| Groom's father | **Names the groom's father** |
| Bride's father | **Names the bride's father** |
| Witnesses | Often family members |
| Parish, county | |

**Burials:**
| Field | Notes |
|-------|-------|
| Burial date | Full date |
| Name | |
| Age | At time of death |
| Abode/residence | |
| Parish, county | |
| Relationship/notes | Sometimes |

### 10.3 Search Parameters

| Parameter | Used? | Notes |
|-----------|-------|-------|
| Surname | Yes | |
| First name | Yes | |
| Record type | Yes | baptism/marriage/burial/all |
| Start year | Yes | |
| End year | Yes | |
| Chapman codes (county) | Yes | Defaults to `["DBY"]` — should be configurable |
| Fuzzy/Soundex | Yes (parameter exists) | Not exposed in `additionalParams` |
| Place filter | **Not used** | Narrow to specific parish |
| Family members | **Not used** | Extends to relatives/spouses |
| Witnesses | **Not used** | Includes marriage witnesses |
| Nearby places | **Not used** | Searches adjacent parishes |

### 10.4 Current Gaps in Python Code

| Gap | Impact | Notes |
|-----|--------|-------|
| `fetch_record_detail()` prints to stdout | Cannot use results programmatically | Should return structured dict |
| No structured return per record type | All records treated the same | Baptism/marriage/burial have different schemas |
| Hardcoded `["DBY"]` default | Silently limits to Derbyshire | Should use `RegionConfig.chapmanCode` |
| Uses `requests` + `BeautifulSoup` | Different deps from other sources | Swift port uses URLSession uniformly — not an issue |

### 10.5 How to Use Every Piece of Data

| Data | Pipeline usage |
|------|---------------|
| **Baptism — father's name** | **Directly resolves ghost father nodes.** If a baptism record for "Thomas Land" lists father "Isaac Land", the ghost father is identified. This is the single most valuable field for ancestor extension. |
| **Baptism — mother's name** | **Directly resolves ghost mother nodes** (with maiden name if pre-marriage). |
| **Marriage — bride's maiden name** | Unlocks FreeBMD birth search for the wife under her birth surname. |
| **Marriage — fathers of both parties** | Names both sets of parents — one marriage record can resolve up to 4 ghost nodes. |
| **Marriage — witnesses** | Often siblings or close relatives — creates leads for unknown family members. |
| Burial — age | Calculate birth year: `burialYear - age`. Cross-reference with baptism. |
| Abode/residence | Confirms geography. Cross-reference with census address. |
| Parish | Identifies the local church — cross-reference with other parish sources. |

### 10.6 Why FreeREG Matters for Pre-1837 Research

Before 1837 (civil registration start), there are NO FreeBMD records. Parish registers transcribed by FreeREG are the primary source for:
- Birth (via baptism records)
- Marriage
- Death (via burial records)

For any ancestor born before ~1820 (who would have married before 1837), FreeREG baptism records that name parents are the most reliable path to ancestor extension. The strategiser's pattern #11 ("pre-1837 birth → FreeREG search") should be the FIRST search for pre-registration ancestors, not a fallback.

---

## 11. Updated Implementation Priority (All Sources)

| # | Change | Source | Effort | Value |
|---|--------|--------|--------|-------|
| 1 | **Find a Grave family links extraction** | Find a Grave | Medium | Very high |
| 2 | **CWGC additional_info next-of-kin parsing** | CWGC | Medium | Very high — names parents + spouse |
| 3 | **FreeREG structured detail returns** | FreeREG | Medium | Very high — baptisms name parents |
| 4 | **Wirksworth parish register search** | Wirksworth | High | Very high — 104K records unlocked |
| 5 | **FreeCen 1911 fertility data** | FreeCen | Low | High |
| 6 | **FreeCen marital status extraction** | FreeCen | Low | High |
| 7 | **Find a Grave maiden name extraction** | Find a Grave | Low | High |
| 8 | **CWGC honours + initials extraction** | CWGC | Low | Medium |
| 9 | **Probate grant type filter** | Probate | Low | Medium |
| 10 | **FreeBMD wildcard search** | FreeBMD | Low | Medium |
| 11 | **FreeBMD mother/spouse surname search** | FreeBMD | Low | Medium |
| 12 | **Cross-source convergence scoring** | Pipeline | Medium | High |
| 13 | **Local AI model Hugging Face integration** | Infrastructure | High | High — enables Tier 2 reasoning |

---

## 12. Development Approach — Test Outside, Ship Inside

### 12.1 The Problem with Building Inside the App

The first three source integrations (FreeBMD, FreeCen, Find a Grave) were built directly into the app. This works but has costs:

- **Slow feedback loop** — every change requires a full Xcode build (~30s), app launch, navigate to Research tab, type a query, wait for results, check if the parsing worked. A bug in HTML regex? Rebuild, relaunch, re-navigate, re-search.
- **No recursive self-improvement** — Claude Code can't run the app, see the output, and fix issues in a loop. It writes code, you build it, you report back, it fixes. Each iteration costs a conversation turn.
- **No automated validation** — we can't compare Swift output against Python output automatically. We're eyeballing results.
- **Live HTTP calls during development** — every test hits the real source, uses rate-limited goodwill, and may return different results each time.

### 12.2 The Solution — Standalone Swift Test Harness

Build and validate each source integration as a **standalone Swift command-line tool** before bringing it into the app. This gives Claude Code direct access to run the code, see the output, iterate, and self-improve — maximising the creative value of the Opus model.

**The pattern:**

```
1. Create a standalone Swift Package (or script) for each source
2. Port the Python parsing logic to Swift
3. Save canned HTTP responses (HTML/JSON/CSV) from the real source
4. Run the Swift parser against canned data
5. Compare output field-by-field against Python output
6. Claude Code runs, sees mismatches, fixes, re-runs — recursive self-improvement
7. When output matches Python exactly → copy the proven code into the app
```

### 12.3 Directory Structure

```
ancestor/
├── AncestorApp/                    ← App code (existing)
├── Ancestor Research/              ← App source files (existing)
├── SourceTests/                    ← Standalone test harness (NEW)
│   ├── Package.swift               ← Swift Package manifest
│   ├── Sources/
│   │   └── SourceTests/
│   │       ├── main.swift           ← Test runner
│   │       ├── TestFreeBMD.swift    ← FreeBMD parser tests
│   │       ├── TestFreeCen.swift    ← FreeCen parser tests
│   │       ├── TestFindAGrave.swift ← Find a Grave parser tests
│   │       ├── TestCWGC.swift       ← CWGC parser tests
│   │       ├── TestProbate.swift    ← Probate parser tests
│   │       ├── TestWirksworth.swift ← Wirksworth parser tests
│   │       ├── TestFreeREG.swift    ← FreeREG parser tests
│   │       └── TestScorer.swift     ← RecordScorer gate tests
│   ├── Fixtures/                    ← Canned responses from real sources
│   │   ├── freebmd/
│   │   │   ├── births_land_1834.html        ← Real FreeBMD response, saved
│   │   │   ├── deaths_cauldwell_1918.html
│   │   │   └── marriages_brooks_1880.html
│   │   ├── freecen/
│   │   │   ├── search_land_1891.html
│   │   │   └── detail_household.html
│   │   ├── findagrave/
│   │   │   ├── search_cauldwell.json
│   │   │   └── memorial_detail.html
│   │   ├── cwgc/
│   │   │   ├── search_cauldwell.csv
│   │   │   └── casualty_detail.html
│   │   ├── probate/
│   │   │   └── search_smith.json
│   │   ├── wirksworth/
│   │   │   ├── pedigree_index.html
│   │   │   ├── pedigree_caul_1.html
│   │   │   └── pedigree_structured.html
│   │   └── freereg/
│   │       ├── search_results.html
│   │       └── record_detail.html
│   └── Expected/                    ← Python output for comparison
│       ├── freebmd_births_land_1834.json    ← What Python produces
│       ├── freecen_search_land_1891.json
│       └── ...
```

### 12.4 How It Works — Step by Step

**Step 1: Capture canned responses**

Run the Python code against real sources, save both the raw HTTP response AND the parsed output:

```python
# capture_fixtures.py — run once to create test fixtures
from sources import freebmd, freecen, findagrave
import json

# FreeBMD
raw_html = freebmd._get_raw_response("Births", "Land", given="Thomas", start=1832, end=1836)
with open("Fixtures/freebmd/births_land_1834.html", "w") as f:
    f.write(raw_html)

parsed = freebmd._parse_html(raw_html)
with open("Expected/freebmd_births_land_1834.json", "w") as f:
    json.dump(parsed, f, indent=2)
```

This captures the ground truth: the exact HTML the source returns AND the exact output the proven Python parser produces.

**Step 2: Swift Package that parses the same HTML**

```swift
// SourceTests/Sources/SourceTests/TestFreeBMD.swift

import Foundation

func testFreeBMDParser() throws {
    // Load canned HTML
    let html = try String(contentsOfFile: "Fixtures/freebmd/births_land_1834.html")
    
    // Parse with our Swift code (copied from FreeBMDSource.parseSearchResults)
    let results = FreeBMDSource.parseSearchResults(html, recordType: .birth)
    
    // Load expected output from Python
    let expectedData = try Data(contentsOf: URL(fileURLWithPath: "Expected/freebmd_births_land_1834.json"))
    let expected = try JSONSerialization.jsonObject(with: expectedData) as! [[String: Any]]
    
    // Compare field by field
    print("FreeBMD Births — Land, 1832-1836")
    print("  Swift parsed: \(results.count) records")
    print("  Python parsed: \(expected.count) records")
    
    guard results.count == expected.count else {
        print("  ❌ RECORD COUNT MISMATCH")
        print("  Swift records:")
        for r in results { print("    \(r.common.name ?? "?") — \(r.common.rawFields)") }
        print("  Python records:")
        for e in expected { print("    \(e["firstname"] ?? "?") \(e["surname"] ?? "?")") }
        return
    }
    
    var mismatches = 0
    for (i, (swift, python)) in zip(results, expected).enumerated() {
        if case .birth(let birth) = swift {
            let pSurname = python["surname"] as? String ?? ""
            let pFirstname = python["firstname"] as? String ?? ""
            let pYear = python["year"] as? Int
            let pQuarter = python["quarter"] as? String
            let pDistrict = python["district"] as? String ?? ""
            let pVol = python["vol"] as? String ?? ""
            let pPage = python["page"] as? String ?? ""
            
            var match = true
            if birth.common.surname != pSurname { print("    [\(i)] surname: Swift=\(birth.common.surname ?? "nil") Python=\(pSurname)"); match = false }
            if birth.common.givenName != pFirstname { print("    [\(i)] given: Swift=\(birth.common.givenName ?? "nil") Python=\(pFirstname)"); match = false }
            if birth.birthYear != pYear { print("    [\(i)] year: Swift=\(birth.birthYear.map(String.init) ?? "nil") Python=\(pYear.map(String.init) ?? "nil")"); match = false }
            if birth.quarter != pQuarter { print("    [\(i)] quarter: Swift=\(birth.quarter ?? "nil") Python=\(pQuarter ?? "nil")"); match = false }
            if birth.district != pDistrict { print("    [\(i)] district: Swift=\(birth.district ?? "nil") Python=\(pDistrict)"); match = false }
            if birth.volume != pVol { print("    [\(i)] vol: Swift=\(birth.volume ?? "nil") Python=\(pVol)"); match = false }
            if birth.page != pPage { print("    [\(i)] page: Swift=\(birth.page ?? "nil") Python=\(pPage)"); match = false }
            
            if !match { mismatches += 1 }
        }
    }
    
    if mismatches == 0 {
        print("  ✅ All \(results.count) records match Python output exactly")
    } else {
        print("  ❌ \(mismatches)/\(results.count) records have mismatches")
    }
}
```

**Step 3: Claude Code runs, sees output, self-improves**

```bash
$ swift run SourceTests
FreeBMD Births — Land, 1832-1836
  Swift parsed: 3 records
  Python parsed: 3 records
    [1] given: Swift=Thos Python=Thomas
  ❌ 1/3 records have mismatches
```

Claude Code sees the mismatch, identifies the issue (URL decoding of `Thos` vs `Thomas`), fixes the parser, runs again:

```bash
$ swift run SourceTests
FreeBMD Births — Land, 1832-1836
  Swift parsed: 3 records
  Python parsed: 3 records
  ✅ All 3 records match Python output exactly
```

**This loop — run, see output, fix, re-run — is the recursive self-improvement cycle that the Opus model excels at.** Each iteration takes seconds (compile + run), not minutes (Xcode build + app launch + manual navigation).

**Step 4: Once all tests pass, copy proven code into the app**

The parser functions are `static` on each source actor — they have no dependencies on the app. Copy them directly from the test harness into `Services/Sources/FreeBMDSource.swift`. The parsing logic is identical; only the HTTP call wrapper changes (test harness reads files, app makes real HTTP requests).

### 12.5 What Gets Tested This Way

| Test | What it validates |
|------|-------------------|
| **Parser accuracy** | Swift parsing produces identical output to Python for every field |
| **Edge cases** | Canned fixtures include tricky cases: URL-encoded names, missing fields, malformed HTML |
| **Scorer gates** | Score canned records against known subjects — verify fact/lead/impossible matches Python |
| **Cross-source corroboration** | Feed scored results from multiple sources into convergence logic |
| **Name similarity** | Run `ScoringRules.nameSimilarity()` against test pairs: Caldwell/Cauldwell=0.95, Jack/John=0.85, Smith/Jones=0.0 |
| **Date validation** | `ScoringRules.validateRecord()` with known edge cases: pre-birth census, post-death marriage, 111-year-old |
| **Region config** | `RegionConfig.derbyshire.isLocalDistrict("Belper")` = true, `isLocalDistrict("Kensington")` = false |

### 12.6 What Does NOT Get Tested This Way

| Concern | Why not | How to address |
|---------|---------|---------------|
| Live HTTP connectivity | Canned fixtures don't test network | Manual integration test with real sources after parser is proven |
| Session/CSRF token flow | Canned fixtures bypass authentication | Test session management separately with a real HTTP call |
| Rate limiting | No network = no rate limiting to test | Verify timing logic in isolation |
| UI rendering | No SwiftUI in command-line tool | Visual testing after code is integrated into app |
| App state integration | No `AppState`, `SourceRegistry`, etc. | Integration testing after merge |

### 12.7 The Recursive Self-Improvement Loop

This approach maximises Claude Code's strengths:

```
┌─────────────────────────────────────────────────┐
│ 1. Claude writes/modifies parser code           │
│ 2. Claude runs: swift run SourceTests           │
│ 3. Claude reads output — sees mismatches        │
│ 4. Claude diagnoses root cause from output       │
│ 5. Claude fixes the code                         │
│ 6. Claude runs again — sees fewer mismatches     │
│ 7. Loop until ✅ All records match               │
│ 8. Move proven code into the app                 │
└─────────────────────────────────────────────────┘
```

**Why this is better than building inside the app:**

| Factor | Inside App | Standalone Harness |
|--------|-----------|-------------------|
| Build time | ~30s (full Xcode) | ~2s (swift build) |
| Test cycle | Manual (launch app, navigate, search, read) | Automated (run, read stdout) |
| Claude Code can see output | No (app is visual) | Yes (stdout is text) |
| Claude Code can self-improve | No (needs human to report results) | Yes (reads output, fixes, re-runs) |
| Test determinism | Non-deterministic (live HTTP) | Deterministic (canned fixtures) |
| Iterations per minute | ~1 | ~10-20 |
| Python comparison | Manual eyeballing | Automated field-by-field |

### 12.8 Fixture Capture Script

A Python script to capture fixtures from all sources:

```python
#!/usr/bin/env python3
"""Capture test fixtures from live sources for Swift parser testing.
Run once to create Fixtures/ and Expected/ directories.
Uses the existing Python source libraries (proven correct).
"""

import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/..")

from sources import freebmd, freecen, findagrave, cwgc, probate, wirksworth

FIXTURES = "Fixtures"
EXPECTED = "Expected"

def capture(source_dir, filename, raw_data, parsed_data):
    os.makedirs(f"{FIXTURES}/{source_dir}", exist_ok=True)
    os.makedirs(EXPECTED, exist_ok=True)
    
    ext = "json" if isinstance(raw_data, (dict, list)) else "html"
    if isinstance(raw_data, bytes):
        raw_data = raw_data.decode("utf-8", errors="replace")
    if isinstance(raw_data, (dict, list)):
        raw_data = json.dumps(raw_data, indent=2)
    
    with open(f"{FIXTURES}/{source_dir}/{filename}.{ext}", "w") as f:
        f.write(raw_data)
    
    with open(f"{EXPECTED}/{source_dir}_{filename}.json", "w") as f:
        json.dump(parsed_data, f, indent=2, default=str)
    
    print(f"  ✓ {source_dir}/{filename}: {len(parsed_data) if isinstance(parsed_data, list) else 'dict'}")

def main():
    print("Capturing FreeBMD fixtures...")
    # (Implementation: call each source, save raw + parsed)
    
    print("Capturing FreeCen fixtures...")
    print("Capturing Find a Grave fixtures...")
    print("Capturing CWGC fixtures...")
    print("Capturing Probate fixtures...")
    print("Capturing Wirksworth fixtures...")
    print("Capturing FreeREG fixtures...")
    print("\nDone. Run 'swift run SourceTests' to validate Swift parsers.")

if __name__ == "__main__":
    main()
```

### 12.9 When to Use This Approach

| Situation | Approach |
|-----------|----------|
| **New source integration** | Always — test harness first, app second |
| **Fixing a parsing bug** | Capture the failing HTML as a new fixture, fix in harness, then merge |
| **Adding new fields to existing source** | Add the field to expected output, run tests, see failure, implement, verify |
| **Porting Python scorer logic** | Run same test cases through Python and Swift, compare verdicts |
| **Refactoring ScoringRules** | Run all scorer tests, verify no regressions |
| **UI changes** | Not applicable — test in the app directly |
| **Network/session management** | Not applicable — test with real HTTP calls |

---

## 13. Narrative Assembly — From Fragments to Biography

### 13.1 The Problem

Research produces fragments scattered across sources. For one person, the pipeline may find:

| Source | Fragment |
|--------|----------|
| FreeBMD | Birth: Mar 1834, Belper district, vol 7b p.213 |
| FreeCen 1841 | Age 7, son, Wirksworth, father Isaac (43, framework knitter) |
| FreeCen 1851 | Age 17, framework knitter, Wirksworth |
| FreeCen 1861 | Age 27, head, lead miner, married to Hannah (25), 2 children |
| FreeBMD | Marriage: Jun 1858, Belper district |
| CWGC | — (not applicable, too old for WWI) |
| Find a Grave | Buried St Mary's Wirksworth, d. 1902 |
| Probate | — (pre-1996, not in digital system) |
| Wirksworth | Pedigree: Thomas Land, b.1834, m. Hannah Barker 1858, occupation lead miner |
| FreeREG | Baptism: 15 Mar 1834, Thomas son of Isaac Land and Mary, Wirksworth |

Each fragment adds a piece. Together they tell a life story: born 1834, baptised at Wirksworth, grew up in a framework knitting family, became a lead miner, married Hannah Barker in 1858, raised children in Wirksworth, died 1902, buried at St Mary's.

### 13.2 The Narrative Model

The pipeline should assemble these fragments into a structured narrative, not just a bag of facts.

```swift
/// A chronological life narrative assembled from multiple sources.
struct LifeNarrative: Codable, Sendable {
    let profileID: String
    let events: [LifeEvent]
    let occupations: [OccupationRecord]
    let residences: [ResidenceRecord]
    let assembledAt: Date
}

/// A single event in a person's life, with source provenance.
struct LifeEvent: Codable, Sendable {
    let type: LifeEventType
    let date: String?               // original date string from source
    let year: Int?                  // extracted year
    let place: String?
    let description: String         // human-readable narrative sentence
    let sources: [EventSource]      // which sources corroborate this
    let confidence: EventConfidence
}

enum LifeEventType: String, Codable, Sendable {
    case birth, baptism, census, marriage, occupation
    case childBirth      // birth of a child
    case militaryService
    case death, burial, probate
    case residence       // known address at a point in time
}

struct EventSource: Codable, Sendable {
    let sourceID: String            // "freebmd", "freecen", etc.
    let recordID: String            // the SourceRecord.id
    let summary: String             // one-line description
}

enum EventConfidence: String, Codable, Sendable {
    case confirmed      // 2+ sources agree
    case probable       // 1 source, all gates pass
    case estimated      // inferred (e.g., birth year from census age)
}

struct OccupationRecord: Codable, Sendable {
    let occupation: String
    let year: Int?
    let source: String
}

struct ResidenceRecord: Codable, Sendable {
    let address: String
    let parish: String?
    let year: Int?
    let source: String
}
```

### 13.3 Assembly Logic

After the pipeline completes, a `NarrativeAssembler` collects facts chronologically:

```swift
nonisolated struct NarrativeAssembler {
    /// Build a life narrative from scored research results.
    static func assemble(
        subject: ResearchSubject,
        facts: [ScoredRecord],
        snapshot: FamilyGraphSnapshot
    ) -> LifeNarrative {
        var events: [LifeEvent] = []
        var occupations: [OccupationRecord] = []
        var residences: [ResidenceRecord] = []

        for fact in facts where fact.verdict == .fact {
            switch fact.record {
            case .birth(let r):
                events.append(LifeEvent(
                    type: .birth,
                    date: r.birthDate, year: r.birthYear,
                    place: r.district,
                    description: "Born \(r.quarter ?? "") \(r.birthYear.map(String.init) ?? ""), registered \(r.district ?? "")",
                    sources: [EventSource(sourceID: r.common.sourceID, recordID: r.common.id, summary: fact.summary)],
                    confidence: .probable
                ))

            case .census(let r):
                events.append(LifeEvent(
                    type: .census,
                    date: nil, year: r.censusYear,
                    place: r.parish ?? r.address,
                    description: "In \(r.censusYear) census at \(r.address ?? r.parish ?? ""), age \(r.age.map(String.init) ?? "?")",
                    sources: [EventSource(sourceID: r.common.sourceID, recordID: r.common.id, summary: fact.summary)],
                    confidence: .probable
                ))
                if let occ = r.occupation, !occ.isEmpty {
                    occupations.append(OccupationRecord(occupation: occ, year: r.censusYear, source: r.common.sourceID))
                }
                if let addr = r.address, !addr.isEmpty {
                    residences.append(ResidenceRecord(address: addr, parish: r.parish, year: r.censusYear, source: r.common.sourceID))
                }

            case .marriage(let r):
                events.append(LifeEvent(
                    type: .marriage,
                    date: r.marriageDate, year: r.marriageYear,
                    place: r.district,
                    description: "Married \(r.spouseName ?? "") \(r.quarter ?? "") \(r.marriageYear.map(String.init) ?? "")",
                    sources: [EventSource(sourceID: r.common.sourceID, recordID: r.common.id, summary: fact.summary)],
                    confidence: .probable
                ))

            // ... death, burial, military, probate, parish ...
            default: break
            }
        }

        // Sort chronologically
        events.sort { ($0.year ?? 0) < ($1.year ?? 0) }

        // Merge corroborating sources for the same event
        events = mergeCorroboratingEvents(events)

        return LifeNarrative(
            profileID: subject.displayName,
            events: events,
            occupations: occupations.sorted { ($0.year ?? 0) < ($1.year ?? 0) },
            residences: residences.sorted { ($0.year ?? 0) < ($1.year ?? 0) },
            assembledAt: Date()
        )
    }

    /// Merge events of the same type and year from different sources.
    private static func mergeCorroboratingEvents(_ events: [LifeEvent]) -> [LifeEvent] {
        // Group by (type, year), merge sources, upgrade confidence to .confirmed if 2+ sources
        ...
    }
}
```

### 13.4 Biography Generation

The Python `drafter.py` generates MediaWiki-formatted biography text from confirmed facts. The Swift equivalent takes a `LifeNarrative` and produces structured biography text:

```swift
nonisolated struct BiographyDrafter {
    /// Generate biography text from a life narrative.
    static func draft(narrative: LifeNarrative, subject: ResearchSubject) -> String {
        var lines: [String] = []

        // Opening line
        var opening = subject.displayName
        if let birth = narrative.events.first(where: { $0.type == .birth }) {
            opening += " (b.\(birth.year.map(String.init) ?? "?")"
            if let place = birth.place { opening += ", \(place)" }
            if let death = narrative.events.first(where: { $0.type == .death }) {
                opening += "; d.\(death.year.map(String.init) ?? "?")"
                if let place = death.place { opening += ", \(place)" }
            }
            opening += ")"
        }
        lines.append(opening + ".")

        // Chronological events
        for event in narrative.events {
            lines.append("")
            lines.append(event.description + ".")
        }

        // Occupations
        if !narrative.occupations.isEmpty {
            let unique = Set(narrative.occupations.map(\.occupation))
            lines.append("")
            lines.append("Occupation: \(unique.sorted().joined(separator: ", ")).")
        }

        // Source citations
        lines.append("")
        lines.append("Sources:")
        let allSources = narrative.events.flatMap(\.sources)
        for source in Set(allSources.map(\.summary)).sorted() {
            lines.append("- \(source)")
        }

        return lines.joined(separator: "\n")
    }
}
```

### 13.5 Narrative in the UI

The assembled narrative drives two UI features:

1. **Profile timeline** — a chronological card view in the inspector sidebar showing each `LifeEvent` with its sources and confidence level. Each event is a Liquid Glass card with the source badges from the popover pattern.

2. **Draft biography** — a text view showing the generated biography, editable by the user before export to WikiTree. Shows confidence indicators: ✓ confirmed (2+ sources), ~ probable (1 source), ? estimated.

---

## 14. Image Management

### 14.1 Which Sources Return Images

| Source | Image type | What it shows | Format | Access |
|--------|-----------|---------------|--------|--------|
| **Find a Grave** | Headstone photos | Names, dates, inscriptions, military emblems | JPEG/PNG via CDN URLs | Public URL, scrape from memorial page |
| **Find a Grave** | Portrait photos | The person during life | JPEG/PNG | Same |
| **CWGC** | Certificate PDF | Formatted record with all fields + cemetery photo | PDF | Public URL |
| **CWGC** | Cemetery photos | The cemetery/memorial where the person is commemorated | JPEG | Via cemetery page |
| **FamilySearch** | Record images | Original document scans (parish registers, census pages, certificates) | JPEG/TIFF | Requires auth, image viewer |
| **Wirksworth** | Pedigree page scans | Original pedigree book pages | HTML-embedded images | Public |
| **FreeBMD** | None | Index only — no images | — | — |
| **FreeCen** | None | Transcription only — no images | — | — |
| **FreeREG** | None | Transcription only — no images | — | — |
| **Probate** | None (digital grants) | Text data only via API | — | — |

### 14.2 Image Types for Genealogy

| Type | Genealogical value | Priority |
|------|-------------------|----------|
| **Headstone photo** | Confirms dates, names, relationships carved in stone. Often the most reliable primary source. | High |
| **Certificate PDF** | Formatted official record — CWGC certificates name next-of-kin with addresses. | High |
| **Original document scan** | Census page, parish register entry, marriage certificate. Primary source evidence. | High |
| **Portrait photo** | The person themselves — no genealogical data but immense personal value. | Medium |
| **Cemetery photo** | Context — shows where the person is buried. | Low |
| **Pedigree scan** | Historical pedigree book page — may contain handwritten notes. | Low |

### 14.3 Image Storage Architecture

Images are stored locally within the project directory, organised by profile and source.

```
~/Library/Application Support/Ancestor Research/
├── Projects/
│   └── {project-id}/
│       ├── database.sqlite          ← existing
│       └── Images/                  ← NEW
│           ├── {profile-id}/
│           │   ├── headstone_findagrave_12345.jpg
│           │   ├── certificate_cwgc_67890.pdf
│           │   ├── portrait_findagrave_12345_2.jpg
│           │   └── census_1891_freecen_piece123.jpg
│           └── _unlinked/           ← images not yet linked to a profile
│               └── downloaded_findagrave_99999.jpg
```

**Naming convention:** `{type}_{source}_{recordID}.{ext}`

### 14.4 Image Data Model

```swift
/// A research image linked to a profile.
struct ResearchImage: Codable, Identifiable, Sendable {
    let id: UUID
    let profileID: String               // which profile this belongs to
    let sourceID: String                // "findagrave", "cwgc", etc.
    let recordID: String                // source-specific record ID
    let imageType: ResearchImageType
    let filename: String                // local filename in Images/{profileID}/
    let originalURL: String?            // where it was downloaded from
    let caption: String?                // description or alt text
    let downloadedAt: Date
    let fileSize: Int64                 // bytes
}

enum ResearchImageType: String, Codable, Sendable {
    case headstone          // gravestone/memorial marker photo
    case portrait           // photo of the person
    case certificate        // official document (CWGC cert, GRO cert)
    case documentScan       // original record image (census page, register)
    case cemetery           // wider cemetery/memorial view
    case pedigree           // historical pedigree page
}
```

### 14.5 Image Acquisition During Research

Images are discovered and optionally downloaded during the research pipeline.

**Find a Grave:**
When `fetchDetail()` scrapes a memorial page, extract image URLs:

```swift
// In FindAGraveSource.parseMemorialDetail():
// Look for headstone photo: <img id="memPhoto" src="...">
// Look for additional photos in the photo gallery section
// Return URLs in a new field on BurialRecord:

struct BurialRecord: Codable, Sendable {
    // ... existing fields ...
    let imageURLs: [ImageReference]?     // NEW — discovered during detail scrape
}

struct ImageReference: Codable, Sendable {
    let url: String
    let type: ResearchImageType
    let caption: String?
}
```

**CWGC:**
The certificate URL is already available from `fetchDetail()`. Download the PDF on demand:

```swift
// In CWGCSource (when built):
// certificateURL is already extracted
// Download to Images/{profileID}/certificate_cwgc_{casualtyID}.pdf
```

**Image download is deferred, not automatic.** The pipeline discovers image URLs during research but doesn't download them automatically — that would slow the pipeline and use bandwidth. Instead:

1. `ImageReference` URLs are stored on the source record
2. After the user reviews and accepts facts, a "Download images" action becomes available
3. The user can selectively download headstone photos, certificates, etc.
4. Downloaded images are stored in the project's `Images/` directory

### 14.6 Image Display in the App

**Inspector sidebar:** When viewing a profile with images, show a collapsible "Images" section below the biography:

```
┌─ Images (3) ──────────────────────────────┐
│                                           │
│  [Headstone photo]     [Certificate]      │
│  Find a Grave          CWGC               │
│  "St Mary's            "Robert Cauldwell  │
│   Wirksworth"           1st Bn W Yorks"   │
│                                           │
│  [Portrait]                               │
│  Find a Grave                             │
│  "Robert Cauldwell,                       │
│   c. 1910"                                │
│                                           │
│  [Download 2 more available images...]    │
└───────────────────────────────────────────┘
```

**Image viewer:** Clicking an image opens a full-size viewer with:
- Source attribution (where the image came from)
- Original URL link
- Download date
- Caption/description
- Zoom and pan

### 14.7 Image and GEDCOM Export

When exporting to GEDCOM:
- Images are referenced via the GEDCOM `OBJE` (multimedia object) tag
- File paths are relative to the GEDCOM file
- GEDCOM 5.5.1 supports `FILE`, `FORM` (format), and `TITL` (title) tags
- The export creates an `Images/` directory alongside the `.ged` file

### 14.8 Privacy and Copyright

| Source | Image copyright | Usage |
|--------|----------------|-------|
| Find a Grave | Uploaded by volunteers — copyright belongs to photographer | Personal research use. Do not redistribute. |
| CWGC | Crown copyright / CWGC | Personal use permitted. Certificate is official document. |
| FamilySearch | Varies by collection — some restricted | Personal research. Check collection terms. |

**The app should display a copyright notice** on each image showing the source and a "personal research use" reminder. Images should NOT be included in shared project exports without explicit user confirmation.

### 14.9 Storage Considerations

| Concern | Approach |
|---------|----------|
| Disk space | Show total image storage per project in Settings. Allow bulk delete. |
| Large PDFs | CWGC certificates are small (~200KB). Census page scans can be large (~5MB). Show file size before download. |
| Offline access | Downloaded images are local — work without network. |
| Backup | Images are in the project directory — backed up with Time Machine alongside the database. |
| Project deletion | Deleting a project deletes its Images/ directory. Confirm with user. |

---

---

## 16. Research Modes — Per-Profile vs Whole-Tree

### 16.1 Two Modes, Different Purposes

| | Per-Profile Research | Whole-Tree Research |
|---|---------------------|---------------------|
| **Trigger** | User selects a specific person | User launches batch operation |
| **Attention** | Focused — watching results arrive | Background — doing other work |
| **Duration** | 30–60 seconds | Minutes to hours |
| **Review** | Immediate — TreeDiffView for this person | Batch — review queue at user's pace |
| **Scope** | One person, all sources | All incomplete profiles, prioritised |
| **Pipeline iterations** | Up to 4 (full strategy loop) | 1–2 per profile (breadth over depth) |
| **When to use** | "Tell me about this person" | "Fill in everything you can find" |

Both use the same `ResearchPipeline` underneath. The difference is orchestration — who calls the pipeline, how many times, and what happens with the results.

### 16.2 Per-Profile Research

**Launch points:**

| Where | Action | Subject construction |
|-------|--------|---------------------|
| Profile popover → "Research" button | Research this person's gaps | `ResearchSubject.fromProfile()` |
| Gaps view → "Research" button on a profile card | Same | `ResearchSubject.fromProfile()` |
| Ghost node → click (future) | Find the unknown ancestor | `ResearchSubject.forGhostParent()` |
| Source Explorer → "Full pipeline" button | Research from manual input | `ResearchSubject.fromUserInput()` |

**Flow:**

```
User clicks "Research" on Thomas Land
    → ResearchSubject.fromProfile(thomasLand, snapshot)
    → ResearchPipeline.research(subject, snapshot, maxIterations: 4)
    → Live progress view shows searches running, results scoring
    → Pipeline completes
    → Confirmed facts shown in TreeDiffView
    → User accepts/rejects each proposed change
    → Accepted changes flow through MergeEngine → snapshot updates → tree re-renders
    → Leads stored in LeadStore for later investigation
```

**UI: Research Progress View**

```
┌─────────────────────────────────────────────┐
│ Researching: Thomas Land (b. 1834)          │
│                                             │
│ Iteration 1 of 4                            │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 75%           │
│                                             │
│ ┌ FreeBMD ──────────────────────────────┐   │
│ │ ✅ 3 births found, 1 fact, 2 leads    │   │
│ └───────────────────────────────────────┘   │
│ ┌ FreeCen ──────────────────────────────┐   │
│ │ ⏳ Searching 1891 census...           │   │
│ └───────────────────────────────────────┘   │
│ ┌ Find a Grave ─────────────────────────┐   │
│ │ ✅ 1 burial found, 1 fact             │   │
│ └───────────────────────────────────────┘   │
│                                             │
│ Facts: 2    Leads: 2    Rejected: 5         │
│                                             │
│ [Cancel]                          [Review →]│
└─────────────────────────────────────────────┘
```

"Review →" becomes active when the pipeline completes (or the user can review partial results by cancelling early). The progress view shows each source as a card with live status.

### 16.3 Whole-Tree Research

**Launch point:** Research tab → "Research all incomplete profiles" button, or toolbar action.

**Orchestration:**

```swift
/// Batch research across all incomplete profiles in priority order.
actor TreeResearchOrchestrator {
    private let pipeline: ResearchPipeline
    private let snapshot: FamilyGraphSnapshot

    /// Run batch research with configurable limits.
    func researchTree(
        config: TreeResearchConfig
    ) async -> TreeResearchResult
}

struct TreeResearchConfig: Sendable {
    let maxProfiles: Int                    // stop after N profiles (default 50)
    let maxDuration: Duration               // stop after this much time (default 1 hour)
    let iterationsPerProfile: Int           // pipeline depth per profile (default 2 — breadth over depth)
    let priorityOrder: ResearchPriority     // which profiles first
    let stopOnNoNewFacts: Int               // stop after N consecutive profiles with no new facts (default 10)
    let includeGhostParents: Bool           // also research ghost nodes (default false for v1)
}

enum ResearchPriority: Sendable {
    case directAncestorsFirst   // profiles on the direct line from root, then outward
    case leastComplete          // lowest completeness score first
    case mostComplete           // highest first (quick wins — nearly complete profiles)
    case byGeneration           // closest generation first, then further back
}
```

**Priority queue construction:**

```swift
extension TreeResearchOrchestrator {
    /// Build the prioritised list of profiles to research.
    func buildQueue(
        snapshot: FamilyGraphSnapshot,
        rootID: String,
        priority: ResearchPriority
    ) -> [String] {
        let incomplete = snapshot.profiles.values.filter {
            let comp = snapshot.completeness(for: $0.id)
            return comp.score < comp.maximum
        }

        switch priority {
        case .directAncestorsFirst:
            // Direct ancestors of root first, then their siblings, then others
            let ancestors = Set(snapshot.ancestorsOf(rootID, depth: 20).map(\.id))
            let direct = incomplete.filter { ancestors.contains($0.id) }
            let others = incomplete.filter { !ancestors.contains($0.id) }
            // Sort each group by completeness (least complete first)
            let sortedDirect = direct.sorted {
                snapshot.completeness(for: $0.id).score < snapshot.completeness(for: $1.id).score
            }
            let sortedOthers = others.sorted {
                snapshot.completeness(for: $0.id).score < snapshot.completeness(for: $1.id).score
            }
            return (sortedDirect + sortedOthers).map(\.id)

        case .leastComplete:
            return incomplete.sorted {
                snapshot.completeness(for: $0.id).score < snapshot.completeness(for: $1.id).score
            }.map(\.id)

        case .mostComplete:
            return incomplete.sorted {
                snapshot.completeness(for: $0.id).score > snapshot.completeness(for: $1.id).score
            }.map(\.id)

        case .byGeneration:
            // Requires traversal depth from root — computed via BFS
            // Closer generations first
            ...
        }
    }
}
```

**Flow:**

```
User clicks "Research all incomplete profiles"
    → Config sheet: priority, max profiles, time limit
    → User confirms → orchestrator starts
    → Sidebar shows: "Researching... 3/50 profiles · 7 facts found · 12 leads"
    → Orchestrator works through the queue:
        For each profile:
            1. Build ResearchSubject from profile
            2. Run pipeline (2 iterations — breadth not depth)
            3. Store results: facts → review queue, leads → LeadStore
            4. Check stop conditions (time, count, no-new-facts streak)
            5. Check Task.checkCancellation()
    → Orchestrator completes
    → User notified: "Research complete — 47 profiles checked, 23 new facts, 89 leads"
    → Review queue view shows proposed changes grouped by profile
```

### 16.4 Review Queue (Whole-Tree Results)

Per-profile research shows results immediately in TreeDiffView. Whole-tree research produces too many results for immediate review — it needs a queue.

```swift
/// A queue of research findings awaiting user review.
@MainActor @Observable
final class ReviewQueue {
    private(set) var items: [ReviewItem] = []
    var pendingCount: Int { items.filter { $0.status == .pending }.count }
    var acceptedCount: Int { items.filter { $0.status == .accepted }.count }
}

struct ReviewItem: Identifiable, Sendable {
    let id: UUID
    let profileID: String
    let profileName: String
    let updates: [ResearchUpdate]       // proposed changes
    let narrative: LifeNarrative?       // assembled story
    let confidence: EventConfidence     // highest confidence among updates
    let factCount: Int
    let leadCount: Int
    var status: ReviewStatus
}

enum ReviewStatus: Sendable {
    case pending        // not yet reviewed
    case accepted       // user accepted all changes
    case partial        // user accepted some, rejected others
    case rejected       // user rejected all changes
    case skipped        // user will review later
}
```

**Review Queue UI:**

```
┌─────────────────────────────────────────────────────┐
│ Research Results — 23 profiles with findings         │
│                                                     │
│ [Accept All High-Confidence]    [Filter: Pending ▾] │
│                                                     │
│ ┌ Thomas Land ─────────────────────────────── 3 facts│
│ │ ✓✓ Birth: Mar 1834, Belper (FreeBMD + FreeREG)   │
│ │ ✓  Marriage: Jun 1858, Belper (FreeBMD)          │
│ │ ~  Occupation: lead miner (FreeCen 1861)          │
│ │ [Review] [Accept All] [Skip]                      │
│ └───────────────────────────────────────────────────┘
│                                                     │
│ ┌ Isaac Land ──────────────────────────────── 2 facts│
│ │ ✓  Census: 1841, Wirksworth, age 43 (FreeCen)    │
│ │ ~  Occupation: framework knitter (FreeCen 1841)   │
│ │ [Review] [Accept All] [Skip]                      │
│ └───────────────────────────────────────────────────┘
│                                                     │
│ ┌ Hannah Barker ────────────────────────────── 1 fact│
│ │ ?  Burial: St Mary's Wirksworth (Find a Grave)    │
│ │ [Review] [Accept All] [Skip]                      │
│ └───────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────┘

✓✓ = confirmed (2+ sources)  ✓ = probable  ~ = estimated  ? = single source
```

**Actions:**
- **Review** → opens TreeDiffView for that profile's proposed changes
- **Accept All** → applies all updates through MergeEngine (only for high-confidence items)
- **Skip** → moves to end of queue, review later
- **Accept All High-Confidence** (bulk action) → accepts all items where every update has `confidence == .confirmed`

### 16.5 Whole-Tree Guardrails

| Guardrail | Default | Why |
|-----------|---------|-----|
| Max profiles | 50 | Prevents runaway sessions |
| Max duration | 1 hour | Same |
| Iterations per profile | 2 (vs 4 for per-profile) | Breadth over depth — find something for everyone, not everything for one person |
| No-new-facts streak | 10 | If 10 consecutive profiles produce nothing, the remaining are likely unsearchable (too recent, too obscure) |
| Rate limiting | Per-source (existing) + global 1s between profiles | Prevents hammering sources with 50 back-to-back queries |
| Cancellation | User can cancel anytime, partial results preserved | Long-running task must be stoppable |
| Resume | Queue persisted to SQLite, orchestrator state saved | If app quits, resume from last completed profile |

### 16.6 Resume After Interruption

The orchestrator saves its progress so whole-tree research can resume after app quit or crash:

```swift
struct TreeResearchProgress: Codable, Sendable {
    let config: TreeResearchConfig
    let queue: [String]                 // profile IDs in priority order
    let completedIndex: Int             // how far through the queue
    let startedAt: Date
    let factsFound: Int
    let leadsCreated: Int
}
```

Saved to SQLite after each profile completes. On app launch, if a `TreeResearchProgress` exists, offer to resume: "Research was interrupted — 23/50 profiles complete. Resume?"

### 16.7 Background Execution

Whole-tree research runs as a Swift `Task` — it continues while the user navigates other tabs (Tree, Audit, Gaps, Settings). The sidebar shows a persistent progress indicator:

```
┌─ Research ──────────────────┐
│ 🔄 Researching... 12/50     │
│ ━━━━━━━━━━━━━━━━━━━ 24%     │
│ 7 facts · 23 leads          │
│ [Pause] [Cancel]            │
└─────────────────────────────┘
```

**Pause** stops the orchestrator after the current profile completes. Resume continues from the next profile. **Cancel** stops immediately, partial results are preserved in the review queue.

---

---

## 18. Investigator as Auditor — Challenging Existing Data

### 18.1 The Problem

The current pipeline assumes the tree is correct and only fills gaps. But trees imported from WikiTree, GEDCOM, or manual entry often contain:

- **Wrong dates** — transcription errors, confused generations, estimated dates that became "exact" through copying
- **Wrong relationships** — assumed parentage that was never verified, children linked to the wrong father
- **Wrong locations** — parish confused with registration district, US location applied to English ancestor
- **Conflated identities** — two different people with the same name merged into one profile
- **Inherited errors** — one researcher's mistake copied across multiple trees and now treated as fact

When the investigator finds a FreeBMD birth record that says Thomas Land was born in 1836 but the tree says 1834, the current pipeline scores the record through the date gate (±2 tolerance → passes) and adds it as a corroborating fact. But it should also flag: "the source says 1836, the tree says 1834 — which is right?"

### 18.2 Two Modes of Investigation

| Mode | Question | Outcome |
|------|----------|---------|
| **Gap filling** (current) | "What don't we know about this person?" | New facts added to the tree |
| **Fact auditing** (new) | "Is what we already know correct?" | Existing facts confirmed, corrected, or disputed |

Both modes run in the same pipeline. The difference is what happens when the scorer finds a **near-match that disagrees with the tree**.

### 18.3 Discrepancy Detection

When the pipeline scores a record against a subject, it currently checks if the record matches the subject. It should also check if the record **contradicts** the subject.

```swift
/// A discrepancy between a source record and existing profile data.
struct ResearchDiscrepancy: Codable, Sendable {
    let profileID: String
    let field: ProfileField
    let existingValue: String           // what the tree currently says
    let sourceValue: String             // what the source record says
    let sourceID: String                // which source found this
    let recordID: String                // which record
    let severity: DiscrepancySeverity
    let explanation: String             // human-readable description
}

enum DiscrepancySeverity: String, Codable, Sendable {
    case correction     // source is almost certainly right, tree is wrong
    case conflict       // source and tree disagree, unclear which is right
    case refinement     // source adds precision (e.g., "1834" → "15 Mar 1834")
    case note           // interesting difference but not necessarily an error
}
```

**Detection logic — added to `RecordScorer`:**

After the 4 gates run and the record is classified as `fact` or `lead`, compare each field against the existing profile:

```swift
extension RecordScorer {
    /// Check if a scored record contradicts existing profile data.
    static func detectDiscrepancies(
        record: SourceRecord,
        profile: Profile,
        verdict: RecordVerdict
    ) -> [ResearchDiscrepancy] {
        // Only check facts and strong leads — impossible records are irrelevant
        guard verdict != .impossible else { return [] }

        var discrepancies: [ResearchDiscrepancy] = []

        switch record {
        case .birth(let r):
            // Birth year: source says X, profile says Y
            if let sourceYear = r.birthYear, let profileYear = profile.birthDate?.bestYear {
                if sourceYear != profileYear {
                    let severity: DiscrepancySeverity = abs(sourceYear - profileYear) <= 2 ? .refinement : .conflict
                    discrepancies.append(ResearchDiscrepancy(
                        profileID: profile.id,
                        field: .birthDate,
                        existingValue: profile.birthDate?.original ?? "\(profileYear)",
                        sourceValue: r.birthDate ?? "\(sourceYear)",
                        sourceID: r.common.sourceID,
                        recordID: r.common.id,
                        severity: severity,
                        explanation: "FreeBMD birth says \(sourceYear), tree says \(profileYear)"
                    ))
                }
            }
            // Birth location: source district vs profile location
            if let sourceDistrict = r.district, let profileLocation = profile.birthLocation {
                if !profileLocation.lowercased().contains(sourceDistrict.lowercased()) {
                    discrepancies.append(ResearchDiscrepancy(
                        profileID: profile.id,
                        field: .birthLocation,
                        existingValue: profileLocation,
                        sourceValue: sourceDistrict,
                        sourceID: r.common.sourceID,
                        recordID: r.common.id,
                        severity: .conflict,
                        explanation: "FreeBMD says registered in \(sourceDistrict), tree says \(profileLocation)"
                    ))
                }
            }

        case .census(let r):
            // Census-derived birth year vs profile birth year
            if let censusAge = r.age, let profileYear = profile.birthDate?.bestYear {
                let censusBirthYear = r.censusYear - censusAge
                if abs(censusBirthYear - profileYear) > ScoringRules.censusAgeTolerance {
                    discrepancies.append(ResearchDiscrepancy(
                        profileID: profile.id,
                        field: .birthDate,
                        existingValue: "\(profileYear)",
                        sourceValue: "~\(censusBirthYear) (age \(censusAge) in \(r.censusYear) census)",
                        sourceID: r.common.sourceID,
                        recordID: r.common.id,
                        severity: .conflict,
                        explanation: "\(r.censusYear) census age \(censusAge) implies birth ~\(censusBirthYear), tree says \(profileYear)"
                    ))
                }
            }

        case .death(let r):
            if let sourceYear = r.deathYear, let profileYear = profile.deathDate?.bestYear {
                if sourceYear != profileYear {
                    let severity: DiscrepancySeverity = abs(sourceYear - profileYear) <= 1 ? .refinement : .correction
                    discrepancies.append(ResearchDiscrepancy(
                        profileID: profile.id,
                        field: .deathDate,
                        existingValue: profile.deathDate?.original ?? "\(profileYear)",
                        sourceValue: r.deathDate ?? "\(sourceYear)",
                        sourceID: r.common.sourceID,
                        recordID: r.common.id,
                        severity: severity,
                        explanation: "FreeBMD death says \(sourceYear), tree says \(profileYear)"
                    ))
                }
            }

        // ... marriage, burial, etc.
        default: break
        }

        return discrepancies
    }
}
```

### 18.4 Severity Classification

| Severity | What it means | Example | Action |
|----------|--------------|---------|--------|
| **Correction** | Source is almost certainly right, tree is almost certainly wrong | Tree says died 1902, FreeBMD death registration says 1905, age at death matches | Auto-suggest correction in review queue |
| **Conflict** | Genuine disagreement, unclear which is right | Tree says born Belper, census says born Ashbourne | Present both values, user decides |
| **Refinement** | Source adds precision to an existing approximate value | Tree says "1834", FreeBMD says "Mar 1834" — same year, more specific | Auto-suggest upgrade if source is more precise |
| **Note** | Interesting difference but not necessarily wrong | Census birthplace varies between enumerations (Mugginton vs Windley) — common for adjacent parishes | Log in narrative, don't flag as error |

### 18.5 How Discrepancies Flow Through the Pipeline

```
Pipeline scores a record as "fact"
    → detectDiscrepancies() compares against existing profile
    → If discrepancies found:
        → Discrepancies stored on ResearchState
        → In per-profile mode: shown in the progress view with amber indicators
        → In whole-tree mode: added to review queue as a separate section
    → In TreeDiffView:
        → New facts shown as green "Add" rows (existing behaviour)
        → Corrections shown as amber "Change" rows with old → new values
        → Conflicts shown as red "Dispute" rows with both values side by side
        → Refinements shown as blue "Refine" rows
```

### 18.6 Convergence-Based Correction

When multiple independent sources agree on a value that differs from the tree, the confidence in the correction increases:

| Sources agreeing with tree | Sources contradicting tree | Verdict |
|---------------------------|--------------------------|---------|
| 2+ | 0 | Tree is confirmed |
| 1 | 1 | Conflict — user decides |
| 0 | 1 | Possible correction — flag for review |
| 0 | 2+ | Probable correction — strongly suggest change |
| 1 | 2+ | Likely correction — tree value is probably wrong |

```swift
extension ResearchDiscrepancy {
    /// Upgrade severity based on how many sources agree with the correction.
    func withConvergence(
        sourcesAgreeingWithTree: Int,
        sourcesAgreeingWithSource: Int
    ) -> ResearchDiscrepancy {
        var updated = self
        if sourcesAgreeingWithSource >= 2 && sourcesAgreeingWithTree == 0 {
            updated = ResearchDiscrepancy(
                profileID: profileID, field: field,
                existingValue: existingValue, sourceValue: sourceValue,
                sourceID: sourceID, recordID: recordID,
                severity: .correction,
                explanation: explanation + " (\(sourcesAgreeingWithSource) sources agree)"
            )
        }
        return updated
    }
}
```

### 18.7 Audit-Triggered Research

The existing `AuditEngine` flags issues like "birth after death", "parent too young", "lifespan >110 years". These audit results should optionally trigger targeted research:

| Audit rule | Research action |
|-----------|----------------|
| Birth after death | Search FreeBMD for birth AND death — one of the dates is wrong |
| Parent age gap <14 | Search census to verify parent/child relationship — may be wrong link |
| Lifespan >110 | Search FreeBMD death — death year is probably wrong |
| No death date (non-living) | Search FreeBMD deaths + Find a Grave — standard gap filling |
| Missing parents | Search FreeREG baptisms + FreeCen census — ancestor extension |
| Duplicate detection | Search all sources for both candidates — determine if same or different person |

**Proposed:** The Gaps view gets a "Research flagged issues" button that builds a research queue from audit results, prioritised by severity (errors first, then warnings).

```swift
extension ResearchSubject {
    /// Build a research subject from an audit result.
    static func fromAuditResult(
        _ result: AuditResult,
        profile: Profile,
        snapshot: FamilyGraphSnapshot
    ) -> ResearchSubject? {
        // Only some audit rules produce researchable subjects
        switch result.ruleID {
        case "birthBeforeDeath", "lifespan":
            // Research to verify dates
            return .fromProfile(profile, snapshot: snapshot)
        case "missingParents":
            // Ancestor extension — handled by ghost node research
            return nil  // launched from ghost nodes, not audit
        case "parentAgeGap":
            // Verify the relationship — research the alleged parent
            return .fromProfile(profile, snapshot: snapshot)
        default:
            return nil
        }
    }
}
```

### 18.8 Discrepancies in the Review Queue

The review queue (§16.4) adds a discrepancy section:

```
┌ Thomas Land ──────────── 3 facts, 1 correction ┐
│ ✓✓ Birth: Mar 1834, Belper (FreeBMD + FreeREG)  │
│ ✓  Marriage: Jun 1858, Belper (FreeBMD)         │
│ ~  Occupation: lead miner (FreeCen 1861)         │
│                                                  │
│ ⚠ CORRECTION: Birth year                        │
│   Tree says: 1834                                │
│   FreeBMD says: Mar 1836 (vol 7b p.213)          │
│   FreeREG baptism says: 15 Mar 1836              │
│   → 2 sources agree on 1836                      │
│   [Accept correction] [Keep tree value] [Dispute]│
│                                                  │
│ [Review] [Accept All] [Skip]                     │
└──────────────────────────────────────────────────┘
```

**Accept correction** → creates a `ResearchUpdate.updateField` that changes the profile's birth date to the source value, flowing through MergeEngine.

**Keep tree value** → dismisses the discrepancy with a note. The existing value is retained but the source evidence is stored in the research trace so future researchers can see the disagreement.

**Dispute** → creates a `FieldDispute` on the profile (the existing conflict resolution system from DESIGN.md). Both values are preserved with their sources until the user resolves.

### 18.9 What This Changes in the Pipeline

The discrepancy detection is a **post-scoring step**, not a change to the scorer itself:

```
Pipeline iteration:
    1. Search sources (existing)
    2. Score results through 4 gates (existing)
    3. NEW: For each fact/lead, detect discrepancies against existing profile
    4. Strategise next searches (existing)
    5. NEW: If discrepancies found, add targeted verification searches
           (e.g., "FreeBMD says birth 1836 but tree says 1834 — search 
            FreeREG baptisms 1834-1836 to verify")
```

The strategiser gains a new pattern (#13): **"date discrepancy detected → search for corroborating evidence"**. If a discrepancy is found in iteration 1, iteration 2 specifically searches for evidence to resolve it.

---

---

## 20. Current Audit & Gaps System — What Exists Today

### 20.1 Audit Engine

The Swift app has a complete audit system with **18 rules** across three severity levels:

**Error rules (5) — impossible situations, data is wrong:**

| Rule | ID | What it checks |
|------|-----|---------------|
| Birth before death | `birthBeforeDeath` | birth.earliest > death.latest |
| Parent age gap | `parentAgeGap` | parent must be ≥14 years older |
| Marriage age | `marriageAge` | must be ≥16 to marry |
| Lifespan | `lifespan` | no person lives >110 years |
| Marriage after death | `noMarriageAfterDeath` | cannot marry after death |

**Warning rules (7) — suspicious or incomplete:**

| Rule | ID | What it checks |
|------|-----|---------------|
| Missing parents | `missingParents` | no parent edges |
| Missing birth date | `missingBirthDate` | birthDate is nil |
| Missing birth location | `missingBirthLocation` | birthLocation is nil |
| Missing death location | `missingDeathLocation` | has death date but no location |
| Parent died before child | `parentDiedBeforeChild` | parent died before child born (1-year posthumous allowance) |
| Parent suspiciously old | `parentSuspiciouslyOld` | parent >55 years older than child |
| Unsourced bio | `unsourcedBio` | bio >50 chars with no `<ref>` tags or "sources" text |
| Self spouse | `selfSpouse` | person linked as own spouse |
| Duplicate detection | `duplicateDetection` | similarity score ≥0.7 between profiles (40% surname, 30% given, 30% birth year) |

**Info rules (3) — data quality observations:**

| Rule | ID | What it checks |
|------|-----|---------------|
| Missing death date | `missingDeathDate` | deathDate nil AND not potentially living |
| Missing bio | `missingBio` | bio nil or empty |
| Completeness score | `completenessScore` | score < maximum, lists missing fields |
| Ancestor extension | `ancestorExtension` | no parents + birth <1920, suggests source hints |

**Each rule uses range arithmetic** on `GenealogicalDate` (earliest/latest bounds) for the error tier, and `bestYear` midpoints for the warning tier. This prevents false positives from approximate dates.

**Rules are togglable** in Settings — each has a switch. Disabled rule IDs are persisted in `AppStorage`.

### 20.2 Completeness Scoring

Every profile gets a completeness score (0–7 for deceased, 0–6 for living):

| # | Field checked | Missing penalty |
|---|--------------|----------------|
| 1 | firstName | -1 |
| 2 | birthDate | -1 |
| 3 | birthLocation | -1 |
| 4 | deathDate (deceased only) | -1 |
| 5 | deathLocation | -1 |
| 6 | bio | -1 |
| 7 | hasParents (parent edges exist) | -1 |

**Living heuristic:** If no death date AND (latest birth year + 110 ≥ current year), treated as potentially living → maximum is 6 (death date not counted against them). Unbounded birth → assumed potentially living.

**Cache:** Pre-computed at snapshot creation, O(1) lookup via `snapshot.completeness(for: profileID)`.

### 20.3 Gaps View

Displays all incomplete profiles sorted by completeness score (least complete first).

**Filters:**
- Field-specific filter buttons: "All", "Bio", "D.Loc", "Parents", "Death", "B.Loc" — each showing count
- Text search on profile name
- Active filter highlights matching badges on each card

**Per-profile card shows:**
- Severity icon (red if score=0, orange otherwise)
- Profile name + birth year
- Missing fields as inline text: "Missing: d.loc, bio, parents, death"
- Completeness score: "3/7"

**Summary bar:** "X/Y complete, Z%"

### 20.4 How Audit and Gaps Connect to the Investigator

The audit and gaps systems identify WHAT needs researching. The investigator pipeline does the researching. The connection points:

| Audit/Gaps finding | Investigator action |
|-------------------|-------------------|
| Missing birth date | Search FreeBMD births, FreeREG baptisms |
| Missing death date | Search FreeBMD deaths, Find a Grave |
| Missing parents | Ghost node research → FreeREG baptisms (name parents), FreeCen census (reveal household) |
| Missing birth location | Search FreeCen census (shows birthplace) |
| Missing death location | Search Find a Grave (cemetery location), FreeBMD deaths (registration district) |
| Missing bio | Narrative assembly → biography drafter (from confirmed facts) |
| Birth after death (error) | Search both FreeBMD birth AND death — one date is wrong |
| Parent age gap <14 (error) | Search census to verify parent-child relationship |
| Lifespan >110 (error) | Search FreeBMD death — death year is probably wrong |
| Duplicate detection | Search all sources for both candidates — determine if same or different person |
| Ancestor extension | Ghost node research — search FreeREG, FreeCen, FamilySearch for parents |

---

## 21. Python-to-Swift Port Gaps — What's Missing from the Specs

This section documents every significant capability in the Python agent that is NOT yet covered in the Swift specs. These were identified by a line-by-line audit of all 30+ Python files against all three spec documents.

### 21.1 Critical Gaps (would break the pipeline if not ported)

**1. Learned date propagation between iterations**

| Python | `validate.py: update_known_dates()` |
|--------|-------------------------------------|
| What it does | After confirming new facts in iteration 1, updates `state["person"]["birth_year"]` and `state["person"]["death_year"]` for iteration 2+ searches. Validates: death must be after birth, lifespan must be plausible. |
| Why critical | Without this, iteration 2 searches use the original (possibly nil) date ranges. A confirmed birth year from iteration 1 should narrow death searches in iteration 2. This is the mechanism that makes the iterative loop useful. |
| Swift spec status | Not specified. `ResearchState.subject` is a `let` (immutable). |
| Fix | Make `ResearchState.subject` a `var`. After scoring in each iteration, call a `refineDates()` method that updates birth/death years from confirmed facts. Add validation: death must be after birth, lifespan ≤110. |

**2. Unsearchable person detection**

| Python | `pipeline.py: _is_unsearchable()` |
|--------|-------------------------------------|
| What it does | Returns true if birth year > 1930. These people won't be in historical sources. Pipeline skips searching and uses only provided family data and corpus matches. |
| Why critical | Without this, the pipeline will search FreeBMD for someone born in 1970, get results for a different person with the same name, and potentially score them as matches. |
| Swift spec status | Not specified. |
| Fix | Add `isUnsearchable` check at pipeline start. If `subject.birthYear > 1930`, skip source searches, use only `FamilyGraphSnapshot` for family data. |

**3. Location validation for FamilySearch results**

| Python | `rules.py: validate_enrichment_location()` |
|--------|---------------------------------------------|
| What it does | Rejects records from wrong counties. Contains 50+ US state names and abbreviations as non-England markers. Prevents American "John Smith born 1845" from matching an English ancestor. |
| Why critical | FamilySearch returns worldwide results. Without this filter, the #1 source of false matches (American records for English surnames) pollutes results. |
| Swift spec status | `ScoringRules.validateEnrichmentLocation()` exists in the Swift code but is incomplete — it checks English counties but does NOT contain the US state names list from Python. |
| Fix | Port the full `NON_ENGLAND_MARKERS` list (50+ US state names, abbreviations, other countries) to the Swift `ScoringRules.validateEnrichmentLocation()`. |

**4. Parent validation for ancestor extension**

| Python | `rules.py: validate_enrichment_parents()` |
|--------|---------------------------------------------|
| What it does | When a christening record names parents, checks if those parent names match parents already linked in the tree. Rejects if parents mismatch (prevents linking wrong parents). |
| Why critical | Without this, ancestor extension may create relationships with the wrong parents from a christening record for a different child with the same name. |
| Swift spec status | Not in any spec. `ScoringRules` does not have this function. |
| Fix | Port `validate_enrichment_parents()` to `ScoringRules`. Call it during ancestor extension fact extraction when a record names parents. |

**5. Household member extraction algorithm**

| Python | `pipeline.py: _extract_household_members()` |
|--------|----------------------------------------------|
| What it does | From census results, extracts all household members (excluding the subject), computes approximate birth year from census year minus age, deduplicates by uppercase name. Stores: name, relationship, age, birth_year_approx, occupation, birth_place, census_year, address, parish. |
| Why critical | This is the primary mechanism for discovering new family members. Without it, census results are scored but the household members aren't captured for further research. |
| Swift spec status | `ResearchState.householdMembers` exists but the extraction algorithm is not specified. |
| Fix | Add `extractHouseholdMembers(from scoredRecords: [ScoredRecord]) -> [HouseholdMember]` to the pipeline. Port the Python deduplication logic (by uppercase name). |

**6. Birth year inference cascade for leads**

| Python | `investigator.py: _infer_birth_year()` |
|--------|------------------------------------------|
| What it does | 4-level fallback to find a birth year for a lead that doesn't have one: (1) `lead.subject_birth_year`, (2) evidence raw records containing `birth_year`, (3) evidence with `age` + `census_year` → computed birth year, (4) lead summary regex for a 4-digit year, (5) twin profile `BirthDate`. |
| Why critical | Many leads lack birth years. Without inference, the scorer's date gate fails everything (no date to compare against), and all results become "impossible". |
| Swift spec status | Not specified. |
| Fix | Port the 5-level cascade to `LeadInvestigator`. Call before scoring results for a lead. |

**7. Multi-district FreeBMD iteration**

| Python | `discover.py: _search_freebmd_births/deaths/marriages()` |
|--------|-----------------------------------------------------------|
| What it does | Iterates over ALL configured districts from `RegionConfig.districts`, running one FreeBMD search per district. Results from all districts are combined. |
| Why critical | A birth could be registered in any adjacent district. Searching only one district misses registrations in the others. With 7 Derbyshire districts, a single-district search misses ~85% of possible matches. |
| Swift spec status | The spec mentions `additionalParams["freebmd_district"]` for a single district but does not describe the iteration pattern. |
| Fix | The `SearchDispatcher` must iterate all districts from `RegionConfig.districts` for FreeBMD searches, combining results. |

**8. FamilySearch multi-type search pattern**

| Python | `discover.py: _search_familysearch()` |
|--------|----------------------------------------|
| What it does | Runs 5 separate FamilySearch searches per person: (1) births in county, (2) deaths in county, (3) marriages in county, (4) census per applicable year, (5) broad sweep with birth place + year range. Deduplicates by ARK identifier. |
| Why critical | FamilySearch is the richest source. A single generic search returns whatever FamilySearch ranks highest — usually census records. The 5-subquery pattern ensures births, deaths, marriages, and census are all searched explicitly. |
| Swift spec status | Not specified at this level of detail. |
| Fix | The `SearchDispatcher` must generate 5 queries for FamilySearch per person, with source-specific parameters for each sub-type. Deduplicate combined results by `ark` field. |

**9. Ancestor extension parent extraction from evidence**

| Python | `investigator.py: _extract_facts()` lines 1095-1143 |
|--------|------------------------------------------------------|
| What it does | For `ancestor_extension` leads, scans evidence household data for parent relationships. Extracts parent name and birth year. Creates facts of type `add_parent` with the parent's details and the child's WikiTree ID. |
| Why critical | This is how ghost nodes get resolved. The investigator finds a census or baptism record with a parent name, and this code turns that into a concrete "add this person as parent" action. |
| Swift spec status | The spec describes `ResearchUpdate.createProfile` and `ResearchUpdate.createRelationship` but doesn't describe the specific extraction algorithm that produces them from evidence. |
| Fix | Port the parent extraction logic to `LeadInvestigator._extractFacts()`. When category is `ancestorExtension`, scan evidence for household members with relationship containing "head", "father", "mother". Create `ResearchUpdate.createProfile` + `ResearchUpdate.createRelationship`. |

**10. Household-to-lead conversion with type distinction**

| Python | `integrate.py: create_leads_from_candidates()` + household conversion |
|--------|-----------------------------------------------------------------------|
| What it does | Creates two types of leads from discovered household members: (1) **Relationship leads** — person exists in the tree, verify the link is correct. (2) **Identity leads** — person is unknown, investigate who they are. Each type gets different `next_actions`. |
| Why critical | Without the type distinction, all household discoveries are treated the same. Relationship leads need link verification. Identity leads need source searches. Different investigation strategies. |
| Swift spec status | `Lead.category` includes `.relationship` and `.identity` but the conversion algorithm and next-action generation are not specified. |
| Fix | Port `create_leads_from_candidates()` and `_suggest_actions()` to the pipeline. Include the category-specific next-action generation (GRO certificate for birth/death, spouse search for marriage, adjacent census years). |

### 21.2 Important Gaps (should be ported for correctness)

**11. Corpus pre-enrichment at pipeline start**

| Python | `pipeline.py` lines 38-66 |
|--------|--------------------------|
| What it does | Before searching, looks up the subject in the corpus (FamilyGraphSnapshot). If found, pre-populates birth/death years, birth location, and family context from existing profile data. |
| Fix | At pipeline start, call `snapshot.profiles.values.first(where: { nameSimilarity >= 0.7 })`. If found, enrich `ResearchSubject` with profile data before searching. |

**12. Census household auto-enrichment**

| Python | `discover.py: _search_census_year()` lines 67-76 |
|--------|---------------------------------------------------|
| What it does | After getting census search results, automatically fetches full household detail for the top 5 matches via `freecen.detail()`. |
| Fix | After `FreeCenSource.search()`, the dispatcher should call `fetchDetail()` for top N scored results. Store household data on the `CensusRecord`. |

**13. Gender guessing from census relationship**

| Python | `research_agent.py: _guess_gender()` |
|--------|---------------------------------------|
| What it does | Maps census relationship strings to gender: head/son/brother/nephew/grandson/uncle/father → male. wife/daughter/sister/niece/granddaughter/aunt/mother → female. |
| Fix | Add `guessGender(from relationship: String) -> Gender?` to `ScoringRules`. Used when constructing `ResearchSubject` from household members who lack explicit gender. |

**14. Military death not in civil register**

| Python | `rules.py: military_death_not_in_civil_register()` |
|--------|-----------------------------------------------------|
| What it does | Checks if death location contains abroad keywords (France, Belgium, Flanders, Gallipoli, etc.). If so, the death won't appear in FreeBMD — need CWGC instead. |
| Fix | Port to `ScoringRules`. The strategiser should skip FreeBMD death search and prioritise CWGC when the person is military-eligible and death location is abroad. |

**15. Source availability check by birth year**

| Python | `rules.py: source_available()` |
|--------|--------------------------------|
| What it does | Checks if a source is relevant for a person's era: FreeBMD not available before 1837, CWGC only for military-age males, parish registers always available. |
| Fix | Port to `ScoringRules` or the `SearchDispatcher`. Skip sources that can't have records for this person's era. Prevents wasted searches. |

**16. Common surnames penalty list**

| Python | `leads.py: COMMON_SURNAMES` |
|--------|------------------------------|
| What it does | 25 common English surnames (Smith, Jones, Williams, Taylor, Brown, etc.) that get a -3 priority penalty on leads because matches are less reliable. |
| Fix | Add the surname list to `ScoringRules` or `Lead.computePriority()`. |

**17. FamilySearch father/mother search parameters**

| Python | `familysearch.py: search()` |
|--------|------------------------------|
| What it does | FamilySearch API accepts `father_surname`, `father_given`, `mother_surname`, `mother_given` as search parameters. When parent names are known, these dramatically narrow results. |
| Fix | Add these as `additionalParams` keys for FamilySearch queries. The dispatcher populates them from `FamilyContext.knownParents` when available. |

**18. LLM context rendering**

| Python | `render.py: render_narrative()` |
|--------|-------------------------------|
| What it does | Builds compact text for LLM context: confirmed facts, rejected records, household members, searched sources, open objectives. Limits evidence to last 15 items to fit in 14B model's context window. |
| Fix | Port `render_narrative()` to Swift. This is the bridge between `ResearchState` and `LocalInferenceService.ask()`. Without it, the LLM sees raw data structures instead of readable context. |

**19. Result pre-annotation for LLM**

| Python | `render.py: _annotate_result()` |
|--------|-------------------------------|
| What it does | Pre-computes date and geographic annotations on results before the LLM sees them: "POSSIBLE MATCH (birth year matches within 2)", "LIKELY DIFFERENT (from Lancashire, not Derbyshire)", "IMPOSSIBLE (born 30 years before expected)". |
| Fix | Port the annotation logic. The LLM should validate pre-computed verdicts rather than computing date arithmetic itself. This is the "deterministic bread" in the sandwich architecture. |

**20. Lead dedup merge-on-duplicate**

| Python | `leads.py: LeadStore.add()` |
|--------|------------------------------|
| What it does | When adding a lead with a `lead_id` that already exists, appends evidence to the existing lead instead of creating a duplicate. Updates priority after merge. |
| Fix | `LeadStore.add()` should check `leadKey` for duplicates. If found, merge evidence and recompute priority instead of inserting a new lead. |

**21. Check findings against existing leads**

| Python | `leads.py: check_findings_against_leads()` |
|--------|---------------------------------------------|
| What it does | After confirming new facts, checks if any open leads are resolved by the new facts and promotes them. |
| Fix | After the pipeline confirms facts, iterate open leads and check if any are now resolvable. Auto-promote leads whose uncertainty is eliminated by the new facts. |

**22. Investigation max iterations default**

| Python | `config.py: INVESTIGATION_MAX_ITERATIONS = 3` |
|--------|-----------------------------------------------|
| What it does | Lead investigation loop runs up to 3 iterations (different from the pipeline's 4). |
| Fix | Ensure `LeadInvestigator` uses 3 as its default, not 4. |

---

## 22. Updated Implementation Priority (All Items)

| # | Change | Category | Effort | Value |
|---|--------|----------|--------|-------|
| 1 | **Standalone test harness** | Infrastructure | Medium | Very high |
| 2 | **Learned date propagation (gap #1)** | Pipeline | Low | Very high |
| 3 | **Unsearchable person detection (gap #2)** | Pipeline | Low | Very high |
| 4 | **Location validation with US states (gap #3)** | ScoringRules | Low | Very high |
| 5 | **Parent validation for ancestor extension (gap #4)** | ScoringRules | Low | Very high |
| 6 | **Household extraction algorithm (gap #5)** | Pipeline | Medium | Very high |
| 7 | **Multi-district FreeBMD iteration (gap #7)** | Dispatcher | Medium | Very high |
| 8 | **Find a Grave family links extraction** | Source | Medium | Very high |
| 9 | **CWGC additional_info next-of-kin parsing** | Source | Medium | Very high |
| 10 | **FreeREG structured detail returns** | Source | Medium | Very high |
| 11 | **Per-profile research flow** | Pipeline + UI | Medium | Very high |
| 12 | **Discrepancy detection (§18)** | Pipeline | Medium | Very high |
| 13 | **Birth year inference cascade (gap #6)** | Investigator | Medium | High |
| 14 | **FamilySearch multi-type search (gap #8)** | Dispatcher | Medium | High |
| 15 | **Ancestor extension parent extraction (gap #9)** | Investigator | Medium | High |
| 16 | **Household-to-lead conversion (gap #10)** | Pipeline | Medium | High |
| 17 | **Narrative assembly** | Pipeline | Medium | High |
| 18 | **FreeCen 1911 fertility data** | Source | Low | High |
| 19 | **Cross-source convergence scoring** | Pipeline | Medium | High |
| 20 | **Local AI model Hugging Face integration** | Infrastructure | High | High |
| 21 | **Whole-tree research orchestrator (§16)** | Pipeline | High | High |
| 22 | **Review queue UI** | UI | Medium | High |
| 23 | **Audit-triggered research (§18.7)** | Pipeline | Medium | High |
| 24 | **Wirksworth parish register search** | Source | High | High |
| 25 | **Image storage + download** | Infrastructure | Medium | Medium |
| 26 | **LLM context rendering (gap #18)** | Investigator | Medium | Medium |
| 27 | **Biography drafter** | Pipeline | Low | Medium |
| 28 | **FreeBMD wildcard/phonetic search** | Source | Low | Medium |
| 29 | **Resume after interruption** | Infrastructure | Medium | Medium |

| # | Change | Category | Effort | Value |
|---|--------|----------|--------|-------|
| 1 | **Standalone test harness** | Infrastructure | Medium | Very high |
| 2 | **Find a Grave family links extraction** | Source | Medium | Very high |
| 3 | **CWGC additional_info next-of-kin parsing** | Source | Medium | Very high |
| 4 | **FreeREG structured detail returns** | Source | Medium | Very high |
| 5 | **Wirksworth parish register search** | Source | High | Very high |
| 6 | **Per-profile research flow (progress view + TreeDiffView)** | Pipeline | Medium | Very high |
| 7 | **Discrepancy detection (post-scoring)** | Pipeline | Medium | Very high |
| 8 | **Narrative assembly from research facts** | Pipeline | Medium | High |
| 9 | **FreeCen 1911 fertility data** | Source | Low | High |
| 10 | **FreeCen marital status extraction** | Source | Low | High |
| 11 | **Find a Grave maiden name + image URLs** | Source | Low | High |
| 12 | **Image storage + download infrastructure** | Infrastructure | Medium | High |
| 13 | **Biography drafter (port from Python)** | Pipeline | Low | Medium |
| 14 | **Cross-source convergence scoring** | Pipeline | Medium | High |
| 15 | **Local AI model Hugging Face integration** | Infrastructure | High | High |
| 16 | **Whole-tree research orchestrator** | Pipeline | High | High |
| 17 | **Review queue UI** | UI | Medium | High |
| 18 | **Audit-triggered research** | Pipeline | Medium | High |
| 19 | **CWGC certificate PDF download** | Source | Low | Medium |
| 20 | **FreeBMD wildcard/phonetic search** | Source | Low | Medium |
| 21 | **Resume after interruption** | Infrastructure | Medium | Medium |

| # | Change | Category | Effort | Value |
|---|--------|----------|--------|-------|
| 1 | **Standalone test harness** | Infrastructure | Medium | Very high |
| 2 | **Find a Grave family links extraction** | Source | Medium | Very high |
| 3 | **CWGC additional_info next-of-kin parsing** | Source | Medium | Very high |
| 4 | **FreeREG structured detail returns** | Source | Medium | Very high |
| 5 | **Wirksworth parish register search** | Source | High | Very high |
| 6 | **Per-profile research flow (progress view + TreeDiffView)** | Pipeline | Medium | Very high |
| 7 | **Narrative assembly from research facts** | Pipeline | Medium | High |
| 8 | **FreeCen 1911 fertility data** | Source | Low | High |
| 9 | **FreeCen marital status extraction** | Source | Low | High |
| 10 | **Find a Grave maiden name + image URLs** | Source | Low | High |
| 11 | **Image storage + download infrastructure** | Infrastructure | Medium | High |
| 12 | **Biography drafter (port from Python)** | Pipeline | Low | Medium |
| 13 | **Cross-source convergence scoring** | Pipeline | Medium | High |
| 14 | **Local AI model Hugging Face integration** | Infrastructure | High | High |
| 15 | **Whole-tree research orchestrator** | Pipeline | High | High |
| 16 | **Review queue UI** | UI | Medium | High |
| 17 | **CWGC certificate PDF download** | Source | Low | Medium |
| 18 | **FreeBMD wildcard/phonetic search** | Source | Low | Medium |
| 19 | **Resume after interruption** | Infrastructure | Medium | Medium |

| # | Change | Source | Effort | Value |
|---|--------|--------|--------|-------|
| 1 | **Standalone test harness** | Infrastructure | Medium | Very high — enables all subsequent work |
| 2 | **Find a Grave family links extraction** | Find a Grave | Medium | Very high |
| 3 | **CWGC additional_info next-of-kin parsing** | CWGC | Medium | Very high |
| 4 | **FreeREG structured detail returns** | FreeREG | Medium | Very high |
| 5 | **Wirksworth parish register search** | Wirksworth | High | Very high |
| 6 | **Narrative assembly from research facts** | Pipeline | Medium | High |
| 7 | **FreeCen 1911 fertility data** | FreeCen | Low | High |
| 8 | **FreeCen marital status extraction** | FreeCen | Low | High |
| 9 | **Find a Grave maiden name + image URLs** | Find a Grave | Low | High |
| 10 | **Image storage + download infrastructure** | Infrastructure | Medium | High |
| 11 | **Biography drafter (port from Python)** | Pipeline | Low | Medium |
| 12 | **Cross-source convergence scoring** | Pipeline | Medium | High |
| 13 | **Local AI model Hugging Face integration** | Infrastructure | High | High |
| 14 | **CWGC certificate PDF download** | CWGC | Low | Medium |
| 15 | **FreeBMD wildcard/phonetic search** | FreeBMD | Low | Medium |

The first three sources (FreeBMD, FreeCen, Find a Grave) were built without this approach. Before building more sources, we should:

1. Capture fixtures from real sources using the Python code
2. Create the test harness
3. Run the existing Swift parsers against the fixtures
4. Fix any mismatches found
5. Then proceed with new sources using the harness-first approach

This validates the existing code AND establishes the pattern for all future sources.
