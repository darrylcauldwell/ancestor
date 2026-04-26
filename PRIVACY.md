# Ancestor Research — Privacy Policy

**Last updated:** 26 April 2026

## Overview

Ancestor Research is a genealogy app that runs on your Mac. Your family tree data is stored locally on your device. This policy explains what data the app accesses and how it is used.

## Data Storage

All family tree data (profiles, relationships, research results, audit findings) is stored in a local SQLite database on your Mac. This data is not uploaded to any server, cloud service, or third party.

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

Only the search parameters listed above are sent. Your full tree data is never transmitted.

## Optional Features

### Local Reasoning Model

The app can optionally load a local AI reasoning model (DeepSeek-R1) using Apple's MLX framework. This model runs entirely on your device using Apple Silicon. No data is sent to any external service for local model inference.

### Field Researcher

The app offers an optional Field Researcher feature that uses the Claude API (by Anthropic) to search the web for genealogical evidence. When enabled:

- You provide your own Claude API key
- The app sends research context (profile names, dates, locations, and existing source citations) to the Claude API
- The Claude API may search the web on your behalf
- Findings are returned to the app and evaluated locally before you review them
- You control when this feature runs and can disable it at any time

No tree data is sent to Claude unless you explicitly initiate a Field Researcher session.

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
