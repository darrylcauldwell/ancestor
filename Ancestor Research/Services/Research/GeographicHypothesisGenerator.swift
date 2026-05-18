import Foundation

/// One weighted guess about where a subject was likely registered for a life event
/// (typically birth). Output of `GeographicHypothesisGenerator`.
///
/// `signals` records the human-readable reasons that contributed weight to this
/// candidate so the UI can show "we think she was born in Belper because…" and
/// the user can confirm, override, or contradict.
nonisolated struct GeographicHypothesis: Sendable, Hashable {
    /// Canonical district name as it appears in FreeBMD's catalogue (title-cased).
    let districtName: String
    /// FreeBMD code for this district (used to drive a targeted query).
    let districtCode: String
    /// Chapman code of the historical county that owns this district.
    let chapmanCode: String
    /// Aggregated prior weight, clamped to [0, 1]. Sum of signal contributions
    /// rather than a probability — interpret as a relative ranking score.
    let weight: Double
    /// One human-readable line per contributing signal, in the order they fired.
    let signals: [String]
}

/// Pure inference engine that walks the family graph and proposes likely
/// registration districts for a subject's birth (or other locatable event).
///
/// The pipeline historically only used `Profile.birthLocation` directly. When
/// that field is unset — common for older or partially-known profiles — the
/// geography gate has no anchor and any in-county candidate passes. This
/// generator closes that gap by treating the *tree's* known locations as
/// hypotheses: the subject's own marriage location, their children's birth
/// locations, parents' marriage locations, and so on.
///
/// Output is a ranked list — the caller (`HypothesisEngine`) decides whether
/// any candidate is strong enough to act on. The generator never asserts a
/// district as fact; it produces falsifiable hypotheses that downstream tests
/// either corroborate (one record matches the predicted district uniquely) or
/// contradict (best evidence is outside the predicted district).
///
/// Year-awareness: when `eventYear` is supplied, parish→district lookups are
/// constrained to districts that were operating in that year. This matters for
/// boundary changes — Wirksworth parish was in Bakewell RD pre-1937 and Belper
/// RD from 1937 onwards; the lookup must pick the right one.
nonisolated enum GeographicHypothesisGenerator {

    /// Compute weighted district hypotheses for the given subject.
    ///
    /// - Parameters:
    ///   - subjectID: profile id of the subject. Must exist in `snapshot`.
    ///   - snapshot: family graph to walk for context signals.
    ///   - eventYear: year of the event being located (typically the subject's
    ///     birth year). Drives year-aware parish→district lookup and is used to
    ///     decay signals whose own year is far from this one. Pass nil to skip
    ///     year filtering — the generator will still work but may pick the
    ///     wrong RD for parishes that moved between districts.
    /// - Returns: hypotheses sorted by descending weight. Empty if no usable
    ///   geographic signal exists anywhere in the subject's surrounding graph.
    static func inferDistricts(
        for subjectID: String,
        snapshot: FamilyGraphSnapshot,
        eventYear: Int? = nil
    ) -> [GeographicHypothesis] {
        guard let subject = snapshot.profiles[subjectID] else { return [] }

        var votes: [DistrictKey: VoteAccumulator] = [:]

        // Signal 1 — subject's own birth location, if known directly.
        // This is the answer if set; we still emit it as a hypothesis so the
        // engine treats every source uniformly.
        addLocationSignal(
            location: subject.birthLocation,
            locationCode: subject.birthLocationCode,
            year: subject.birthDate?.earliest ?? eventYear,
            weight: 1.0,
            reason: "Subject's own birth location: \(subject.birthLocation ?? "")",
            eventYear: eventYear,
            into: &votes
        )

        // Signal 2 — subject's own marriage location. A 1969 Belper marriage is
        // strong evidence the subject lived in or near Belper RD around 1969,
        // which transitively makes Belper RD a plausible birth district.
        for rel in snapshot.relationships
        where rel.type == .spouse && (rel.from == subjectID || rel.to == subjectID) {
            addLocationSignal(
                location: rel.marriageLocation,
                locationCode: rel.marriageLocationCode,
                year: rel.marriageDate?.earliest,
                weight: 0.75,
                reason: marriageReason(rel: rel, snapshot: snapshot, subjectID: subjectID),
                eventYear: eventYear,
                into: &votes
            )
        }

        // Signal 3 — children's birth locations. Parents are usually present at
        // the registration district of their child's birth; this corroborates
        // the parent's likely home district at that point in time.
        let children = snapshot.childrenOf(subjectID)
        for child in children {
            addLocationSignal(
                location: child.birthLocation,
                locationCode: child.birthLocationCode,
                year: child.birthDate?.earliest,
                weight: 0.55,
                reason: "Child \(child.displayName) born in \(child.birthLocation ?? "")",
                eventYear: eventYear,
                into: &votes
            )
        }

        // Signal 4 — siblings' birth locations. Same parents → usually same
        // registration district, modulo migration between children.
        for sibling in snapshot.siblingsOf(subjectID) {
            addLocationSignal(
                location: sibling.birthLocation,
                locationCode: sibling.birthLocationCode,
                year: sibling.birthDate?.earliest,
                weight: 0.65,
                reason: "Sibling \(sibling.displayName) born in \(sibling.birthLocation ?? "")",
                eventYear: eventYear,
                into: &votes
            )
        }

        // Signal 5 — parents' marriage location. Parents usually marry near
        // where they go on to register children — moderate weight, drops off
        // when the marriage is decades before the subject's birth.
        let parents = snapshot.parentsOf(subjectID)
        for parent in parents {
            for rel in snapshot.relationships
            where rel.type == .spouse && (rel.from == parent.id || rel.to == parent.id) {
                addLocationSignal(
                    location: rel.marriageLocation,
                    locationCode: rel.marriageLocationCode,
                    year: rel.marriageDate?.earliest,
                    weight: 0.50,
                    reason: "Parent \(parent.displayName) married in \(rel.marriageLocation ?? "")",
                    eventYear: eventYear,
                    into: &votes
                )
            }
        }

        // Signal 6 — spouse's own birth location. Assortative mating means
        // people often marry locally, but lots of long-distance moves too.
        for spouse in snapshot.spousesOf(subjectID) {
            addLocationSignal(
                location: spouse.birthLocation,
                locationCode: spouse.birthLocationCode,
                year: spouse.birthDate?.earliest,
                weight: 0.35,
                reason: "Spouse \(spouse.displayName) born in \(spouse.birthLocation ?? "")",
                eventYear: eventYear,
                into: &votes
            )
        }

        return votes
            .map { (key, acc) in
                GeographicHypothesis(
                    districtName: key.districtName,
                    districtCode: key.districtCode,
                    chapmanCode: key.chapmanCode,
                    weight: min(1.0, acc.weight),
                    signals: acc.signals
                )
            }
            .sorted { $0.weight > $1.weight }
    }

    // MARK: - Internals

    /// Stable key for accumulating votes. Uses district code (FreeBMD's
    /// unique numeric id) so two different name spellings collapse correctly.
    private struct DistrictKey: Hashable {
        let districtName: String
        let districtCode: String
        let chapmanCode: String
    }

    private struct VoteAccumulator {
        var weight: Double = 0
        var signals: [String] = []
    }

    private static func addLocationSignal(
        location: String?,
        locationCode: String?,
        year: Int?,
        weight: Double,
        reason: String,
        eventYear: Int?,
        into votes: inout [DistrictKey: VoteAccumulator]
    ) {
        let resolved = resolveDistricts(
            location: location,
            locationCode: locationCode,
            year: year
        )
        guard !resolved.isEmpty else { return }

        let baseWeight = weight * yearDecay(from: year, to: eventYear)
        guard baseWeight > 0 else { return }

        // When a parish appears in multiple districts (Wirksworth sits in both
        // Bakewell and Belper RDs at different periods), split the vote rather
        // than picking one arbitrarily. Other corroborating signals are what
        // promote the correct district to the top of the ranking.
        let effectiveWeight = baseWeight / Double(resolved.count)
        for district in resolved {
            let key = DistrictKey(
                districtName: district.name,
                districtCode: district.code,
                chapmanCode: district.chapmanCode ?? ""
            )
            votes[key, default: VoteAccumulator()].weight += effectiveWeight
            votes[key, default: VoteAccumulator()].signals.append(reason)
        }
    }

    /// Confidence multiplier based on how far the signal year is from the event
    /// year. Same-year signals get 1.0; ±10 years fades to ~0.7; ±30 years to
    /// ~0.3. No decay if either year is missing.
    private static func yearDecay(from signalYear: Int?, to eventYear: Int?) -> Double {
        guard let signalYear, let eventYear else { return 1.0 }
        let gap = Double(abs(signalYear - eventYear))
        // Smooth exponential decay — half-life ≈ 25 years.
        return pow(0.5, gap / 25.0)
    }

    /// Translate a free-text location (and optional structured code) into the
    /// candidate FreeBMD registration districts that cover it in the given
    /// year. May return multiple districts when a parish appears in more than
    /// one RD's parish list (typically because boundary changes moved it over
    /// time). Returns empty when the input can't be mapped at all.
    private static func resolveDistricts(
        location: String?,
        locationCode: String?,
        year: Int?
    ) -> [FreeBMDDistrict] {
        let catalogue = FreeBMDDistrictCatalogue.shared

        // Path 1 — structured "DBY:Wirksworth" code.
        if let code = locationCode, let parsed = parseLocationCode(code) {
            let yearScoped: [FreeBMDDistrict]
            if let year {
                yearScoped = catalogue.covering(years: year...year)
            } else {
                yearScoped = catalogue.all()
            }
            let parishLower = parsed.place.lowercased()
            let chapmanUpper = parsed.chapman.uppercased()
            let parishMatches = yearScoped.filter { d in
                d.chapmanCode?.uppercased() == chapmanUpper
                    && (d.parishes?.contains(where: { $0.lowercased() == parishLower }) ?? false)
            }
            if !parishMatches.isEmpty { return parishMatches }
            // Maybe the place IS the district name (e.g. "DBY:Belper")
            if let direct = catalogue.district(named: parsed.place) {
                return [direct]
            }
        }

        // Path 2 — free-text location.
        guard let raw = location?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return [] }

        if let direct = catalogue.district(named: raw) {
            return [direct]
        }

        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let parishPart = parts.first,
           let direct = catalogue.district(named: parishPart) {
            return [direct]
        }
        // Future: when only free text is provided, look up parts.last as a
        // county name via uk-chapman-codes.json and run the parish search.

        return []
    }

    private static func parseLocationCode(_ code: String) -> (chapman: String, place: String)? {
        let parts = code.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let chapman = parts[0].trimmingCharacters(in: .whitespaces)
        let place = parts[1].trimmingCharacters(in: .whitespaces)
        guard !chapman.isEmpty, !place.isEmpty else { return nil }
        return (chapman, place)
    }

    private static func marriageReason(
        rel: Relationship,
        snapshot: FamilyGraphSnapshot,
        subjectID: String
    ) -> String {
        let location = rel.marriageLocation ?? ""
        if let year = rel.marriageDate?.earliest {
            return "Subject married in \(location), \(year)"
        }
        return "Subject married in \(location)"
    }
}
