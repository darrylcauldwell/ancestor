# Ancestor Research — Support

## Getting Help

For questions, bug reports, or feature requests, please open an issue at the project's GitHub repository.

## Frequently Asked Questions

### How do I import my family tree?

The app supports two import methods:
- **GEDCOM**: File → Import GEDCOM, select your `.ged` file
- **WikiTree**: Settings → WikiTree, enter your email and password

### Exporting a GEDCOM from another tree app

Most commercial genealogy services let you download your tree as a `.ged` file:

- **Ancestry.com** — Trees → Tree Settings → Manage Tree → Export tree
- **MyHeritage** — Family tree → Manage trees → Export to GEDCOM
- **FindMyPast** — Tree menu (top right of your tree) → Export GEDCOM
- **Family Tree Maker** — File → Export → GEDCOM
- **Family Historian** — File → Export → GEDCOM file
- **RootsMagic** — File → Export → GEDCOM
- **Reunion** — File → Export → GEDCOM
- **FamilySearch** — My Family Tree → Tools → Export GEDCOM (available for personal trees, not the shared Family Tree)

Once you have the `.ged` file: launch Ancestor Research, click **Import GEDCOM…** on the welcome screen, or drag the file directly onto the window.

We don't connect to these services directly — the app works on the GEDCOM file alone, then enriches it from the seven free historical sources listed below.

### How do I search for records?

Select the **Research** tab in the sidebar, choose a profile, select a research mode (Verify, Extend, or Discover), and click **Research**. The app searches all enabled sources automatically.

### What sources does the app search?

FreeBMD (civil registration 1837+), FreeCen (census 1841-1921), CWGC (military casualties WWI/WWII), Find a Grave (burial memorials), Probate Calendar (1858+), Wirksworth Parish Records (~1550-1860), and FreeREG (parish registers ~1500-1900).

### How does the scoring work?

Every record is scored through 4 gates: name similarity, date compatibility, geographic consistency, and family context. Records that pass all gates are facts. Records with soft failures are leads. Records that fail hard are impossible.

### What is the reasoning model?

An optional on-device AI model (DeepSeek-R1) that runs on Apple Silicon. It suggests research strategy, evaluates evidence clusters, disambiguates conflicting records, and drafts biographical summaries. It runs locally — no internet required, no third-party AI services involved.

### Where is my data stored?

All data is stored locally on your Mac in the app's sandboxed container. Nothing is uploaded to any cloud service.

## System Requirements

- macOS 26 or later
- Apple Silicon (M1 or later) required for the local reasoning model
- Internet connection required for source searches
