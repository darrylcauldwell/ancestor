import Foundation

/// Generates GEDCOM 5.5.1 SOUR records with proper citation fields.
/// When exported and imported into RootsMagic or Family Historian,
/// citations appear in their native UI.
nonisolated struct GEDCOMCitationExporter {

    /// Generate SOUR records for all unique sources referenced in research results.
    /// Returns (source records, source reference map from sourceID to GEDCOM @S_ID@).
    static func exportSourceRecords(
        from results: [String: ResearchResult]  // profileID → result
    ) -> (lines: [String], sourceRefs: [String: String]) {
        var sourceLines: [String] = []
        var sourceRefs: [String: String] = [:]
        var sourceCounter = 1

        // Collect unique sources
        var seenSources: Set<String> = []
        for (_, result) in results {
            for scored in result.allScoredRecords {
                let sourceID = scored.record.sourceID
                guard !seenSources.contains(sourceID) else { continue }
                seenSources.insert(sourceID)

                let ref = "@S\(sourceCounter)@"
                sourceRefs[sourceID] = ref
                sourceCounter += 1

                sourceLines.append(contentsOf: sourceRecord(for: sourceID, ref: ref))
            }
        }

        return (sourceLines, sourceRefs)
    }

    /// Generate a GEDCOM SOUR record for a source.
    private static func sourceRecord(for sourceID: String, ref: String) -> [String] {
        let (title, author, publisher, url) = sourceMetadata(for: sourceID)

        var lines = ["0 \(ref) SOUR"]
        lines.append("1 TITL \(title)")
        if !author.isEmpty {
            lines.append("1 AUTH \(author)")
        }
        if !publisher.isEmpty {
            lines.append("1 PUBL \(publisher)")
        }
        if !url.isEmpty {
            lines.append("1 NOTE \(url)")
        }
        return lines
    }

    /// Get source metadata for GEDCOM SOUR fields.
    private static func sourceMetadata(for sourceID: String) -> (title: String, author: String, publisher: String, url: String) {
        switch sourceID {
        case "freebmd":
            return ("England & Wales, Civil Registration Index (FreeBMD)",
                    "General Register Office",
                    "FreeBMD, https://www.freebmd.org.uk",
                    "https://www.freebmd.org.uk")
        case "freecen":
            return ("England & Wales, Census Returns (FreeCen)",
                    "Office for National Statistics",
                    "FreeCen, https://www.freecen.org.uk",
                    "https://www.freecen.org.uk")
        case "findagrave":
            return ("Find a Grave, database and images",
                    "",
                    "Find a Grave, https://www.findagrave.com",
                    "https://www.findagrave.com")
        case "cwgc":
            return ("Commonwealth War Graves Commission, Casualty Details",
                    "Commonwealth War Graves Commission",
                    "CWGC, https://www.cwgc.org",
                    "https://www.cwgc.org")
        case "probate":
            return ("England & Wales, National Probate Calendar",
                    "HM Courts & Tribunals Service",
                    "https://probatesearch.service.gov.uk",
                    "https://probatesearch.service.gov.uk")
        case "wirksworth":
            return ("Wirksworth Parish Records",
                    "Various contributors",
                    "http://www.wirksworth.org.uk",
                    "http://www.wirksworth.org.uk")
        case "freereg":
            return ("FreeREG Parish Register Transcriptions",
                    "Various volunteer transcribers",
                    "FreeREG, https://www.freereg.org.uk",
                    "https://www.freereg.org.uk")
        default:
            return (sourceID, "", "", "")
        }
    }

    /// Generate inline SOUR citation for an individual's event in GEDCOM.
    /// This goes under the event tag (BIRT, DEAT, MARR, etc.)
    static func inlineCitation(for scored: ScoredRecord, sourceRefs: [String: String]) -> [String] {
        guard let ref = sourceRefs[scored.record.sourceID] else { return [] }
        let citation = CitationRenderer.cite(scored.record)

        var lines = ["2 SOUR \(ref)"]
        // PAGE field — specific location within the source
        lines.append("3 PAGE \(citation.short)")
        // DATA with date accessed
        lines.append("3 DATA")
        lines.append("4 DATE \(formatGEDCOMDate(citation.accessedAt))")
        // NOTE with full citation
        if citation.full.count > 80 {
            // Split long citations
            lines.append("3 NOTE \(String(citation.full.prefix(80)))")
            var remaining = String(citation.full.dropFirst(80))
            while !remaining.isEmpty {
                let chunk = String(remaining.prefix(80))
                lines.append("4 CONT \(chunk)")
                remaining = String(remaining.dropFirst(min(80, remaining.count)))
            }
        } else {
            lines.append("3 NOTE \(citation.full)")
        }

        return lines
    }

    /// Generate evidence summary as a GEDCOM NOTE for a profile.
    static func evidenceSummaryNote(
        summary: String,
        level: Int = 1
    ) -> [String] {
        guard !summary.isEmpty else { return [] }
        var lines: [String] = []
        let chunks = summary.components(separatedBy: .newlines)
        for (i, chunk) in chunks.enumerated() {
            if i == 0 {
                lines.append("\(level) NOTE Evidence Summary: \(chunk)")
            } else {
                lines.append("\(level + 1) CONT \(chunk)")
            }
        }
        return lines
    }

    private static func formatGEDCOMDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy"
        return formatter.string(from: date).uppercased()
    }
}
