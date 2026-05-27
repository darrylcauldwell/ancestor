import Foundation

/// A proposal that the engine has detected enough cross-source agreement
/// to confidently narrow a subject's birth year. Output of
/// `BirthYearConsensusDetector.detect`.
///
/// Pure data. Slice A only logs these for verification; slice B2 will
/// route them through `pending_facts` so the user reviews them with the
/// supporting-evidence preview visible.
nonisolated struct BirthYearConsensus: Sendable {

    /// Discriminator for how prominently the UI should surface a
    /// proposal. Reflects how rich the cross-source evidence is —
    /// not the engine's certainty that the year is *correct* (the
    /// 4-gate scorer still owns that question). Per
    /// `SUBJECT_SELF_NARROWING_SPEC.md` §3.5.
    nonisolated enum ConfidenceTier: String, Sendable {
        /// ≥4 supporting records (plus the MUST floor of ≥2 sources
        /// and ≥1 location-aligned). Renders with one-click Apply.
        case high
        /// Floor met (≥3 records, ≥2 sources, ≥1 location-aligned)
        /// but below the High threshold. Renders quieter — no
        /// auto-apply button; user is routed to the manual cleanse
        /// flow so they evaluate evidence in context.
        case medium
    }

    /// The single birth year the cluster agrees on.
    let proposedBirthYear: Int
    let confidence: ConfidenceTier
    /// How many records support this year within ±1.
    let agreeingRecordCount: Int
    /// Distinct sourceIDs across supporting records. Floor is 2.
    let distinctSourceCount: Int
    /// One supporting-evidence row per record. Slice B3 renders the
    /// list inline in the review surface (§3.4) so the user can audit
    /// for off-by-one census drift or unrelated records sneaking in.
    let supportingEvidence: [SupportingEvidence]
}

/// One supporting record's contribution to a `BirthYearConsensus`.
/// Carries enough metadata for the review surface to render a
/// human-readable bullet ("Birth Q4 1883 Belper 7b/631 (FreeBMD)")
/// and for slice B2 to persist the link to `scored_records` rows.
nonisolated struct SupportingEvidence: Sendable {
    /// `SourceRecord.id` — joins back to `scored_records.record_id`.
    let recordID: String
    /// `SourceRecord.sourceID` — drives the source-diversity guard
    /// and the parenthetical attribution in the UI.
    let sourceID: String
    /// Short human label of the underlying record shape, e.g.
    /// "Birth Q4 1883", "Census 1891 age 7", "Burial".
    let typeLabel: String
    /// Birth year this record implies. Already in the ±1 window of
    /// the consensus year — the renderer can show "implies 1883" or
    /// "implies 1884" so off-by-one drifts surface to the user.
    let yearImplied: Int
    /// Any place field the record carries. Nil when the record's
    /// shape has no location data (rare). Drives the locality guard
    /// and renders as the bullet's location suffix.
    let location: String?
    /// True when this record's location overlaps with the subject's
    /// known birth/death location per the locality guard (§3.2).
    /// At least one supporter must have this true for the consensus
    /// to surface at all.
    let isLocationAligned: Bool
}

/// Slice A — detects "this subject's birth year window is wide AND the
/// scored records cluster on a single year" without needing the 4-gate
/// scorer to promote any single record to `.fact`. Closes the
/// chicken-and-egg loop where a wide birth window prevents any one BMD
/// record from being confidently anchored, which in turn keeps the
/// window wide forever.
///
/// Determinism contract: this is rule-driven, not MLX-driven. It looks
/// at typed record fields, buckets implied years, applies the
/// `SUBJECT_SELF_NARROWING_SPEC.md` §3 guards, and returns the result.
/// No model involvement.
nonisolated enum BirthYearConsensusDetector {

    /// Subject birth-window spans tighter than this are considered
    /// already-anchored — narrowing doesn't help and we don't fire.
    private static let wideSpanThreshold: Int = 5

    /// Floor for the MUST §3.0 record count.
    private static let minAgreement: Int = 3

    /// Floor for the MUST §3.1 source-diversity guard.
    private static let minDistinctSources: Int = 2

    /// Threshold for promotion from Medium to High tier (§3.5).
    /// Above this many records *and* the other MUSTs already passed,
    /// the cluster is confident enough for the one-click Apply UI.
    private static let highTierRecordThreshold: Int = 4

    /// Returns a `BirthYearConsensus` when the scored records cluster
    /// strongly enough to surface as a profile-update proposal. Returns
    /// nil when the subject's window is already tight, when no
    /// year-bearing cluster reaches the floor, or when any MUST guard
    /// (§3.0 record count, §3.1 source diversity, §3.2 locality) fails.
    static func detect(
        in scored: [ScoredRecord],
        for subject: ResearchSubject
    ) -> BirthYearConsensus? {
        if let from = subject.birthYearFrom, let to = subject.birthYearTo,
           to - from <= wideSpanThreshold {
            return nil
        }

        let evidence = collectEvidence(from: scored, subject: subject)
        guard evidence.count >= minAgreement else { return nil }

        guard let (anchorYear, supporters) = strongestCluster(in: evidence) else {
            return nil
        }

        // MUST §3.0 — record count floor.
        guard supporters.count >= minAgreement else { return nil }

        // MUST §3.1 — source diversity. Multiple records from the same
        // source (e.g. 4 FreeCen census ages) often trace back to a
        // single underlying birth registration. Counting them as
        // independent confirmations is the classic false-positive mode.
        let distinctSources = Set(supporters.map(\.sourceID))
        guard distinctSources.count >= minDistinctSources else { return nil }

        // MUST §3.2 — locality alignment. At least one supporter must
        // overlap with the subject's known birth/death location.
        // Closes the "right surname + year, wrong region" gap.
        guard supporters.contains(where: \.isLocationAligned) else { return nil }

        let tier: BirthYearConsensus.ConfidenceTier =
            supporters.count >= highTierRecordThreshold ? .high : .medium

        return BirthYearConsensus(
            proposedBirthYear: anchorYear,
            confidence: tier,
            agreeingRecordCount: supporters.count,
            distinctSourceCount: distinctSources.count,
            supportingEvidence: supporters
        )
    }

    // MARK: - Evidence collection

    /// Pulls implied birth years out of every typed record shape we
    /// know how to read. Skips records with verdict `.impossible`.
    private static func collectEvidence(
        from scored: [ScoredRecord],
        subject: ResearchSubject
    ) -> [SupportingEvidence] {
        var out: [SupportingEvidence] = []
        let subjectPlaces = subjectKnownPlaceTokens(subject)
        for s in scored where s.verdict != .impossible {
            guard let entry = supportingEvidence(
                for: s.record,
                subjectPlaceTokens: subjectPlaces
            ) else { continue }
            out.append(entry)
        }
        return out
    }

    /// Per-record-shape extractor. Returns nil when the record shape
    /// carries no usable birth-year signal (marriage, parish without
    /// a baptism year, etc.).
    private static func supportingEvidence(
        for record: SourceRecord,
        subjectPlaceTokens: Set<String>
    ) -> SupportingEvidence? {
        switch record {
        case .birth(let r):
            guard let y = r.birthYear else { return nil }
            let location = r.birthPlace ?? r.district
            return SupportingEvidence(
                recordID: record.id,
                sourceID: record.sourceID,
                typeLabel: "Birth \(y)",
                yearImplied: y,
                location: location,
                isLocationAligned: tokensOverlap(
                    location, subjectPlaceTokens
                )
            )

        case .census(let r):
            let impliedYear: Int?
            if let direct = r.birthYear {
                impliedYear = direct
            } else if let age = r.age {
                impliedYear = r.censusYear - age
            } else {
                impliedYear = nil
            }
            guard let y = impliedYear else { return nil }
            let location = r.parish ?? r.district ?? r.address
            return SupportingEvidence(
                recordID: record.id,
                sourceID: record.sourceID,
                typeLabel: "Census \(r.censusYear) age \(r.age.map(String.init) ?? "?")",
                yearImplied: y,
                location: location,
                isLocationAligned: tokensOverlap(
                    location, subjectPlaceTokens
                )
            )

        case .burial(let r):
            guard let y = r.birthYear else { return nil }
            let location = r.burialLocation ?? r.birthPlace ?? r.cemetery
            return SupportingEvidence(
                recordID: record.id,
                sourceID: record.sourceID,
                typeLabel: "Burial",
                yearImplied: y,
                location: location,
                isLocationAligned: tokensOverlap(
                    location, subjectPlaceTokens
                )
            )

        case .death(let r):
            guard let d = r.deathYear, let a = r.age else { return nil }
            let location = r.deathPlace ?? r.district
            return SupportingEvidence(
                recordID: record.id,
                sourceID: record.sourceID,
                typeLabel: "Death \(d) age \(a)",
                yearImplied: d - a,
                location: location,
                isLocationAligned: tokensOverlap(
                    location, subjectPlaceTokens
                )
            )

        case .probate(let r):
            guard let d = r.deathYear, let a = r.ageAtDeath else { return nil }
            let location = r.address ?? r.registry
            return SupportingEvidence(
                recordID: record.id,
                sourceID: record.sourceID,
                typeLabel: "Probate \(d) age \(a)",
                yearImplied: d - a,
                location: location,
                isLocationAligned: tokensOverlap(
                    location, subjectPlaceTokens
                )
            )

        case .pedigree(let r):
            guard let y = r.birthYear else { return nil }
            return SupportingEvidence(
                recordID: record.id,
                sourceID: record.sourceID,
                typeLabel: "Pedigree",
                yearImplied: y,
                location: r.location,
                isLocationAligned: tokensOverlap(
                    r.location, subjectPlaceTokens
                )
            )

        case .military, .marriage, .parish:
            return nil
        }
    }

    // MARK: - Clustering

    /// Finds the year (± 1) with the most supporting evidence. The ±1
    /// fuzziness lets 1883 and 1884 cluster — common across BMD
    /// quarter boundaries, census-age rounding, and burial age drift.
    /// Returns nil when no candidate year exists.
    private static func strongestCluster(
        in evidence: [SupportingEvidence]
    ) -> (year: Int, supporters: [SupportingEvidence])? {
        var bucket: [Int: [SupportingEvidence]] = [:]
        for e in evidence {
            bucket[e.yearImplied, default: []].append(e)
        }
        var best: (year: Int, supporters: [SupportingEvidence])?
        for candidate in bucket.keys {
            let combined = (candidate - 1 ... candidate + 1)
                .flatMap { bucket[$0] ?? [] }
            if combined.count > (best?.supporters.count ?? 0) {
                best = (candidate, combined)
            }
        }
        return best
    }

    // MARK: - Locality alignment (§3.2)

    /// Subject's known place tokens, lowercased and stripped of common
    /// noise words. Drawn from `region` (birth location) and
    /// `deathLocation`. Empty when the subject is a placeholder with
    /// no location data — which by spec §3.2 means we can't verify
    /// alignment and the proposal won't surface.
    private static func subjectKnownPlaceTokens(
        _ subject: ResearchSubject
    ) -> Set<String> {
        var raw: [String] = []
        if case let .county(name) = subject.region { raw.append(name) }
        if let dl = subject.deathLocation { raw.append(dl) }
        return Set(raw.flatMap(tokenize))
    }

    /// Token-overlap check between a record's location string and the
    /// subject's known tokens. Lowercased, comma/whitespace-tokenised,
    /// common noise words (county, country) filtered. Returns false
    /// when either side has no usable tokens.
    private static func tokensOverlap(
        _ recordLocation: String?,
        _ subjectTokens: Set<String>
    ) -> Bool {
        guard let recordLocation, !subjectTokens.isEmpty else { return false }
        let recordTokens = Set(tokenize(recordLocation))
        return !recordTokens.intersection(subjectTokens).isEmpty
    }

    /// Lowercases, splits on commas and whitespace, removes country-
    /// and county-level noise tokens that are too broad to anchor
    /// identity. Pragmatic and tunable — names below county
    /// (parish/town/district) are what we want to match on.
    private static let noiseTokens: Set<String> = [
        "england", "wales", "scotland", "ireland", "uk",
        "united", "kingdom", "great", "britain", "british",
        "the", "of", "and", "in", "on", "at", "near",
        // County-level — too broad on their own. A subject in
        // Derbyshire and a record citing only "Derbyshire" with no
        // town isn't meaningfully aligned.
        "derbyshire", "yorkshire", "lancashire", "nottinghamshire",
        "staffordshire", "lincolnshire", "cheshire", "leicestershire",
    ]

    private static func tokenize(_ raw: String) -> [String] {
        raw.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ", \t\n").union(.punctuationCharacters))
            .filter { !$0.isEmpty && !noiseTokens.contains($0) }
    }
}
