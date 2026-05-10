import Foundation

/// M21 — "Share read-only link" per DESIGN.md §13. Renders the family tree as
/// a folder of vanilla HTML/CSS files. A recipient who's never heard of this
/// app can open `index.html` in any browser and click through the tree.
///
/// Output format: one `index.html` (alphabetical profile list), one
/// `profile-{id}.html` per profile, one shared `style.css`. No JavaScript
/// required — purely static, link-driven navigation.
nonisolated enum HTMLExporter {

    nonisolated struct ExportRequest: Sendable {
        let snapshot: FamilyGraphSnapshot
        let lifeEvents: [LifeEvent]
        let projectName: String
        let excludeLiving: Bool
        let excludeSensitive: Bool
    }

    nonisolated struct ExportResult: Sendable {
        /// Tuple-list rather than a dictionary — we want stable iteration
        /// order when writing files and asserting in tests.
        let files: [(relativePath: String, contents: String)]
    }

    // MARK: - Public entry point

    static func export(_ request: ExportRequest) -> ExportResult {
        // Sort profiles alphabetically by display name (then by id for ties)
        // so both the index and the file order are deterministic.
        let allProfiles = request.snapshot.profiles.values
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                let l = sortKey(for: lhs)
                let r = sortKey(for: rhs)
                if l == r { return lhs.id < rhs.id }
                return l < r
            }

        // Bucket life events by profile so per-profile rendering is O(1) per
        // profile rather than O(N) scans of every event list.
        var eventsByProfile: [String: [LifeEvent]] = [:]
        for event in request.lifeEvents {
            eventsByProfile[event.profileID, default: []].append(event)
        }

        var files: [(relativePath: String, contents: String)] = []

        // index.html ----------------------------------------------------------
        files.append((
            relativePath: "index.html",
            contents: renderIndex(profiles: allProfiles, request: request)
        ))

        // style.css -----------------------------------------------------------
        files.append((
            relativePath: "style.css",
            contents: stylesheet
        ))

        // profile-{id}.html ---------------------------------------------------
        // We always emit a page per non-deleted profile (subject to the
        // excludeLiving filter on living-private people) so cross-links to a
        // living person who would otherwise be rendered as "[Living]" still
        // resolve to a page.
        for profile in allProfiles {
            if request.excludeLiving && isLivingPrivate(profile) { continue }
            let events = eventsByProfile[profile.id] ?? []
            let html = renderProfile(
                profile: profile,
                events: events,
                snapshot: request.snapshot,
                projectName: request.projectName,
                excludeLiving: request.excludeLiving,
                excludeSensitive: request.excludeSensitive
            )
            files.append((
                relativePath: "profile-\(safeFilenameID(profile.id)).html",
                contents: html
            ))
        }

        return ExportResult(files: files)
    }

    // MARK: - Index page

    private static func renderIndex(
        profiles: [Profile],
        request: ExportRequest
    ) -> String {
        let title = escape(request.projectName)
        var body = ""
        body.append("<header><h1>\(title)</h1>")

        let visibleCount: Int = {
            if request.excludeLiving {
                return profiles.filter { !isLivingPrivate($0) }.count
            }
            return profiles.count
        }()
        body.append(
            "<p class=\"meta\">\(visibleCount) "
            + (visibleCount == 1 ? "profile" : "profiles")
            + "</p></header>"
        )

        body.append("<main><ul class=\"profile-index\">")
        for profile in profiles {
            if request.excludeLiving && isLivingPrivate(profile) { continue }
            if isLivingPrivate(profile) {
                body.append("<li class=\"living\">[Living]</li>")
                continue
            }
            let name = escape(displayName(for: profile))
            let years = lifespan(profile)
            let yearsHTML = years.isEmpty ? "" : " <span class=\"years\">(\(escape(years)))</span>"
            let href = "profile-\(safeFilenameID(profile.id)).html"
            body.append(
                "<li><a href=\"\(escape(href))\">\(name)</a>\(yearsHTML)</li>"
            )
        }
        body.append("</ul></main>")

        body.append(footer())

        return wrapPage(title: title, body: body)
    }

    // MARK: - Profile page

    private static func renderProfile(
        profile: Profile,
        events: [LifeEvent],
        snapshot: FamilyGraphSnapshot,
        projectName: String,
        excludeLiving: Bool,
        excludeSensitive: Bool
    ) -> String {
        let pageTitle = "\(displayName(for: profile)) – \(projectName)"
        var body = ""

        body.append("<header>")
        body.append("<p class=\"breadcrumb\"><a href=\"index.html\">\(escape(projectName))</a></p>")
        body.append("<h1>\(escape(displayName(for: profile)))</h1>")
        let years = lifespan(profile)
        if !years.isEmpty {
            body.append("<p class=\"years\">\(escape(years))</p>")
        }
        body.append("</header>")

        body.append("<main>")

        // Vital facts ---------------------------------------------------------
        body.append("<section class=\"vitals\"><h2>Vital facts</h2><dl>")
        if let birth = profile.birthDate {
            body.append("<dt>Born</dt><dd>\(escape(birth.original))")
            if let loc = profile.birthLocation, !loc.isEmpty {
                body.append(" &middot; \(escape(loc))")
            }
            body.append("</dd>")
        } else if let loc = profile.birthLocation, !loc.isEmpty {
            body.append("<dt>Born</dt><dd>\(escape(loc))</dd>")
        }
        if let death = profile.deathDate {
            body.append("<dt>Died</dt><dd>\(escape(death.original))")
            if let loc = profile.deathLocation, !loc.isEmpty {
                body.append(" &middot; \(escape(loc))")
            }
            body.append("</dd>")
        } else if let loc = profile.deathLocation, !loc.isEmpty {
            body.append("<dt>Died</dt><dd>\(escape(loc))</dd>")
        }
        if let gender = profile.gender, gender != .unknown {
            body.append("<dt>Gender</dt><dd>\(escape(gender.rawValue.capitalized))</dd>")
        }
        body.append("</dl>")

        let comp = snapshot.completeness(for: profile.id)
        body.append(
            "<p class=\"completeness\">Completeness: \(comp.score) / \(comp.maximum)</p>"
        )
        body.append("</section>")

        // Bio -----------------------------------------------------------------
        if let bio = profile.bio, !bio.isEmpty {
            body.append("<section class=\"bio\"><h2>Biography</h2>")
            for paragraph in bio.split(separator: "\n", omittingEmptySubsequences: true) {
                body.append("<p>\(escape(String(paragraph)))</p>")
            }
            body.append("</section>")
        }

        // Family --------------------------------------------------------------
        let parents = snapshot.parentsOf(profile.id)
        let spouses = snapshot.spousesOf(profile.id)
        let children = snapshot.childrenOf(profile.id)

        if !parents.isEmpty || !spouses.isEmpty || !children.isEmpty {
            body.append("<section class=\"family\"><h2>Family</h2>")
            body.append(renderRelationGroup("Parents", parents, excludeLiving: excludeLiving))
            body.append(renderRelationGroup("Spouses", spouses, excludeLiving: excludeLiving))
            body.append(renderRelationGroup("Children", children, excludeLiving: excludeLiving))
            body.append("</section>")
        }

        // Life events ---------------------------------------------------------
        let visibleEvents = events
            .filter { !(excludeSensitive && $0.sensitive) }
            .sorted { lhs, rhs in
                (lhs.sortYear ?? Int.max) < (rhs.sortYear ?? Int.max)
            }
        if !visibleEvents.isEmpty {
            body.append("<section class=\"events\"><h2>Life events</h2><ul>")
            for event in visibleEvents {
                body.append("<li>\(renderLifeEvent(event))</li>")
            }
            body.append("</ul></section>")
        }

        // Sources -------------------------------------------------------------
        let sourceLines = renderSourceLines(profile: profile)
        if !sourceLines.isEmpty {
            body.append("<section class=\"sources\"><h2>Sources</h2><ol>")
            for line in sourceLines {
                body.append("<li>\(line)</li>")
            }
            body.append("</ol></section>")
        }

        body.append("</main>")
        body.append(footer())

        return wrapPage(title: pageTitle, body: body)
    }

    private static func renderRelationGroup(
        _ heading: String,
        _ people: [Profile],
        excludeLiving: Bool
    ) -> String {
        guard !people.isEmpty else { return "" }
        var html = "<h3>\(escape(heading))</h3><ul>"
        // Sort by display name for deterministic output.
        let sorted = people.sorted { sortKey(for: $0) < sortKey(for: $1) }
        for person in sorted {
            if isLivingPrivate(person) {
                if excludeLiving {
                    html.append("<li class=\"living\">[Living]</li>")
                } else {
                    let href = "profile-\(safeFilenameID(person.id)).html"
                    html.append("<li><a href=\"\(escape(href))\">[Living]</a></li>")
                }
                continue
            }
            let name = escape(displayName(for: person))
            let years = lifespan(person)
            let suffix = years.isEmpty ? "" : " <span class=\"years\">(\(escape(years)))</span>"
            let href = "profile-\(safeFilenameID(person.id)).html"
            html.append("<li><a href=\"\(escape(href))\">\(name)</a>\(suffix)</li>")
        }
        html.append("</ul>")
        return html
    }

    private static func renderLifeEvent(_ event: LifeEvent) -> String {
        var parts: [String] = []
        parts.append("<strong>\(escape(event.type.displayName))</strong>")
        if let date = event.date {
            var dateStr = date.original
            if let end = event.endDate, end.original != date.original {
                dateStr += " – \(end.original)"
            }
            parts.append(escape(dateStr))
        } else if let end = event.endDate {
            parts.append("until " + escape(end.original))
        }
        if let location = event.location, !location.isEmpty {
            parts.append(escape(location))
        }
        if let description = event.description, !description.isEmpty {
            parts.append(escape(description))
        }
        return parts.joined(separator: " &middot; ")
    }

    /// One line per FieldSource. Prefer structured citation rendering when
    /// available; fall back to the raw source string. We mirror
    /// `ResearchReportComposer.formatCitationLine` semantics so the same source
    /// reads the same way across narrative reports and HTML exports.
    private static func renderSourceLines(profile: Profile) -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        // Iterate fields in a deterministic order so test expectations hold.
        for field in ProfileField.allCases {
            guard let sources = profile.sources[field] else { continue }
            for source in sources {
                let label = formatSource(source)
                guard !label.isEmpty else { continue }
                let key = "\(field.rawValue)|\(label)"
                guard seen.insert(key).inserted else { continue }
                let fieldTag = "<span class=\"field\">\(escape(field.rawValue))</span>"
                let urlSuffix: String
                if let urlString = source.citation?.url, !urlString.isEmpty {
                    let safe = escape(urlString)
                    urlSuffix = " <a class=\"src-link\" href=\"\(safe)\">link</a>"
                } else {
                    urlSuffix = ""
                }
                lines.append("\(fieldTag) \(escape(label))\(urlSuffix)")
            }
        }
        return lines
    }

    private static func formatSource(_ source: FieldSource) -> String {
        if let citation = source.citation, !citation.isEmpty {
            let formatted = citation.formatted.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !formatted.isEmpty { return formatted }
        }
        let raw = source.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        return source.origin.identifier
    }

    // MARK: - Helpers

    /// Browser-safe HTML escape — applied to every value before rendering.
    /// `nonisolated` so callers in tests/services don't need to be on the main
    /// actor.
    nonisolated static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for char in s {
            switch char {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(char)
            }
        }
        return out
    }

    /// IDs originate from GEDCOM (`@I123@`) or UUID strings — both contain
    /// characters that aren't safe in filenames or URLs. Strip to a
    /// conservative alphanumeric + dash + underscore subset.
    private static func safeFilenameID(_ id: String) -> String {
        var out = ""
        out.reserveCapacity(id.count)
        for char in id {
            if char.isLetter || char.isNumber || char == "-" || char == "_" {
                out.append(char)
            } else {
                out.append("_")
            }
        }
        return out.isEmpty ? "unknown" : out
    }

    private static func isLivingPrivate(_ profile: Profile) -> Bool {
        profile.resolvedAttributes.privacy == .livingPrivate
    }

    private static func displayName(for profile: Profile) -> String {
        let name = profile.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "(Unknown)" : name
    }

    private static func sortKey(for profile: Profile) -> String {
        // Sort by lastName then firstName so the alphabetical index reads
        // surname-first like a phonebook. Falls back to displayName when the
        // pieces are missing.
        let last = (profile.lastName ?? "").lowercased()
        let first = (profile.firstName ?? "").lowercased()
        return "\(last)|\(first)"
    }

    private static func lifespan(_ profile: Profile) -> String {
        let birth = profile.birthDate?.bestYear
        let death = profile.deathDate?.bestYear
        switch (birth, death) {
        case let (b?, d?): return "\(b)\u{2013}\(d)"
        case let (b?, nil): return "b. \(b)"
        case let (nil, d?): return "d. \(d)"
        case (nil, nil): return ""
        }
    }

    private static func footer() -> String {
        "<footer><p class=\"meta\">Generated by Ancestor Research</p></footer>"
    }

    private static func wrapPage(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <link rel="stylesheet" href="style.css">
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Stylesheet

    private static let stylesheet: String = """
    /* Ancestor Research — read-only HTML export */
    :root {
        --text: #1d1d1f;
        --muted: #6e6e73;
        --link: #0066cc;
        --link-hover: #003e7e;
        --border: #d2d2d7;
        --bg: #ffffff;
        --bg-soft: #f5f5f7;
    }
    * { box-sizing: border-box; }
    html, body {
        margin: 0;
        padding: 0;
        background: var(--bg);
        color: var(--text);
    }
    body {
        font-family: Georgia, "Times New Roman", serif;
        font-size: 17px;
        line-height: 1.55;
        max-width: 760px;
        margin: 0 auto;
        padding: 32px 24px 64px;
    }
    header { margin-bottom: 24px; }
    header h1 {
        font-size: 2rem;
        margin: 0 0 4px;
        line-height: 1.2;
    }
    header .years, header .meta, .breadcrumb {
        color: var(--muted);
        margin: 0;
    }
    .breadcrumb { font-size: 0.95rem; margin-bottom: 12px; }
    h2 {
        font-size: 1.2rem;
        border-bottom: 1px solid var(--border);
        padding-bottom: 4px;
        margin-top: 32px;
    }
    h3 {
        font-size: 1rem;
        margin-top: 16px;
        margin-bottom: 4px;
        color: var(--muted);
        font-weight: normal;
        text-transform: uppercase;
        letter-spacing: 0.04em;
    }
    a {
        color: var(--link);
        text-decoration: none;
    }
    a:hover, a:focus { color: var(--link-hover); text-decoration: underline; }
    ul, ol { padding-left: 22px; }
    li { margin-bottom: 4px; }
    dl { margin: 0; }
    dt {
        font-weight: bold;
        margin-top: 8px;
    }
    dd {
        margin: 0 0 4px;
        padding-left: 0;
    }
    .profile-index { list-style: none; padding-left: 0; }
    .profile-index li {
        padding: 6px 0;
        border-bottom: 1px solid var(--border);
    }
    .years { color: var(--muted); font-size: 0.9rem; }
    .completeness {
        background: var(--bg-soft);
        padding: 6px 10px;
        border-radius: 6px;
        display: inline-block;
        font-size: 0.9rem;
        color: var(--muted);
    }
    .sources { font-size: 0.95rem; }
    .sources .field {
        display: inline-block;
        font-family: -apple-system, system-ui, sans-serif;
        font-size: 0.75rem;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        color: var(--muted);
        background: var(--bg-soft);
        padding: 1px 6px;
        border-radius: 4px;
        margin-right: 6px;
    }
    .sources .src-link {
        font-size: 0.85rem;
        margin-left: 4px;
    }
    .living {
        color: var(--muted);
        font-style: italic;
    }
    footer {
        margin-top: 48px;
        padding-top: 16px;
        border-top: 1px solid var(--border);
        color: var(--muted);
        font-size: 0.85rem;
    }
    """
}
