# Ancestor Research — Support

## Getting Help

For questions, bug reports, or feature requests, please open an issue at the project's GitHub repository.

## Frequently Asked Questions

### How do I import my family tree?

The app supports two import methods:
- **GEDCOM**: File → Import GEDCOM, select your `.ged` file
- **WikiTree**: Settings → WikiTree, enter your email and password

### How do I search for records?

Select the **Research** tab in the sidebar, choose a profile, select a research mode (Verify, Extend, or Discover), and click **Research**. The app searches all enabled sources automatically.

### What sources does the app search?

FreeBMD (civil registration 1837+), FreeCen (census 1841-1921), CWGC (military casualties WWI/WWII), Find a Grave (burial memorials), Probate Calendar (1858+), Wirksworth Parish Records (~1550-1860), and FreeREG (parish registers ~1500-1900).

### How does the scoring work?

Every record is scored through 4 gates: name similarity, date compatibility, geographic consistency, and family context. Records that pass all gates are facts. Records with soft failures are leads. Records that fail hard are impossible.

### What is the reasoning model?

An optional on-device AI model (DeepSeek-R1) that runs on Apple Silicon. It suggests research strategy, evaluates evidence clusters, and drafts biographical summaries. It runs locally — no internet required.

### What is the Field Researcher?

An optional feature that uses the Claude API to search unstructured web sources (parish register photographs, newspaper archives, local history sites). Requires your own API key. Findings go through the same evidence pipeline as structured source results.

### Where is my data stored?

All data is stored locally on your Mac in the app's sandboxed container. Nothing is uploaded to any cloud service.

## System Requirements

- macOS 26 or later
- Apple Silicon (M1 or later) required for the local reasoning model
- Internet connection required for source searches and Field Researcher
