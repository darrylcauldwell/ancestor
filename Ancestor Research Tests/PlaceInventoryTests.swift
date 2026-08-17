import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// LOCATION_MODEL_SPEC Part III, Slice A — the scored place inventory.
///
/// The property that matters most is the last one: **nothing may score high
/// that cannot be justified**. Ruth Brailsford's "Middleton, Derbyshire"
/// silently became Bakewell RD — a district that did not exist at her 1824
/// birth — and nothing surfaced it. A score that reads "high" for a row with
/// four rival Middletons would reintroduce exactly that failure.
@MainActor
struct PlaceInventoryTests {

    private func profile(
        id: String, name: String = "Test", birth: String? = nil,
        birthLocation: String?, birthCode: String? = nil
    ) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: name, lastName: "Person",
                gender: .female, attributes: nil,
                birthDate: birth.map { GenealogicalDate(parsing: $0) } ?? nil,
                birthLocation: birthLocation, birthLocationCode: birthCode,
                deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func row(_ rows: [PlaceInventory.Row], _ text: String) -> PlaceInventory.Row? {
        rows.first { $0.text == text }
    }

    // MARK: - The acceptance case

    /// Ruth Brailsford, born "Middleton, Derbyshire" in 1824. Derbyshire alone
    /// has four Middletons; the app used to answer Bakewell RD, which began in
    /// 1839. This row must NOT read as confident.
    @Test func ruthsMiddletonScoresLowAndSaysWhy() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "ruth", name: "Ruth", birth: "1824", birthLocation: "Middleton, Derbyshire")
        ])
        guard let middleton = row(rows, "Middleton, Derbyshire") else {
            Issue.record("Middleton row missing"); return
        }
        #expect(middleton.confidence < .high,
                "rival Middletons must not read as confident — got \(middleton.confidence.label): \(middleton.reasons)")
        #expect(middleton.placeNames.count > 1,
                "the rival settlements must be counted, not collapsed: \(middleton.placeNames)")
        #expect(middleton.reasons.contains { $0.contains("share this name") },
                "the rivals must be named, not just scored: \(middleton.reasons)")
    }

    /// Bakewell RD began in 1839. It must not be *offered* for an 1824 birth —
    /// and must not silently vanish either, or the one remaining answer looks
    /// like a discovery rather than the last one standing.
    @Test func anImpossibleDistrictIsEliminatedAndShownAsEliminated() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "ruth", birth: "1824", birthLocation: "Middleton, Derbyshire")
        ])
        guard let middleton = row(rows, "Middleton, Derbyshire") else {
            Issue.record("Middleton row missing"); return
        }
        #expect(!middleton.candidates.contains { $0.id.contains("Bakewell") },
                "Bakewell RD (from 1839) cannot hold an 1824 event — offered \(middleton.candidates.map(\.id))")
        #expect(middleton.eliminated.contains { $0.district.name == "Bakewell" && $0.reason == "began 1839" },
                "elimination must be visible: \(middleton.eliminated.map { "\($0.district.name) \($0.reason)" })")
        #expect(middleton.reasons.contains { $0.contains("Ruled out") && $0.contains("1839") },
                "and stated in words: \(middleton.reasons)")
    }

    /// Civil registration began in July 1837. Naming a district for an earlier
    /// event is a geographic approximation, and saying so costs one line.
    @Test func preRegistrationEventsSayTheDistrictIsOnlyALocator() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "p", birth: "1824", birthLocation: "Youlgreave, Derbyshire")
        ])
        #expect(row(rows, "Youlgreave, Derbyshire")?.reasons
            .contains { $0.contains("predates civil registration") } == true)
    }

    /// One settlement filed under two districts across the 1974 reorganisation
    /// is not ambiguity. Counting districts would call Warslow contested and
    /// Middleton certain — exactly backwards.
    @Test func oneSettlementUnderSuccessiveDistrictsIsNotAmbiguous() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "p", birth: "1861", birthLocation: "Warslow, Staffordshire")
        ])
        #expect(row(rows, "Warslow, Staffordshire")?.placeNames.count == 1,
                "got \(row(rows, "Warslow, Staffordshire")?.placeNames ?? [])")
    }

    // MARK: - The scoring contract

    @Test func anUnambiguousCountyStatedPlaceScoresHigh() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "p", birth: "1861", birthLocation: "Warslow, Staffordshire")
        ])
        let warslow = row(rows, "Warslow, Staffordshire")
        #expect(warslow?.confidence == .high,
                "single candidate + county stated + first segment matched — got \(warslow?.confidence.label ?? "nil"): \(warslow?.reasons ?? [])")
    }

    /// A hamlet the catalogue lacks resolves only through a WIDER segment. That
    /// is useful, but the user must be told the precise place is still unknown
    /// rather than believing Alport itself was found.
    @Test func aHamletResolvedViaItsParishSaysSo() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "p", birth: "1861", birthLocation: "Alport, Youlgreave, Derbyshire")
        ])
        guard let alport = row(rows, "Alport, Youlgreave, Derbyshire") else {
            Issue.record("row missing"); return
        }
        #expect(alport.matchedSegment?.caseInsensitiveCompare("Youlgreave") == .orderedSame)
        #expect(alport.confidence < .high, "the hamlet itself was not matched")
        #expect(alport.reasons.contains { $0.contains("Alport") },
                "must name the segment that failed: \(alport.reasons)")
    }

    @Test func atrulyUnknownPlaceIsUnresolvedNotLow() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "p", birthLocation: "Darley Hall")
        ])
        #expect(row(rows, "Darley Hall")?.confidence == .unresolved)
    }

    // MARK: - Grouping and ordering

    @Test func oneStringUsedBySeveralPeopleIsOneRow() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "a", birth: "1861", birthLocation: "Middleton, Derbyshire"),
            profile(id: "b", birth: "1870", birthLocation: "Middleton, Derbyshire"),
        ])
        let middleton = row(rows, "Middleton, Derbyshire")
        #expect(middleton?.occurrences.count == 2)
        #expect(middleton?.profileCount == 2, "so the UI can say what is at stake")
    }

    /// The list is ordered so the work is at the top.
    @Test func theListSortsLeastConfidentFirst() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "a", birth: "1861", birthLocation: "Warslow, Staffordshire"),
            profile(id: "b", birthLocation: "Darley Hall"),
            profile(id: "c", birth: "1824", birthLocation: "Middleton, Derbyshire"),
        ])
        let order = rows.map(\.confidence)
        #expect(order == order.sorted(), "rows must ascend by confidence — got \(rows.map { "\($0.text)=\($0.confidence.label)" })")
        #expect(rows.first?.confidence == .unresolved)
    }

    /// Era elimination uses the EARLIEST year any occurrence carries — the
    /// narrowest constraint available, so a district ruled out for one use is
    /// not quietly offered because another use is later.
    @Test func eraFilteringUsesTheNarrowestConstraint() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "early", birth: "1824", birthLocation: "Taddington, Derbyshire"),
            profile(id: "late", birth: "1890", birthLocation: "Taddington, Derbyshire"),
        ])
        let candidates = row(rows, "Taddington, Derbyshire")?.candidates.map(\.id) ?? []
        #expect(!candidates.contains { $0.contains("Bakewell") },
                "1824 is the binding constraint; Bakewell RD began 1839 — offered \(candidates)")
    }

    // MARK: - Bound rows

    @Test func anAlreadyBoundFieldNeedsNoDecision() {
        let rows = PlaceInventory.build(profiles: [
            profile(id: "p", birth: "1824", birthLocation: "Middleton, Derbyshire",
                    birthCode: "DBY:Ashbourne-RD")
        ])
        #expect(row(rows, "Middleton, Derbyshire")?.needsDecision == false,
                "a field the user already bound must leave the queue")
    }

    @Test func softDeletedProfilesAreExcluded() {
        var deleted = profile(id: "gone", birthLocation: "Warslow, Staffordshire")
        deleted.isDeleted = true
        #expect(PlaceInventory.build(profiles: [deleted]).isEmpty)
    }

    // MARK: - The property that matters

    /// Swept over the whole live-tree corpus: no row may claim high confidence
    /// while offering rival districts. This is the regression guard for the
    /// Bakewell failure — a confident-looking wrong answer is worse than none,
    /// because nothing downstream flags it.
    @Test func nothingScoresHighWithRivalCandidates() {
        let profiles = GazetteerTreeCoverageTests.treeLocations.enumerated().map {
            profile(id: "p\($0.offset)", birth: "1861", birthLocation: $0.element)
        }
        let offenders = PlaceInventory.build(profiles: profiles)
            .filter { $0.confidence == .high && ($0.placeNames.count > 1 || $0.candidates.count > 1) }
            .map { "\($0.text) → places \($0.placeNames), districts \($0.candidates.map(\.name))" }
        #expect(offenders.isEmpty, "high confidence with rivals:\n\(offenders.joined(separator: "\n"))")
    }
}
