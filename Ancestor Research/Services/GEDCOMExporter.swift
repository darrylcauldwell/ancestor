import Foundation

/// Per-category counts of workbench-only data the caller is excluding from
/// a GEDCOM export. When supplied to `GEDCOMExporter.export(...)`, each
/// non-zero count produces one entry in `ExportResult.dropped[]` so the
/// post-export sheet can be honest about everything that didn't make it
/// into the file. The exporter itself doesn't know the project DB; the
/// caller (`GEDCOMDocument`) totals these up before invoking the export.
nonisolated struct WorkbenchExportSummary: Sendable {
    let hypothesisCount: Int
    let focusSetCount: Int
    let transactionCount: Int
    let workbenchNoteCount: Int

    init(
        hypothesisCount: Int = 0,
        focusSetCount: Int = 0,
        transactionCount: Int = 0,
        workbenchNoteCount: Int = 0
    ) {
        self.hypothesisCount = hypothesisCount
        self.focusSetCount = focusSetCount
        self.transactionCount = transactionCount
        self.workbenchNoteCount = workbenchNoteCount
    }
}

/// Exports a FamilyGraphSnapshot to GEDCOM 5.5.1 format.
/// This is lossy interop — app-specific data (disputes, source provenance
/// beyond first source, transaction history) is dropped. See DESIGN.md §5.10.
///
/// Citations (DESIGN.md §5.12) ARE preserved on a best-effort basis: every
/// distinct `Citation` carried by any `FieldSource` becomes a top-level
/// `0 @Snnn@ SOUR` record, and event lines (BIRT/DEAT/MARR) reference it
/// inline via `2 SOUR @Snnn@` with `3 PAGE` and `3 QUAY` children.
nonisolated struct GEDCOMExporter {

    struct ExportResult {
        let content: String
        let individualCount: Int
        let familyCount: Int
        let dropped: [String]
    }

    /// Export to a file at the given path.
    /// - Parameter excludeLiving: when true, profiles flagged `livingPrivate`
    ///   are omitted entirely. When false (default), they're emitted with a
    ///   `RESN privacy` tag so the receiving software knows to handle them
    ///   carefully.
    /// - Parameter attachments: optional per-profile attachments to emit as
    ///   `OBJE` blocks (M13). When non-empty the relative path inside the
    ///   `.ancestor` archive is written as `2 FILE media/<relativePath>`.
    /// - Parameter lifeEvents: optional life events. When provided alongside
    ///   `attachments`, attachments targeting a `.lifeEvent(id:)` resolve to
    ///   the life event's profile and are emitted as OBJE under that
    ///   individual. Required for the sensitive filter to know which life
    ///   events are flagged.
    /// - Parameter excludeSensitive: when true (M14 §7.15.2), attachments
    ///   whose target is a sensitive `LifeEvent` are omitted from the
    ///   exported OBJE blocks. Sensitive workbench notes never become GEDCOM
    ///   today (notes aren't surfaced as GEDCOM `NOTE` lines), so the flag
    ///   has no effect on note content.
    static func export(
        _ snapshot: FamilyGraphSnapshot,
        to path: String,
        excludeLiving: Bool = false,
        attachments: [Attachment] = [],
        lifeEvents: [LifeEvent] = [],
        excludeSensitive: Bool = false,
        format: GEDCOMFormat = .v5_5_1,
        workbenchSummary: WorkbenchExportSummary? = nil
    ) throws -> ExportResult {
        let result = export(
            snapshot,
            excludeLiving: excludeLiving,
            attachments: attachments,
            lifeEvents: lifeEvents,
            excludeSensitive: excludeSensitive,
            format: format,
            workbenchSummary: workbenchSummary
        )
        try result.content.write(toFile: path, atomically: true, encoding: .utf8)
        return result
    }

    /// Export to a GEDCOM string.
    static func export(
        _ snapshot: FamilyGraphSnapshot,
        excludeLiving: Bool = false,
        attachments: [Attachment] = [],
        lifeEvents: [LifeEvent] = [],
        excludeSensitive: Bool = false,
        format: GEDCOMFormat = .v5_5_1,
        workbenchSummary: WorkbenchExportSummary? = nil
    ) -> ExportResult {
        var lines: [String] = []
        var dropped: [String] = []

        // Header — version-stamped from the chosen format. GEDCOM 7.0 drops
        // the `2 FORM LINEAGE-LINKED` substructure under `1 GEDC` (it was
        // removed from the spec); 5.5.1 still requires it. The rest of the
        // header is shared.
        lines.append("0 HEAD")
        lines.append("1 SOUR AncestorResearch")
        lines.append("2 NAME \(AppConstants.displayName)")
        lines.append("1 DATE \(formatHeaderDate(Date()))")
        lines.append("1 GEDC")
        lines.append("2 VERS \(format.version.versionString)")
        if format.version == .v5_5_1 {
            lines.append("2 FORM LINEAGE-LINKED")
        }
        lines.append("1 CHAR UTF-8")

        // Submitter
        lines.append("0 @SUBM1@ SUBM")
        lines.append("1 NAME \(AppConstants.displayName)")

        // Build the citation registry up front. This lets exportIndividual /
        // exportFamily emit the right `@Snnn@` xref tokens inline as they go,
        // and we emit the SOUR records once at the end.
        let registry = CitationRegistry(snapshot: snapshot)

        // Build a lookup from life-event id → (profileID, sensitive). Used to
        // route life-event attachments to the correct INDI record and to
        // honour the M14 sensitive filter when `excludeSensitive` is set.
        var lifeEventLookup: [UUID: (profileID: String, sensitive: Bool)] = [:]
        for event in lifeEvents {
            lifeEventLookup[event.id] = (event.profileID, event.sensitive)
        }

        // Group attachments by profile. M13 emits an `OBJE` block per
        // attachment whose target is the profile itself or one of its
        // field sources. M14 also routes `.lifeEvent` attachments to their
        // owning profile when `lifeEvents` is provided. Sensitive life
        // event attachments are dropped entirely when `excludeSensitive`
        // is true.
        let attachmentsByProfile = Self.groupAttachmentsByProfile(
            attachments,
            lifeEventLookup: lifeEventLookup,
            excludeSensitive: excludeSensitive
        )

        // For GEDCOM 7.0, OBJE blocks live as top-level records and INDI
        // records reference them via `1 OBJE @M{n}@`. The registry assigns
        // a stable xref to each emitted attachment so we can emit the
        // top-level records once individual export is complete.
        let mediaRegistry = MediaRegistry()

        // Individuals — apply privacy filter once and remember which IDs
        // were dropped so family records below can skip them too.
        var indiCount = 0
        let sortedProfiles = snapshot.profiles.values.sorted { $0.id < $1.id }
        var omittedIDs: Set<String> = []
        for profile in sortedProfiles {
            let isLivingPrivate = profile.resolvedAttributes.privacy == .livingPrivate
            if excludeLiving && isLivingPrivate {
                omittedIDs.insert(profile.id)
                dropped.append("Excluded living-private profile \(profile.id)")
                continue
            }
            indiCount += 1
            let profileAttachments = attachmentsByProfile[profile.id] ?? []
            var indiLines = exportIndividual(
                profile,
                registry: registry,
                attachments: profileAttachments,
                format: format,
                mediaRegistry: mediaRegistry
            )
            if isLivingPrivate, !indiLines.isEmpty {
                // Place RESN privacy on the line after the `0 ... INDI` header.
                indiLines.insert("1 RESN privacy", at: 1)
            }
            lines.append(contentsOf: indiLines)

            // Track dropped data
            if !profile.disputes.isEmpty {
                dropped.append("Dropped \(profile.disputes.count) dispute(s) for \(profile.displayName)")
            }
            for (field, sources) in profile.sources where sources.count > 1 {
                dropped.append("Dropped \(sources.count - 1) additional source(s) for \(profile.displayName).\(field.rawValue)")
            }
        }

        // Families — reconstruct FAM records from relationships.
        // When excluding living-private profiles, drop any relationship that
        // references one of them so we don't emit dangling FAMS/FAMC links.
        let familySnapshot: FamilyGraphSnapshot = omittedIDs.isEmpty
            ? snapshot
            : FamilyGraphSnapshot(
                profiles: snapshot.profiles.filter { !omittedIDs.contains($0.key) },
                relationships: snapshot.relationships.filter {
                    !omittedIDs.contains($0.from) && !omittedIDs.contains($0.to)
                }
            )
        let families = buildFamilies(from: familySnapshot)
        var famCount = 0
        for family in families {
            famCount += 1
            lines.append(contentsOf: exportFamily(family))
        }

        // SOUR records — emit deduplicated citations as top-level records,
        // before the trailer (per GEDCOM 5.5.1 spec, top-level records may
        // appear in any order between HEAD and TRLR).
        lines.append(contentsOf: registry.exportRecords())

        // OBJE records — GEDCOM 7.0 only. 5.5.1 emits OBJE inline within
        // INDI (the registry stays empty in that mode).
        lines.append(contentsOf: mediaRegistry.exportRecords())

        // Trailer
        lines.append("0 TRLR")

        // M16.13 — surface workbench-only data the caller knows is being
        // excluded. Each non-zero category turns into one human-readable
        // entry so the post-export sheet can be specific about what was
        // dropped (and why). When `workbenchSummary` is nil the behaviour
        // is unchanged for callers that don't yet supply it.
        if let summary = workbenchSummary {
            if summary.hypothesisCount > 0 {
                dropped.append("Dropped \(summary.hypothesisCount) hypotheses (workbench-only, no GEDCOM tag)")
            }
            if summary.focusSetCount > 0 {
                dropped.append("Dropped \(summary.focusSetCount) focus sets (workbench-only, no GEDCOM tag)")
            }
            if summary.transactionCount > 0 {
                dropped.append("Dropped \(summary.transactionCount) transactions (workbench-only, no GEDCOM tag)")
            }
            if summary.workbenchNoteCount > 0 {
                dropped.append("Dropped \(summary.workbenchNoteCount) workbench notes (workbench-only, no GEDCOM tag)")
            }
        }

        return ExportResult(
            content: lines.joined(separator: "\n") + "\n",
            individualCount: indiCount,
            familyCount: famCount,
            dropped: dropped
        )
    }

    // MARK: - Individual Export

    private static func exportIndividual(
        _ profile: Profile,
        registry: CitationRegistry,
        attachments: [Attachment] = [],
        format: GEDCOMFormat = .v5_5_1,
        mediaRegistry: MediaRegistry = MediaRegistry()
    ) -> [String] {
        var lines: [String] = []
        lines.append("0 \(profile.id) INDI")

        // Name. The "Given /Surname/" form is valid in both 5.5.1 and 7.0.
        // 7.0 prefers explicit GIVN/SURN substructures alongside it. We
        // emit them in both versions when the parts are available — they
        // were already emitted under 5.5.1 (parser also reads them).
        let given = profile.firstName ?? ""
        let surname = profile.lastName ?? ""
        if !given.isEmpty || !surname.isEmpty {
            lines.append("1 NAME \(given) /\(surname)/")
            if !given.isEmpty { lines.append("2 GIVN \(given)") }
            if !surname.isEmpty { lines.append("2 SURN \(surname)") }
        }

        // Gender
        if let gender = profile.gender {
            switch gender {
            case .male: lines.append("1 SEX M")
            case .female: lines.append("1 SEX F")
            case .other: lines.append("1 SEX X")
            case .unknown: lines.append("1 SEX U")
            }
        }

        // Birth — emit citation under the BIRT event when present on either
        // birthDate or birthLocation field source. Date wins if both differ.
        if profile.birthDate != nil || profile.birthLocation != nil {
            lines.append("1 BIRT")
            if let date = profile.birthDate {
                lines.append("2 DATE \(date.original)")
            }
            if let place = profile.birthLocation {
                lines.append("2 PLAC \(place)")
            }
            let citationFieldSource = pickCitedSource(
                profile: profile,
                preferring: [.birthDate, .birthLocation]
            )
            lines.append(contentsOf: citationLines(for: citationFieldSource, registry: registry, baseLevel: 2))
        }

        // Death
        if profile.deathDate != nil || profile.deathLocation != nil {
            lines.append("1 DEAT")
            if let date = profile.deathDate {
                lines.append("2 DATE \(date.original)")
            }
            if let place = profile.deathLocation {
                lines.append("2 PLAC \(place)")
            }
            let citationFieldSource = pickCitedSource(
                profile: profile,
                preferring: [.deathDate, .deathLocation]
            )
            lines.append(contentsOf: citationLines(for: citationFieldSource, registry: registry, baseLevel: 2))
        }

        // OBJE — multimedia objects (M13). Per DESIGN.md §5.15, each
        // attachment whose target is this profile (or one of its field
        // sources) becomes one `1 OBJE` block.
        //
        //  - 5.5.1: emit inline `1 OBJE / 2 FILE / 2 FORM / 2 TITL` under
        //    the INDI record. The FILE path is the location inside the
        //    `.ancestor` archive so a receiver can resolve it.
        //  - 7.0: emit `1 OBJE @M{n}@` references; the actual record is
        //    appended at the top level once individual export completes
        //    (see MediaRegistry.exportRecords()).
        switch format.version {
        case .v5_5_1:
            for attachment in attachments {
                lines.append(contentsOf: inlineOBJELines(for: attachment))
            }
        case .v7_0:
            for attachment in attachments {
                let xref = mediaRegistry.xref(for: attachment)
                lines.append("1 OBJE \(xref)")
            }
        }

        return lines
    }

    /// Render an inline OBJE block for a single attachment (GEDCOM 5.5.1).
    /// ```
    /// 1 OBJE
    /// 2 FILE media/abc.jpg
    /// 2 FORM jpg
    /// 2 TITL Wedding photo, 1923
    /// ```
    /// `TITL` is omitted when the attachment has no caption.
    private static func inlineOBJELines(for attachment: Attachment) -> [String] {
        var out: [String] = ["1 OBJE"]
        out.append("2 FILE media/\(attachment.relativePath)")
        let form = (attachment.relativePath as NSString).pathExtension.lowercased()
        if !form.isEmpty {
            out.append("2 FORM \(form)")
        }
        if let caption = attachment.caption,
           !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("2 TITL \(caption)")
        }
        return out
    }

    /// Bucket attachments by the profile they belong to. Both
    /// `.profile(id:)` and `.fieldSource(entityID:, field:)` targets
    /// resolve to the same profile id directly. `.lifeEvent` targets
    /// resolve via the supplied `lifeEventLookup`; if that lookup is
    /// empty (caller didn't pass life events), they're skipped — matches
    /// the pre-M14 behaviour where life events were app-only storage.
    ///
    /// When `excludeSensitive` is true, attachments whose life event is
    /// flagged sensitive are dropped from the result (M14 §7.15.2).
    private static func groupAttachmentsByProfile(
        _ attachments: [Attachment],
        lifeEventLookup: [UUID: (profileID: String, sensitive: Bool)] = [:],
        excludeSensitive: Bool = false
    ) -> [String: [Attachment]] {
        var bucket: [String: [Attachment]] = [:]
        for attachment in attachments {
            let profileID: String?
            switch attachment.attachedTo {
            case .profile(let id):
                profileID = id
            case .fieldSource(let entityID, _):
                profileID = entityID
            case .lifeEvent(let lifeEventID):
                guard let entry = lifeEventLookup[lifeEventID] else {
                    profileID = nil
                    break
                }
                if excludeSensitive && entry.sensitive {
                    profileID = nil
                } else {
                    profileID = entry.profileID
                }
            }
            if let id = profileID {
                bucket[id, default: []].append(attachment)
            }
        }
        return bucket
    }

    /// Find the first `FieldSource` on the profile that carries a non-empty
    /// citation, prioritising the listed fields in order. Returns nil when
    /// no field on the profile has a citation worth emitting.
    private static func pickCitedSource(
        profile: Profile,
        preferring fields: [ProfileField]
    ) -> FieldSource? {
        for field in fields {
            guard let sources = profile.sources[field] else { continue }
            if let cited = sources.first(where: { ($0.citation?.isEmpty == false) }) {
                return cited
            }
        }
        return nil
    }

    /// Render the per-event citation block for a FieldSource. Emits nothing
    /// when no citation is present (the source identifier badge alone is
    /// not preserved in GEDCOM — only structured citations are).
    ///
    /// Output (with `baseLevel: 2`) is:
    /// ```
    /// 2 SOUR @S3@
    /// 3 PAGE Volume 7b, page 213
    /// 3 QUAY 2
    /// ```
    private static func citationLines(
        for source: FieldSource?,
        registry: CitationRegistry,
        baseLevel: Int
    ) -> [String] {
        guard let source, let citation = source.citation, !citation.isEmpty else {
            return []
        }
        let xref = registry.xref(for: citation)
        var out: [String] = ["\(baseLevel) SOUR \(xref)"]
        let pageText = pageText(from: citation)
        if !pageText.isEmpty {
            out.append("\(baseLevel + 1) PAGE \(pageText)")
        }
        if let quality = source.quality {
            out.append("\(baseLevel + 1) QUAY \(quality.rawValue)")
        }
        return out
    }

    /// Build the PAGE locator from the citation. PAGE is the per-citation
    /// "where in this source" string, so we combine `page`, `collection`,
    /// `repository` (in that order). When all are empty but we have a URL,
    /// we fall back to the URL — that way readers without `_URL` support
    /// still see something useful.
    private static func pageText(from citation: Citation) -> String {
        var parts: [String] = []
        if let page = citation.page, !page.isEmpty { parts.append(page) }
        if let collection = citation.collection, !collection.isEmpty { parts.append(collection) }
        if let repository = citation.repository, !repository.isEmpty { parts.append(repository) }
        if parts.isEmpty, let url = citation.url, !url.isEmpty {
            return url
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Family Reconstruction

    /// A reconstructed FAM record for export.
    private struct ExportFamily {
        let id: String
        let husbandID: String?
        let wifeID: String?
        let childIDs: [String]
        let marriageDate: GenealogicalDate?
    }

    /// Reconstruct FAM records from spouse + parent relationships.
    /// Each unique couple (or single parent with children) becomes one FAM.
    private static func buildFamilies(from snapshot: FamilyGraphSnapshot) -> [ExportFamily] {
        var families: [String: ExportFamily] = [:]
        var famCounter = 1

        // Process spouse relationships first — each creates a FAM
        for rel in snapshot.relationships where rel.type == .spouse {
            let key = [rel.from, rel.to].sorted().joined(separator: "+")
            if families[key] == nil {
                // Determine HUSB/WIFE by gender
                let p1 = snapshot.profiles[rel.from]
                let p2 = snapshot.profiles[rel.to]
                let husbID: String?
                let wifeID: String?
                if p1?.gender == .male {
                    husbID = rel.from
                    wifeID = rel.to
                } else if p2?.gender == .male {
                    husbID = rel.to
                    wifeID = rel.from
                } else {
                    husbID = rel.from
                    wifeID = rel.to
                }
                families[key] = ExportFamily(
                    id: "@F\(famCounter)@",
                    husbandID: husbID,
                    wifeID: wifeID,
                    childIDs: [],
                    marriageDate: rel.marriageDate
                )
                famCounter += 1
            }
        }

        // Process parent relationships — assign children to families.
        // A child may appear in multiple families (biological + step-parent).
        // Group parent edges per child, then split into pairs/singles to form FAMs.
        var childToParentEdges: [String: [Relationship]] = [:]
        for rel in snapshot.relationships where rel.type == .parent {
            childToParentEdges[rel.to, default: []].append(rel)
        }

        for (childID, parentEdges) in childToParentEdges {
            // Group parent edges into family units.
            // If parents are a couple (have a spouse edge), they're one family.
            // Otherwise each parent is a separate family unit for this child.
            let parentIDs = parentEdges.map(\.from)
            var assigned: Set<String> = []

            // First: find pairs that are spouses
            for i in 0..<parentIDs.count {
                guard !assigned.contains(parentIDs[i]) else { continue }
                for j in (i + 1)..<parentIDs.count {
                    guard !assigned.contains(parentIDs[j]) else { continue }
                    let pair = [parentIDs[i], parentIDs[j]].sorted()
                    let key = pair.joined(separator: "+")
                    if families[key] != nil {
                        // This pair has a spouse FAM — add child to it
                        let existing = families[key]!
                        var children = existing.childIDs
                        if !children.contains(childID) { children.append(childID) }
                        families[key] = ExportFamily(
                            id: existing.id, husbandID: existing.husbandID,
                            wifeID: existing.wifeID, childIDs: children,
                            marriageDate: existing.marriageDate
                        )
                        assigned.insert(parentIDs[i])
                        assigned.insert(parentIDs[j])
                    }
                }
            }

            // Second: remaining unassigned parents get their own FAM
            for parentID in parentIDs where !assigned.contains(parentID) {
                let key = parentID
                if let existing = families[key] {
                    var children = existing.childIDs
                    if !children.contains(childID) { children.append(childID) }
                    families[key] = ExportFamily(
                        id: existing.id, husbandID: existing.husbandID,
                        wifeID: existing.wifeID, childIDs: children,
                        marriageDate: existing.marriageDate
                    )
                } else {
                    let parent = snapshot.profiles[parentID]
                    let isHusb = parent?.gender != .female
                    families[key] = ExportFamily(
                        id: "@F\(famCounter)@",
                        husbandID: isHusb ? parentID : nil,
                        wifeID: isHusb ? nil : parentID,
                        childIDs: [childID],
                        marriageDate: nil
                    )
                    famCounter += 1
                }
            }
        }

        return families.values.sorted { $0.id < $1.id }
    }

    private static func exportFamily(_ family: ExportFamily) -> [String] {
        var lines: [String] = []
        lines.append("0 \(family.id) FAM")

        if let husb = family.husbandID {
            lines.append("1 HUSB \(husb)")
        }
        if let wife = family.wifeID {
            lines.append("1 WIFE \(wife)")
        }
        for childID in family.childIDs {
            lines.append("1 CHIL \(childID)")
        }
        if let date = family.marriageDate {
            lines.append("1 MARR")
            lines.append("2 DATE \(date.original)")
        }

        // Note: marriage citations are not currently surfaced on Relationship
        // (sources live on Profile.sources), so MARR has no citation block
        // at this time. When relationship-level citations land we'll attach
        // `2 SOUR @Sn@` here using the same registry helper.

        return lines
    }

    // MARK: - Helpers

    private static func formatHeaderDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date).uppercased()
    }
}

// MARK: - Media Registry

/// Collects multimedia attachments emitted during 7.0 export and assigns
/// each a stable `@M{n}@` xref. INDI records reference attachments via
/// `1 OBJE @Mn@`; the registry then emits the matching `0 @Mn@ OBJE`
/// top-level records (with FILE/FORM/TITL substructures) at the end of
/// the document, before TRLR.
///
/// In 5.5.1 mode the registry is constructed but never used — the
/// exporter emits OBJE blocks inline within INDI instead, and the
/// registry's `exportRecords()` returns an empty list.
nonisolated final class MediaRegistry {
    private var ordered: [Attachment] = []
    private var index: [UUID: Int] = [:]

    init() {}

    /// Returns the `@Mn@` xref for an attachment, registering it if new.
    func xref(for attachment: Attachment) -> String {
        if let existing = index[attachment.id] {
            return "@M\(existing)@"
        }
        let id = ordered.count + 1
        ordered.append(attachment)
        index[attachment.id] = id
        return "@M\(id)@"
    }

    /// Render the top-level OBJE records (GEDCOM 7.0).
    /// ```
    /// 0 @M1@ OBJE
    /// 1 FILE media/thomas.jpg
    /// 2 FORM jpg
    /// 1 TITL Wedding photo, 1923
    /// ```
    /// In 7.0, `FORM` is a substructure of `FILE`, so it sits at level 2.
    /// `TITL` is a sibling of `FILE` (level 1), omitted when the
    /// attachment has no caption.
    func exportRecords() -> [String] {
        var lines: [String] = []
        for (offset, attachment) in ordered.enumerated() {
            let id = offset + 1
            lines.append("0 @M\(id)@ OBJE")
            lines.append("1 FILE media/\(attachment.relativePath)")
            let form = (attachment.relativePath as NSString).pathExtension.lowercased()
            if !form.isEmpty {
                lines.append("2 FORM \(form)")
            }
            if let caption = attachment.caption,
               !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("1 TITL \(caption)")
            }
        }
        return lines
    }
}

// MARK: - Citation Registry

/// Deduplicates citations across all profiles in a snapshot and assigns each
/// a stable `@Snnn@` xref token. Emits the corresponding `0 @Sn@ SOUR`
/// records via `exportRecords()` once the rest of the document is built.
///
/// Deduplication uses `Citation`'s synthesised `Hashable`, which compares
/// every field. Two field sources whose citations differ in even one
/// character produce two distinct SOUR records — that's intentional, since
/// "FreeBMD birth index 1834" and "FreeBMD birth index 1835" really are
/// different sources.
private nonisolated final class CitationRegistry {
    private var ordered: [Citation] = []
    private var index: [Citation: Int] = [:]

    init(snapshot: FamilyGraphSnapshot) {
        for profile in snapshot.profiles.values {
            for sources in profile.sources.values {
                for source in sources {
                    guard let citation = source.citation, !citation.isEmpty else { continue }
                    register(citation)
                }
            }
        }
    }

    /// Returns the `@Sn@` xref for a citation, registering it if new.
    func xref(for citation: Citation) -> String {
        let id = register(citation)
        return "@S\(id)@"
    }

    @discardableResult
    private func register(_ citation: Citation) -> Int {
        if let existing = index[citation] { return existing }
        let id = ordered.count + 1
        ordered.append(citation)
        index[citation] = id
        return id
    }

    /// Render the SOUR records. Emits one block per registered citation.
    ///
    /// `_URL` is a non-standard tag. GEDCOM 5.5.1 has no native URL holder
    /// on SOUR; modern parsers (Gramps, MacFamilyTree, RootsMagic) accept
    /// the `_URL` extension by convention. Receivers that don't recognise
    /// it ignore it cleanly — the citation is still readable from `TITL`,
    /// `PUBL`, and `NOTE`.
    ///
    /// Long values are wrapped via GEDCOM 5.5.1 CONC/CONT continuations
    /// (see `GEDCOMLineFolder`) so receivers don't reject oversized lines.
    func exportRecords() -> [String] {
        var lines: [String] = []
        for (offset, citation) in ordered.enumerated() {
            let id = offset + 1
            lines.append("0 @S\(id)@ SOUR")

            if let collection = citation.collection, !collection.isEmpty {
                lines.append(contentsOf: GEDCOMLineFolder.fold(level: 1, tag: "ABBR", value: collection))
            }
            if let title = citation.title, !title.isEmpty {
                lines.append(contentsOf: GEDCOMLineFolder.fold(level: 1, tag: "TITL", value: title))
            } else if let collection = citation.collection, !collection.isEmpty {
                // No explicit title — collection becomes the canonical title
                // so SOUR still has something human-readable.
                lines.append(contentsOf: GEDCOMLineFolder.fold(level: 1, tag: "TITL", value: collection))
            }
            if let repository = citation.repository, !repository.isEmpty {
                // We don't model repositories as separate top-level records
                // (no REPO records emitted), so embed the repository name as
                // PUBL (publication info) — most viewers display it.
                lines.append(contentsOf: GEDCOMLineFolder.fold(level: 1, tag: "PUBL", value: repository))
            }
            if let url = citation.url, !url.isEmpty {
                // Custom tag — see method docstring.
                lines.append(contentsOf: GEDCOMLineFolder.fold(level: 1, tag: "_URL", value: url))
            }
            if let notes = citation.notes, !notes.isEmpty {
                lines.append(contentsOf: GEDCOMLineFolder.fold(level: 1, tag: "NOTE", value: notes))
            }
            if let dateAccessed = citation.dateAccessed {
                let f = DateFormatter()
                f.dateFormat = "d MMM yyyy"
                f.locale = Locale(identifier: "en_US_POSIX")
                lines.append("1 DATE \(f.string(from: dateAccessed).uppercased())")
            }
        }
        return lines
    }
}

/// GEDCOM 5.5.1 line-folder. Records are limited to 255 chars total
/// (including the leading "<level> <tag> " prefix); we use a 248-char
/// payload budget as a safe limit. Long values split across continuation
/// lines:
///
///  - `CONT` — represents a hard line break (used when the original value
///    contained `\n` characters).
///  - `CONC` — represents a no-break continuation; receivers concatenate
///    without inserting a space.
///
/// Continuations live one level deeper than the original tag: `1 NOTE foo`
/// continues with `2 CONT bar` or `2 CONC bar`.
nonisolated enum GEDCOMLineFolder {
    private static let maxPayloadPerLine = 200

    static func fold(level: Int, tag: String, value: String) -> [String] {
        let prefix = "\(level) \(tag) "
        let nextLevel = level + 1
        var output: [String] = []

        // Split the value on newlines first so each line break becomes a
        // CONT continuation. Then chunk each segment to fit the budget,
        // emitting subsequent chunks as CONC.
        let segments = value.components(separatedBy: "\n")
        for (segIndex, segment) in segments.enumerated() {
            let chunks = chunkString(segment, by: maxPayloadPerLine)
            for (chunkIndex, chunk) in chunks.enumerated() {
                if segIndex == 0 && chunkIndex == 0 {
                    output.append("\(prefix)\(chunk)")
                } else if chunkIndex == 0 {
                    // First chunk of a new line-broken segment → CONT.
                    output.append("\(nextLevel) CONT \(chunk)")
                } else {
                    // Continuation of the same logical line → CONC.
                    output.append("\(nextLevel) CONC \(chunk)")
                }
            }
            // Empty segment from a trailing or doubled newline still
            // needs a CONT to preserve the break.
            if chunks.isEmpty && segIndex > 0 {
                output.append("\(nextLevel) CONT ")
            }
        }
        return output
    }

    private static func chunkString(_ s: String, by size: Int) -> [String] {
        guard !s.isEmpty else { return [] }
        var result: [String] = []
        var index = s.startIndex
        while index < s.endIndex {
            let end = s.index(index, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            result.append(String(s[index..<end]))
            index = end
        }
        return result
    }
}
