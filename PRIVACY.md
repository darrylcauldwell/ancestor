# Ancestor Research — Privacy Policy

**Last updated:** 4 July 2026

## Overview

Ancestor Research is a genealogy app that runs on your Mac. Your family tree data is stored locally on your device. This policy explains what data the app accesses and how it is used.

## Data Storage

All family tree data (profiles, relationships, research results, audit findings) is stored in a local SQLite database on your Mac. This data is not uploaded to any server, cloud service, or third party — unless you explicitly publish a redacted snapshot of your tree to your own iCloud account for people you invite (see "Family Tree Publishing" below). Research data, evidence, and working notes are never published under any circumstances.

The database is located in the app's sandboxed container and is not accessible to other apps.

## External Services

The app connects to the following external services to search for historical records:

| Service | Data Sent | Purpose |
|---------|-----------|---------|
| FreeBMD (freebmd.org.uk) | Surname, given name, year range | Search civil registration indexes |
| FreeCen (freecen.org.uk) | Surname, given name, census year | Search census transcriptions |
| CWGC (cwgc.org) | Surname | Search military casualty records |
| Find a Grave (findagrave.com) | Surname, given name, year range | Search burial memorials |
| Probate Calendar (probatesearch.service.gov.uk) | Surname, given name, year range | Search probate grants |
| Wirksworth Parish Records (wirksworth.org.uk) | Surname | Search parish register transcriptions |
| FreeREG (freereg.org.uk) | Surname, given name, year range | Search parish registers |
| FamilySearch (familysearch.org) | Surname, given name, year range | Search historical record collections |

Only the search parameters listed above are sent. Your full tree data is never transmitted.

## Optional Features

### Family Tree Publishing (iCloud)

If you choose **Publish Tree to iCloud**, the app creates a redacted copy of your tree and stores it in your own iCloud account using Apple's CloudKit. This never happens automatically — publishing is always an explicit action, preceded by a review screen where you confirm how every person will appear.

- **What is shared:** names, dates, places, relationships, life events, and any photos you individually mark for publishing — after redaction.
- **Living people** are shared as name-only entries by default. Their dates, places, events, and photos are excluded unless you explicitly override this for a specific person in the review screen.
- **What is never shared:** research evidence, source-search history, working notes, audit findings, and anything you mark as sensitive or choose to omit.
- **Who can see it:** only people you personally invite, through Apple's iCloud sharing. Invited family members can view the tree but cannot change it — this is enforced by Apple's servers, not just by the app. The shared copy is stored in your iCloud account and counts against your iCloud storage.
- **Stopping:** you can unpublish at any time, which removes the shared copy from iCloud and revokes all invitations.

Apple's processing of iCloud data is governed by [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

### Local Reasoning Model

The app can optionally load a local, open-weight AI reasoning model (selected in Settings) using Apple's MLX framework. The model runs entirely on your device using Apple Silicon. No data is sent to any external service for local model inference; the only network activity involved is the one-time download of the model weights themselves.

## Data Collection

Ancestor Research does not collect analytics, telemetry, crash reports, or usage data. The app does not contain advertising. There are no user accounts.

## Third-Party Data

Historical records returned by the external services listed above are stored locally in your project database for research purposes. These records are sourced from publicly available genealogical databases.

## Children's Privacy

Ancestor Research does not knowingly collect data from children under 13. The app processes historical genealogical records which may include information about deceased individuals of any age.

## Changes

This privacy policy may be updated when new features are added. Changes will be noted with an updated date at the top of this page.

## Contact

For questions about this privacy policy, please open an issue at the project's GitHub repository.
