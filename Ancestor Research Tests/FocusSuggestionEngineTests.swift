import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the recent-activity suggestion engine (M17.4, DESIGN.md §7.7.2).
/// Pure-function tests — no DB, no AppState, no view.
struct FocusSuggestionEngineTests {

    private func makeTransaction(
        kind: TransactionKind,
        completedAt: Date,
        profileCount: Int = 1
    ) -> Transaction {
        Transaction(
            id: UUID(),
            kind: kind,
            undoStrategy: .replay,
            startedAt: completedAt,
            completedAt: completedAt,
            changeCount: 1,
            profileCount: profileCount
        )
    }

    @Test func suggestionsEmptyWhenNoTransactions() {
        let result = FocusSuggestionEngine.suggestRecentlyActive(transactions: [])
        #expect(result.isEmpty)
    }

    @Test func singleRecentTransactionYieldsOneSuggestion() {
        let now = Date()
        let tx = makeTransaction(
            kind: .addProfile(profileID: "alice"),
            completedAt: now.addingTimeInterval(-60) // 1 min ago
        )
        let result = FocusSuggestionEngine.suggestRecentlyActive(
            transactions: [tx],
            referenceDate: now
        )
        #expect(result == ["alice"])
    }

    @Test func multipleTransactionsDeduplicateProfileIDs() {
        let now = Date()
        // alice was edited five minutes ago AND three minutes ago — should
        // appear once in the result, with the more-recent entry winning so
        // the most-recent-first ordering is honoured.
        let older = makeTransaction(
            kind: .addProfile(profileID: "alice"),
            completedAt: now.addingTimeInterval(-300)
        )
        let mid = makeTransaction(
            kind: .addProfile(profileID: "bob"),
            completedAt: now.addingTimeInterval(-200)
        )
        let newer = makeTransaction(
            kind: .resolveDispute(field: .firstName, profileID: "alice"),
            completedAt: now.addingTimeInterval(-180)
        )
        let family = makeTransaction(
            kind: .addFamily(profileIDs: ["carol", "dave", "alice"]),
            completedAt: now.addingTimeInterval(-60),
            profileCount: 3
        )
        let result = FocusSuggestionEngine.suggestRecentlyActive(
            transactions: [older, mid, newer, family],
            referenceDate: now
        )
        // family is most recent → carol/dave/alice land first (alice
        // dedupes from earlier mentions); bob picked up from the
        // remaining most-recent occurrence.
        #expect(result == ["carol", "dave", "alice", "bob"])
    }

    @Test func transactionsOutsideWindowExcluded() {
        let now = Date()
        let recent = makeTransaction(
            kind: .addProfile(profileID: "fresh"),
            completedAt: now.addingTimeInterval(-10 * 60)
        )
        let stale = makeTransaction(
            kind: .addProfile(profileID: "stale"),
            completedAt: now.addingTimeInterval(-60 * 60) // 1 hour ago
        )
        let result = FocusSuggestionEngine.suggestRecentlyActive(
            transactions: [recent, stale],
            windowMinutes: 30,
            referenceDate: now
        )
        #expect(result == ["fresh"])
        #expect(!result.contains("stale"))
    }
}
