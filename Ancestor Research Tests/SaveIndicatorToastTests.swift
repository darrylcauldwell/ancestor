import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the manual-save toast trigger (M17.5, DESIGN.md §7.5.15).
struct SaveIndicatorToastTests {

    @Test func triggerFiresAtThreeManualTransactions() {
        // Below the threshold — silent.
        #expect(!SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: true, hasShown: false, transactionCount: 0
        ))
        #expect(!SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: true, hasShown: false, transactionCount: 2
        ))
        // At and above the threshold — fires.
        #expect(SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: true, hasShown: false, transactionCount: 3
        ))
        #expect(SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: true, hasShown: false, transactionCount: 50
        ))
        // Non-manual / large projects never see the guidance toast.
        #expect(!SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: false, hasShown: false, transactionCount: 99
        ))
    }

    @Test func triggerSuppressedAfterFirstShow() {
        // Once `hasShown` is true the trigger is permanently silent for
        // this user — no matter how many more actions they perform.
        #expect(!SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: true, hasShown: true, transactionCount: 3
        ))
        #expect(!SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: true, hasShown: true, transactionCount: 10
        ))
        #expect(!SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: true, hasShown: true, transactionCount: 1000
        ))
    }
}
