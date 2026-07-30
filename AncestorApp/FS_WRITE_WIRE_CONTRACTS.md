# FamilySearch User Trees Write API — Wire Contracts (verbatim extracts)

Extracted 2026-07-30 from developers.familysearch.org (live docs) and www.familysearch.org/developers classic use-case pages.
Base hosts seen in docs: reference pages show `https://apibeta.familysearch.org` (Beta); example `Location:` headers show `https://api.familysearch.org` (production). Paths below are host-relative.

Auth on every call: `Authorization: Bearer YOUR_ACCESS_TOKEN_HERE`.

---

## 1. Create Group

Source: https://developers.familysearch.org/main/docs/create-group.md (example) + https://developers.familysearch.org/main/docs/creategroup (reference)

- Method: `POST`
- Path: `/platform/groups`
- Content-Type: `application/x-fs-v1+json`

Verbatim request body (docs' formatting preserved, including odd indentation):

```json
{
  "groups" : [ {
  "name" : "Good Ship Zion Immigrant Society",
  "description" : "Trees for those who immigrated on the various Good Ship Zion voyages",
  "codeOfConduct" : "Please be respectful of others and their work",
  "treeIds" : null
  } ]
  }
```

Response: `201 Created`
- `X-entity-id: 9MMN-C68`
- `Location: https://api.familysearch.org/platform/groups/9MMN-C68`
- `X-processing-time: 217`

Reference-page notes: required = `groups` array (exactly 1 element) with `name`. `groupId` and `treeIds` fields are ignored during creation. Error: `429` "The request was throttled."

Group management URL template (for users): `https://{domain}/service/tree/page-links/groups/{group-id}/details`

---

## 2. Create User Tree

Source: https://developers.familysearch.org/main/docs/create-user-tree (example) + https://developers.familysearch.org/main/docs/createtree (reference)

- Method: `POST`
- Path: `/platform/trees`
- Content-Type: `application/x-fs-v1+json`

Verbatim request body:

```json
{
  "trees": [
    {
      "groupIds": [
        "9M9H-2G7"
      ],
      "name": "The Good Ship Zion, Voyage #1",
      "description": "The passengers and descendants of those who migrated on the Good Ship Zion, Voyage #1",
      "ownerAccess": "CompanyApps",
      "groupAccess": "None"
    }
  ]
}
```

Response: `201 Created`
- `X-entity-id: 9NMM-9D6C`
- `Location: https://api.familysearch.org/platform/trees/9NMM-9D6C`

Reference-page field table (createtree):

| Field | Required | Notes |
|---|---|---|
| `name` | Yes | Tree name (not displayed on FamilySearch website) |
| `description` | No | Not displayed on FamilySearch website |
| `groupIds` | Yes | array, length exactly 1 (the group from step 1) |
| `ownerAccess` | No | Default: `http://familysearch.org/v1/CompanyApp` |
| `groupAccess` | No | Default: `http://familysearch.org/v1/None` |
| `allAccess` | No | Defaults to `groupAccess` if not provided |

Enum values per reference page: `http://familysearch.org/v1/AnyApps`, `http://familysearch.org/v1/CompanyApp`, `http://familysearch.org/v1/None`.
NOTE INCONSISTENCY: the tutorial example uses bare `"CompanyApps"` / `"None"`; the reference uses full URIs with singular `CompanyApp`; the update example uses URI with plural `CompanyApps`. Unresolved — probe live.

`hidden`, `private`, `startingPersonId` are NOT accepted at creation (not listed on createtree); trees are created `hidden=true`, `private=true` by default.

Errors: `429` throttled.

---

## 3. Read Current Tree

Source: https://developers.familysearch.org/main/docs/current-tree-selection (+ read-current-tree.md)

- Method: `GET`
- Path: `/platform/trees/current`
- Accept: `application/json`

Response: `200 OK`, verbatim body:

```json
{
  "trees": [{
    "id": "9NMM-9SQB"
  }]
}
```

---

## 4. Set Current Tree

Source: https://developers.familysearch.org/main/docs/current-tree-selection + https://developers.familysearch.org/main/docs/setcurrenttree

- Method: `POST`
- Path: `/platform/trees/current`
- Content-Type: `application/x-fs-v1+json`
- Accept: `*/*`

Verbatim request body (to switch back to the public Family Tree):

```json
{
  "trees": [{
    "id": "GLOBAL"
  }]
}
```

To target a user tree, put the user tree ID (from Create Tree `X-entity-id`, or Read User's Groups) in place of `"GLOBAL"`.

Response: `204 No Content`. Errors: `429` throttled.

- The global/public Family Tree identifier is the literal string `GLOBAL`.
- This sets the tree context for subsequent API calls in the session. **No per-call tree override parameter (query param or header) is documented anywhere** — current-tree selection is the only documented targeting mechanism for person creation.

---

## 5. Create Person

Source: https://developers.familysearch.org/main/docs/create-person.md + https://developers.familysearch.org/main/docs/createperson (reference) + classic https://www.familysearch.org/developers/docs/api/tree/Create_Person_usecase

- Method: `POST`
- Path: `/platform/tree/persons`
- Content-Type: `application/x-fs-v1+json` (or `application/x-fs-v1+xml`)
- Optional header: `X-Reason: <reason for creating the person>`
- No query/path parameters. No tree-ID parameter — targeting a user tree happens ONLY via prior Set Current Tree. (Comparison doc footnote: "Creating a person in user tree space requires a Tree ID" — satisfied by the current-tree context.)
- "Do not include id fields when creating a new person."

Verbatim request body (create-person.md variant):

```json
{
  "persons" : [ {
    "living" : false,
    "gender" : {
      "attribution" : {
        "changeMessage" : "...change message..."
      },
      "type" : "http://gedcomx.org/Female"
    },
    "names" : [ {
      "attribution" : {
        "changeMessage" : "...change message..."
      },
      "type" : "http://gedcomx.org/BirthName",
      "preferred" : true,
      "nameForms" : [ {
        "fullText" : "Anastasia Aleksandrova",
        "parts" : [ {
          "type" : "http://gedcomx.org/Given",
          "value" : "Anastasia"
        }, {
          "type" : "http://gedcomx.org/Surname",
          "value" : "Aleksandrova"
        } ]
      } ]
    } ],
    "facts" : [ {
      "type" : "http://gedcomx.org/Birth",
      "date" : {
        "original" : "3 Apr 1836",
        "formal" : "+1836"
      },
      "place" : {
        "original" : "Moscow, Russia"
      }
    } ],
    "display" : {
      "name" : "Anastasia Aleksandrova",
      "gender" : "Female"
    }
  } ]
}
```

(The classic use-case page shows a longer variant with a second Cyrillic `nameForms` entry, a `Residence` fact with `"normalized"` place values, and a fuller `display` block — same envelope.)

Response: `201 Created`
- `X-entity-id: 12345` (new person ID)
- `Location: https://api.familysearch.org/platform/tree/persons/12345`
- `Link` headers to notes, matches, descendancy, ancestry.

Errors: `429` throttled. Recommendation from uploading guide: store the returned Person ID (with the Tree ID) alongside your app's person data.

---

## 6. Create Child-and-Parents Relationship

Source: https://developers.familysearch.org/main/docs/create-child-and-parents-relationship

- Method: `POST`
- Path: `/platform/tree/relationships`  (yes — the generic relationships collection; the Location points at child-and-parents-relationships)
- Content-Type: `application/x-fs-v1+json` (or `application/x-fs-v1+xml`)

Verbatim request body:

```json
{
  "childAndParentsRelationships" : [ {
    "parent1" : {
      "resource" : "https://api.familysearch.org/platform/tree/persons/PPPX-MP1",
      "resourceId" : "PPPX-MP1"
    },
    "parent2" : {
      "resource" : "https://api.familysearch.org/platform/tree/persons/PPPX-FP2",
      "resourceId" : "PPPX-FP2"
    },
    "child" : {
      "resource" : "https://api.familysearch.org/platform/tree/persons/PPPX-PP3",
      "resourceId" : "PPPX-PP3"
    },
    "parent1Facts" : [ {
      "id" : "C.1",
      "attribution" : {
        "contributor" : {
          "resource" : "https://api.familysearch.org/platform/users/agents/JNYR-KJP"
        },
        "changeMessage" : "...change message..."
      },
      "type" : "http://gedcomx.org/AdoptiveParent"
    } ],
    "parent2Facts" : [ {
      "id" : "C.2",
      "attribution" : {
        "contributor" : {
          "resource" : "https://api.familysearch.org/platform/users/agents/JNYR-KJP"
        },
        "changeMessage" : "...change message..."
      },
      "type" : "http://gedcomx.org/BiologicalParent"
    } ]
  } ]
}
```

Response: `201 Created`
- `X-entity-id: PPPX-PP0`
- `Location: https://api.familysearch.org/platform/tree/child-and-parents-relationships/PPPX-PP0`
- `Link: <https://api.familysearch.org/platform/tree/child-and-parents-relationships/PPPX-PP0/source-references?flag=fsh>; rel="source-references"`
- `Link: <https://api.familysearch.org/platform/tree/child-and-parents-relationships/PPPX-PP0/notes?flag=fsh>; rel="notes"`

User-tree note (uploading guide, verbatim): "No tree Id is required. However, the system will return an error if an attempt is made to create a relationship between persons belonging to different tree spaces."

---

## 7. Create Couple Relationship

Source: https://developers.familysearch.org/main/docs/create-couple-relationship

- Method: `POST`
- Path: `/platform/tree/relationships`
- Content-Type: `application/x-fs-v1+json`

Verbatim request body:

```json
{
  "relationships" : [ {
    "type" : "http://gedcomx.org/Couple",
    "person1" : {
      "resource" : "https://api.familysearch.org/platform/tree/persons/FJP-M4RK",
      "resourceId" : "FJP-M4RK"
    },
    "person2" : {
      "resource" : "https://api.familysearch.org/platform/tree/persons/JRW-NMSD",
      "resourceId" : "JRW-NMSD"
    },
    "facts" : [ {
      "attribution" : {
        "contributor" : {
          "resource" : "https://api.familysearch.org/platform/users/agents/JNYR-KJP"
        },
        "changeMessage" : "...change message..."
      },
      "type" : "http://gedcomx.org/Marriage",
      "date" : {
        "original" : "June 1800",
        "formal" : "+1800-06"
      },
      "place" : {
        "original" : "Provo, Utah, Utah, United States"
      }
    } ]
  } ]
}
```

Response: `201 Created`
- `X-entity-id: 12345`
- `Location: https://api.familysearch.org/platform/tree/couple-relationships/12345`
- `Link: <https://api.familysearch.org/platform/tree/couple-relationships/12345/source-references?flag=fsh>; rel="source-references"`
- `Link: <https://api.familysearch.org/platform/tree/couple-relationships/12345/notes?flag=fsh>; rel="notes"`

Constraint (verbatim): "The couple relationship for FamilySearch Family Tree requires person 1 to be male and person 2 to be female." (Stated for Family Tree; whether enforced in user trees is not stated.)

---

## 8. Create Source Description

Source: https://developers.familysearch.org/main/docs/create-source-description

- Method: `POST`
- Path: `/platform/sources/descriptions`
- Content-Type: `application/x-gedcomx-v1+json`

Verbatim request body:

```json
{
  "sourceDescriptions" : [ {
    "about" : "https://familysearch.org/pal:/MM9.1.1/M9PJ-2JJ",
    "citations" : [ {
      "value" : "\"United States Census, 1900.\" database and digital images, FamilySearch (https://familysearch.org/: accessed 17 Mar 2012), Ethel Hollivet, 1900; citing United States Census Office, Washington, D.C., 1900 Population Census Schedules, Los Angeles, California, population schedule, Los Angeles Ward 6, Enumeration District 58, p. 20B, dwelling 470, family 501, FHL microfilm 1,240,090; citing NARA microfilm publication T623, roll 90."
    } ],
    "titles" : [ {
      "value" : "1900 US Census, Ethel Hollivet"
    } ],
    "notes" : [ {
      "text" : "Ethel Hollivet (line 75) with husband Albert Hollivet (line 74); also in the dwelling: step-father Joseph E Watkins (line 72), mother Lina Watkins (line 73), and grandmother -- Lina's mother -- Mary Sasnett (line 76).  Albert's mother and brother also appear on this page -- Emma Hollivet (line 68), and Eddie (line 69)."
    } ]
  } ]
}
```

Response: `201 Created`
- `X-entity-id: QDS-NBVC`
- `Location: https://api.familysearch.org/platform/sources/descriptions/QDS-NBVC`

Rule (uploading guide, verbatim): "A Source Description can be associated with multiple tree persons, including persons belonging to different trees."

---

## 9. Create Person Source Reference

Source: https://developers.familysearch.org/main/docs/create-person-source-reference (+ classic Create_Person_Source_Reference_usecase, identical)

- Method: `POST`
- Path: `/platform/tree/persons/PPPP-PPP`  (POST to the person itself, NOT .../source-references)
- Content-Type: `application/x-gedcomx-v1+json` (or `application/x-gedcomx-v1+xml`)

Verbatim request body:

```json
{
  "persons" : [ {
    "sources" : [ {
      "attribution" : {
        "changeMessage" : "Family is at the same address found in other sources associated with this family.  Names are a good match.  Estimated births are reasonable."
      },
      "description" : "https://api.familysearch.org/platform/sources/descriptions/MMMM-MMM",
      "tags" : [ {
        "resource" : "http://gedcomx.org/Name"
      }, {
        "resource" : "http://gedcomx.org/Gender"
      }, {
        "resource" : "http://gedcomx.org/Birth"
      } ]
    } ]
  } ]
}
```

Response: `201 Created`
- `X-entity-id: SRSR-R01`
- `Location: https://api.familysearch.org/platform/tree/persons/PPPP-PPP/source-references/SRSR-R01`
- `Content-location: /platform/tree/persons/PPPP-PPP`

---

## 10. Create Couple Relationship Source Reference

Source: https://developers.familysearch.org/main/docs/create-couple-relationship-source-reference

- Method: `POST`
- Path: `/platform/tree/couple-relationships/RRRR-RRR/source-references`
- Content-Type: `application/x-gedcomx-v1+json`

Verbatim request body:

```json
{
  "relationships" : [ {
    "id" : "RRRR-RRR",
    "sources" : [ {
      "attribution" : {
        "changeMessage" : "Family is at the same address found in other sources associated with this family.  Names are a good match.  Estimated births are reasonable."
      },
      "description" : "https://api.familysearch.org/platform/sources/descriptions/MMMM-MMM",
      "tags" : [ {
        "resource" : "http://gedcomx.org/Name"
      }, {
        "resource" : "http://gedcomx.org/Gender"
      }, {
        "resource" : "http://gedcomx.org/Birth"
      } ]
    } ]
  } ]
}
```

Response: `201 Created`
- `X-entity-id: SRSR-R01`
- `Location: https://api.familysearch.org/platform/tree/couple-relationships/RRRR-RRR/source-references/SRSR-R01`
- `Content-location: /platform/tree/couple-relationships/RRRR-RRR/source-references`

---

## 11. Create Child-and-Parents Relationship Source Reference

Source: https://developers.familysearch.org/main/docs/create-child-and-parents-relationship-source-reference

- Method: `POST`
- Path: `/platform/tree/child-and-parents-relationships/RRRR-RRR/source-references`
- Content-Type: `application/x-fs-v1+json` (or `application/x-fs-v1+xml`)  — note fs-v1, not gedcomx-v1, because childAndParentsRelationships is an FS extension type

Verbatim request body:

```json
{
  "childAndParentsRelationships" : [ {
    "sources" : [ {
      "attribution" : {
        "changeMessage" : "Family is at the same address found in other sources associated with this family.  Names are a good match.  Estimated births are reasonable."
      },
      "description" : "https://api.familysearch.org/platform/sources/descriptions/MMMM-MMM",
      "tags" : [ {
        "resource" : "http://gedcomx.org/Name"
      }, {
        "resource" : "http://gedcomx.org/Gender"
      }, {
        "resource" : "http://gedcomx.org/Birth"
      } ]
    } ]
  } ]
}
```

Response: `201 Created`
- `X-entity-id: SRSR-R01`
- `Location: https://api.familysearch.org/platform/tree/child-and-parents-relationships/RRRR-RRR/source-references/SRSR-R01`
- `X-processing-time: 3`

---

## 12. Update User Tree (finalize: startingPersonId + hidden flip + private flag)

Source: https://developers.familysearch.org/main/docs/update-user-tree.md (example) + https://developers.familysearch.org/main/docs/updatetree (reference)

- Method: `POST`
- Path: `/platform/trees/{tid}`  (example: `POST /platform/trees/9NMM-9D6C`)
- Content-Type: `application/x-gedcomx-v1+json` (per the example page)

Verbatim request body — **copied exactly as printed in the docs, WHICH IS MALFORMED JSON** (the `ownerAccess` and `groupAccess` keys are missing their closing quotes in the doc). Fix the quoting on the wire:

```json
{
  "trees" : [ {
    "startingPersonId" : "BM62-5YF",
    "hidden" : false,
    "private" : false,
    "ownerAccess : "http://familysearch.org/v1/CompanyApps",
    "groupAccess : "http://familysearch.org/v1/CompanyApps"
  } ]
}
```

Reference-page (updatetree) modifiable fields: `startingPersonId`, `hidden`, `private`, `name`, `description`, `ownerAccess`, `groupAccess`, `allAccess` (enum URIs as in Create Tree). "Only one tree per request." "Empty strings remove attribute values."

Response: `204 No Content` (headers: `Content-type: text/html`, `X-processing-time: 179`).
Errors: `404` tree does not exist; `410` tree has been deleted; `429` throttled.

Rules (verbatim):
- "The hidden state can only be changed one time. Once the `hidden` attribute of the tree is set to `false` it cannot be set back to `true`."
- "Hidden and private should only be changed to false once your tree has all details."
- "If the tree remains in the private state, it will not show up in any Searches or Matches on the FamilySearch website."

---

## Ordering rules and constraints (from uploading-a-user-tree, access-model, privacy-model, comparison, private-spaces docs)

1. **Group before tree.** Create Group → returns group ID → Create Tree requires `groupIds` (exactly one).
2. **Tree before current-tree selection; current-tree before persons.** Create Tree → `X-Entity-Id` = tree ID → `POST /platform/trees/current` with that ID. Person creation has no tree parameter; the current-tree context is the only documented targeting mechanism. ("Creating a person in user tree space requires a Tree ID" — comparison doc footnote.) **No per-call override parameter is documented.** Switch back with id `"GLOBAL"` for public Family Tree operations.
3. **Persons before relationships.** Relationships reference person IDs; "No tree Id is required. However, the system will return an error if an attempt is made to create a relationship between persons belonging to different tree spaces." Person IDs are unique across Family Tree and user trees.
4. **Source description before source reference.** The reference's `description` URI points at the created description. A Source Description can be attached to persons in multiple different trees.
5. **Finalize last.** After all persons/relationships/sources/memories are uploaded: `POST /platform/trees/{tid}` setting `startingPersonId`, `hidden: false`, and (optionally) `private: false`.
6. **Hidden flip is one-way** (false → cannot go back to true). Trees are created `hidden=true`.
7. **Private defaults true**; private trees are invisible to Search/Matches. Privacy auto-expires: after 2 years of owner inactivity with no contributor edits, FamilySearch emails the owner and after 30 more days the tree flips to public.
8. **Access fields effectively fixed at creation.** `ownerAccess` default `CompanyApp`, `groupAccess` default `None`, `allAccess` defaults to `groupAccess`. Access-model doc: fields "should be configured carefully at creation time and not changed afterward" / "intended to remain unchanged for the lifetime of the tree." Third-party search/match over user-tree persons requires all three = `AnyApps`.
9. **Living persons**: default classification is living if unspecified or no death event; living persons live in private space and are not publicly viewable; flagging deceased makes the record public (reverting requires administrator intervention).
10. **Memories are public** (verbatim): "Memories added to a user tree through the API are public, even if the user tree is set to private."
11. **Save an upload timestamp** after finishing, for later syncing via the Tree Change History endpoint; that feed excludes changes to Memories, Source Descriptions, and Discussions.
12. **Unsupported in user trees**: Ordinances, Relationship Finder, Current User Person, Match by Example.

## Unresolved / needs live probe

- Access enum wire values are inconsistent across docs: bare `"CompanyApps"`/`"None"` (create example) vs URI `http://familysearch.org/v1/CompanyApp` (createtree reference, singular) vs URI `http://familysearch.org/v1/CompanyApps` (update example, plural).
- The update-user-tree example JSON is malformed in the docs (missing closing quotes on two keys) — corrected form must be inferred.
- Content-Type for Update Tree: example shows `application/x-gedcomx-v1+json`, but trees are FS extension types elsewhere (`x-fs-v1+json` on create). Either may work; probe.
- Scope of current-tree selection ("session"): whether it binds to the access token or the user is not documented; treat as per-token and re-assert before each write batch.
- Whether Create Person returns `X-entity-id` on beta host (reference page documents only `Location`; classic usecase shows `X-entity-id: 12345`).
- Whether the couple person1=male/person2=female constraint applies inside user trees (stated for Family Tree only).
- Beta host `apibeta.familysearch.org` vs production `api.familysearch.org`: reference pages use apibeta; Location examples use api. Use the host your key is enrolled for (this project's FS access is via the Beta program).
