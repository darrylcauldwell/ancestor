import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Why `ContradictoryFactsAudit` stayed quiet while Emma Gladwin held two birth
/// registrations at once (owner dogfood 2026-08-25).
///
/// The contest ran over `verdict == .fact` rows only. A record the user has
/// APPLIED is a live claim on the tree whatever the scorer last decided about
/// it — including a row an earlier exclusivity pass already demoted to `.lead`
/// — so a slot holding an applied fact beside an applied lead read as
/// UNRIVALLED and reported nothing.
///
/// Applied rows still cannot be WRITTEN by the one-click: they land in
/// `appliedHeldBack`, exactly as the applied guard requires.
struct ContradictoryFactsAppliedLeadTests {

    private func birth(_ id: String, quarter: String, year: Int, page: String) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                 surname: "GLADWIN", givenName: "EMMA",
                                 detailURL: "https://www.freebmd.org.uk/cgi/\(id)",
                                 rawFields: [:]),
            birthYear: year, quarter: quarter, district: "Belper",
            volume: "7b", page: page))
    }

    private func row(
        _ recordID: String, verdict: RecordVerdict, quarter: String, year: Int,
        page: String, appliedAt: Date? = nil
    ) -> EvidenceRecord {
        EvidenceRecord(
            id: "@EMMA@|\(recordID)", profileID: "@EMMA@", sourceID: "freebmd",
            sourceRecordID: recordID, recordType: .birth,
            verdict: verdict,
            record: birth(recordID, quarter: quarter, year: year, page: page),
            citationFull: "FreeBMD birth index, \(quarter) \(year), Belper, 7b/\(page)",
            citationURL: nil,
            scoredAt: Date(timeIntervalSince1970: 0), userStatus: .unreviewed,
            appliedAt: appliedAt,
            gates: [GateResult(gate: .name, outcome: .pass, reason: "surname=1.00")],
            summary: "birth \(quarter) \(year)")
    }

    private let applied = Date(timeIntervalSince1970: 100)

    @Test func anAppliedLeadContestsItsSlot() {
        let evidence = [
            row("b513", verdict: .fact, quarter: "Dec", year: 1867, page: "513",
                appliedAt: applied),
            row("b515", verdict: .lead, quarter: "Dec", year: 1865, page: "515",
                appliedAt: applied),
        ]
        let finding = ContradictoryFactsAudit.finding(
            profileID: "@EMMA@", profileName: "Emma Gladwin",
            evidence: evidence, profile: nil)

        #expect(finding != nil, "two registrations on one birth is a contradiction")
        #expect(Set(finding?.demotions.map(\.sourceRecordID) ?? []) == ["b513", "b515"])
        #expect(finding?.demotable.isEmpty == true,
                "both are on the tree — choosing between them is the user's call")
        #expect(finding?.appliedHeldBack.count == 2)
    }

    /// The narrowing that keeps this from re-opening settled slots: a lead
    /// nobody applied, with no exclusivity marker, still proves nothing.
    @Test func anUnappliedLeadStillDoesNotContest() {
        let evidence = [
            row("b513", verdict: .fact, quarter: "Dec", year: 1867, page: "513",
                appliedAt: applied),
            row("b515", verdict: .lead, quarter: "Dec", year: 1865, page: "515"),
        ]
        #expect(ContradictoryFactsAudit.finding(
            profileID: "@EMMA@", profileName: "Emma Gladwin",
            evidence: evidence, profile: nil) == nil)
    }

    /// Index twins of ONE registration are one candidate, not rivals — the
    /// elevation must not turn a re-indexed row into a phantom contradiction.
    @Test func anAppliedLeadTwinOfTheAppliedFactIsNotARival() {
        let evidence = [
            row("b513", verdict: .fact, quarter: "Dec", year: 1867, page: "513",
                appliedAt: applied),
            row("b513-alt", verdict: .lead, quarter: "Dec", year: 1867, page: "513",
                appliedAt: applied),
        ]
        #expect(ContradictoryFactsAudit.demotions(in: evidence, profile: nil).isEmpty)
    }
}
