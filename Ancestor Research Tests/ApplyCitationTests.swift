import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// Sourcing-gate fix (2026-07-15): research applies must attach the
/// record's citation to the FieldSource they write. Previously the apply
/// path carried origin only — `FieldSource.citation` stayed nil forever, so
/// the Sourcing tab's visibility gate could never fire from research and
/// per-field citations were missing from every profile surface despite
/// living in evidence_records.
@MainActor
struct ApplyCitationTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    @Test func appliedFactCarriesItsCitation() throws {
        let db = try makeDB()
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "William", lastName: "Cauldwell",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", name: "William Cauldwell",
                                 surname: "Cauldwell", givenName: "William",
                                 detailURL: "https://www.freebmd.org.uk/x", rawFields: [:]),
            deathYear: 1900, deathDate: nil, deathPlace: "Belper", age: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "143",
            spouseSurname: nil))
        let scored = ScoredRecord(id: "d1", record: record, verdict: .fact, gates: [], summary: "")

        let failures = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)
        #expect(failures.isEmpty, "apply reported failures: \(failures.map(\.what))")

        let after = try #require(try db.buildSnapshot().profiles["p1"])
        let deathSources = after.sources[.deathDate] ?? []
        #expect(deathSources.contains { $0.citation != nil },
                "the applied deathDate must carry the record's citation")
        let cite = deathSources.compactMap(\.citation).first
        #expect(cite?.url == "https://www.freebmd.org.uk/x")
        #expect(cite?.notes?.contains("FreeBMD") == true,
                "citation notes carry the rendered full citation; got \(cite?.notes ?? "nil")")

        // Mirror of AppState.sourcingTabVisible — the Sourcing tab must be
        // earnable by a research apply, not only manual citation entry.
        let anyCited = after.sources.values.contains { $0.contains { $0.citation != nil } }
        #expect(anyCited, "sourcingTabVisible predicate must fire from a research apply")
    }

    /// FreeBMD citation backfill Change 6 — when enrich-in-place heals a
    /// link-less applied FreeBMD evidence row from a linked sibling of the same
    /// GRO entry, the citation the apply already wrote onto the profile must gain
    /// the link too. Regression: Abraham Twyford's death *evidence* healed on
    /// re-research, but his deathDate/deathLocation *fact* citations stayed
    /// link-less (owner dogfood 2026-08-10) — the audit read the healed evidence
    /// while the published citation was still bare.
    @Test func enrichmentPropagatesLinkToAppliedFactCitation() throws {
        let db = try makeDB()
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "Abraham", lastName: "Twyford",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        // The applied record: 1980 Bakewell death, NO direct-entry link.
        let linkless = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d_nourl", sourceID: "freebmd", name: "Abraham Twyford",
                                 surname: "Twyford", givenName: "Abraham",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1980, deathDate: nil, deathPlace: "Bakewell", age: nil,
            quarter: "Jun", district: "Bakewell", volume: "6", page: "40", spouseSurname: nil))
        let rendered = CitationRenderer.cite(linkless)
        let linklessScored = ScoredRecord(id: "d_nourl", record: linkless, verdict: .fact, gates: [], summary: "")
        try db.saveEvidence(profileID: "p1", scored: linklessScored,
                            citationFull: rendered.full, citationURL: nil)
        try db.updateEvidenceUserStatus(
            evidenceID: EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: "d_nourl"),
            status: .savedAsLead)
        _ = ApplyEngine.applyFactToSubject(linklessScored, profile: profile, snapshot: snapshot, db: db)

        // The linked sibling: same GRO entry 6/40, WITH the direct-entry link
        // (a different index-row recordID — the case that misled the first
        // diagnosis; healing matches by vol/page, not recordID).
        let link = "https://www.freebmd.org.uk/cgi/information.pl?r=265360753:4260&d=bmd_1"
        let linked = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d_url", sourceID: "freebmd", name: "Abraham Twyford",
                                 surname: "Twyford", givenName: "Abraham",
                                 detailURL: link, rawFields: [:]),
            deathYear: 1980, deathDate: nil, deathPlace: "Bakewell", age: nil,
            quarter: "Jun", district: "Bakewell", volume: "6", page: "40", spouseSurname: nil))
        let linkedScored = ScoredRecord(id: "d_url", record: linked, verdict: .fact, gates: [], summary: "")
        try db.saveEvidence(profileID: "p1", scored: linkedScored,
                            citationFull: CitationRenderer.cite(linked).full, citationURL: link)

        // Precondition: the applied deathDate citation starts link-less.
        let before = try #require(try db.buildSnapshot().profiles["p1"])
        let beforeCite = (before.sources[.deathDate] ?? []).compactMap(\.citation).first
        #expect((beforeCite?.url ?? "").isEmpty, "applied citation should start link-less")

        // Act: the Change 3 enrich-in-place reconcile writer.
        let n = try db.reconcileFreeBMDCitationLinks(profileID: "p1")
        #expect(n >= 1, "reconcile should heal the link-less evidence row from its sibling")

        // Assert: BOTH the evidence row AND the applied fact citation now link.
        let healed = try db.loadEvidenceForProfile("p1").first { $0.sourceRecordID == "d_nourl" }
        #expect(healed?.citationURL?.contains("265360753") == true,
                "evidence row must adopt the sibling's link")

        let after = try #require(try db.buildSnapshot().profiles["p1"])
        let afterCite = (after.sources[.deathDate] ?? []).compactMap(\.citation).first
        #expect(afterCite?.url?.contains("265360753") == true,
                "the applied deathDate citation must gain the link (Change 6 propagation)")
    }

    /// Never overwrite a citation that already carries a link, and never touch a
    /// citation whose text does not fingerprint to the enriched record.
    @Test func propagationLeavesUnrelatedAndAlreadyLinkedCitationsAlone() throws {
        let db = try makeDB()
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "Abraham", lastName: "Twyford",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        // Apply a birth with an EXISTING link — must not be clobbered.
        let birth = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b1", sourceID: "freebmd", name: "Abraham Twyford",
                                 surname: "Twyford", givenName: "Abraham",
                                 detailURL: "https://www.freebmd.org.uk/keep-me", rawFields: [:]),
            birthYear: 1888, birthDate: nil, birthPlace: "Bakewell",
            quarter: "Mar", district: "Bakewell", volume: "7b", page: "738",
            mothersMaidenName: nil))
        let birthScored = ScoredRecord(id: "b1", record: birth, verdict: .fact, gates: [], summary: "")
        _ = ApplyEngine.applyFactToSubject(birthScored, profile: profile, snapshot: snapshot, db: db)

        // Propagate a DIFFERENT record's link with non-matching citation text.
        let healed = try db.propagateCitationURLToAppliedFacts(
            profileID: "p1",
            citationFull: "Some other death registration, vol. 6/40; accessed 1 Jan 2026.",
            citationURL: "https://www.freebmd.org.uk/should-not-apply")
        #expect(healed == 0, "no link-less citation fingerprints to that record")

        let after = try #require(try db.buildSnapshot().profiles["p1"])
        let birthCite = (after.sources[.birthDate] ?? []).compactMap(\.citation).first
        #expect(birthCite?.url == "https://www.freebmd.org.uk/keep-me",
                "an already-linked citation must be left untouched")
    }

    /// Retroactive heal — Abraham's actual state on 2026-08-10: the evidence row
    /// was link-healed on an earlier run, but the applied citation stayed bare.
    /// A later reconcile has no *new* cross-transcription work to do, yet must
    /// still propagate the existing evidence link onto the link-less fact.
    @Test func reconcileHealsAppliedCitationWhenEvidenceAlreadyLinked() throws {
        let db = try makeDB()
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "Abraham", lastName: "Twyford",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let rec = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", name: "Abraham Twyford",
                                 surname: "Twyford", givenName: "Abraham",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1980, deathDate: nil, deathPlace: "Bakewell", age: nil,
            quarter: "Jun", district: "Bakewell", volume: "6", page: "40", spouseSurname: nil))
        let full = CitationRenderer.cite(rec).full
        let scored = ScoredRecord(id: "d1", record: rec, verdict: .fact, gates: [], summary: "")

        // Apply the fact (link-less citation lands on the profile) …
        _ = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)
        // … then simulate the evidence row being link-healed on an earlier run,
        // WITHOUT re-rendering the applied citation.
        let link = "https://www.freebmd.org.uk/cgi/information.pl?r=265360753:4260&d=bmd_1"
        try db.saveEvidence(profileID: "p1", scored: scored, citationFull: full, citationURL: link)
        try db.updateEvidenceUserStatus(
            evidenceID: EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: "d1"),
            status: .savedAsLead)

        let before = try #require(try db.buildSnapshot().profiles["p1"])
        #expect(((before.sources[.deathDate] ?? []).compactMap(\.citation).first?.url ?? "").isEmpty,
                "precondition: applied citation is still link-less")

        _ = try db.reconcileFreeBMDCitationLinks(profileID: "p1")

        let after = try #require(try db.buildSnapshot().profiles["p1"])
        let cite = (after.sources[.deathDate] ?? []).compactMap(\.citation).first
        #expect(cite?.url?.contains("265360753") == true,
                "an already-linked evidence row must still heal its bare applied citation")
    }

    /// The same GRO registration can render with different name casing across
    /// scrapes ("WILLIAM Cauldwell" vs "WILLIAM CAULDWELL"); the fingerprint
    /// match must be case-insensitive or the heal silently misses — owner dogfood
    /// 2026-08-10: William Cauldwell's death citation stayed bare after the
    /// re-fetched evidence arrived all-caps.
    @Test func propagationMatchesCitationTextCaseInsensitively() throws {
        let db = try makeDB()
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "William", lastName: "Cauldwell",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let rec = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", name: "William Cauldwell",
                                 surname: "Cauldwell", givenName: "William",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1963, deathDate: nil, deathPlace: "Belper", age: nil,
            quarter: "Mar", district: "Belper", volume: "3A", page: "46", spouseSurname: nil))
        let scored = ScoredRecord(id: "d1", record: rec, verdict: .fact, gates: [], summary: "")
        _ = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)

        // A later scrape rendered the surname ALL-CAPS — same registration.
        let appliedNotes = CitationRenderer.cite(rec).full
        let allCaps = appliedNotes.replacingOccurrences(of: "Cauldwell", with: "CAULDWELL")
        #expect(allCaps != appliedNotes, "test setup: the casing must actually differ")

        let healed = try db.propagateCitationURLToAppliedFacts(
            profileID: "p1", citationFull: allCaps,
            citationURL: "https://www.freebmd.org.uk/cgi/information.pl?r=227323437:2671&d=bmd_1")
        #expect(healed >= 1, "a case-differing citation text must still match and heal")
        let after = try #require(try db.buildSnapshot().profiles["p1"])
        let cite = (after.sources[.deathDate] ?? []).compactMap(\.citation).first
        #expect(cite?.url?.contains("227323437") == true)
    }

    /// The Enrich button decides "healed vs nothing" purely from the reconcile
    /// RETURN value. Before the fix it counted only cross-transcription EVIDENCE
    /// reconciles (0 here) even though it propagated the link onto the bare fact
    /// citation — so the button falsely reported "no volume/page" (owner dogfood
    /// 2026-08-13: Barbara Holmes, whose one applied FreeBMD evidence row already
    /// had the link while her birthDate/birthLocation citations stayed bare). The
    /// return must now include the applied-citation propagations.
    @Test func reconcileReturnCountsAppliedCitationPropagations() throws {
        let db = try makeDB()
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "Barbara", lastName: "Holmes",
            gender: .female, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let rec = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b1", sourceID: "freebmd", name: "Barbara M Holmes",
                                 surname: "Holmes", givenName: "Barbara",
                                 detailURL: nil, rawFields: [:]),
            birthYear: 1942, birthDate: nil, birthPlace: "Belper",
            quarter: "Dec", district: "Belper", volume: "7b", page: "1019",
            mothersMaidenName: nil))
        let full = CitationRenderer.cite(rec).full
        let scored = ScoredRecord(id: "b1", record: rec, verdict: .fact, gates: [], summary: "")
        // Apply → the bare (link-less) citation lands on the profile …
        _ = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)
        // … while the SAME evidence row already carries the link (no cross-
        // transcription work to do — the case that returned 0 before the fix).
        let link = "https://www.freebmd.org.uk/cgi/information.pl?r=185815725:4503&d=bmd_1"
        try db.saveEvidence(profileID: "p1", scored: scored, citationFull: full, citationURL: link)
        try db.updateEvidenceUserStatus(
            evidenceID: EvidenceRecord.compositeID(profileID: "p1", sourceRecordID: "b1"),
            status: .savedAsLead)

        let n = try db.reconcileFreeBMDCitationLinks(profileID: "p1")
        #expect(n >= 1, "the return must count the fact-citation heal, not only cross-transcription reconciles")

        let after = try #require(try db.buildSnapshot().profiles["p1"])
        let cite = (after.sources[.birthDate] ?? []).compactMap(\.citation).first
        #expect(cite?.url?.contains("185815725") == true, "the bare citation must gain the link")
    }
}
