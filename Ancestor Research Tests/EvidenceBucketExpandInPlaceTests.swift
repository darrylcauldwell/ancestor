import Testing
@testable import Ancestor_Research

/// SC-1 follow-up (review C8). The ledger's research buckets (researched /
/// you-rejected / scorer-rejected) cap at 20 rows, and the overflow button
/// used to open the pending-facts sheet — a DIFFERENT queue (the firewall's
/// `pending_facts`), which never lists these scored records and shows "No
/// Pending Findings" when that queue is empty. Rows past the cap were
/// unreachable from the very button that promised them ("review all →"); the
/// rejected buckets' tails had no view path at all. The affordance now
/// expands the bucket in place; `EvidenceBucketDisplay` is that decision
/// extracted from the view so the behaviour is pinned here.
struct EvidenceBucketExpandInPlaceTests {

    /// The core C8 repair: asking for the rest reveals EVERY row of this
    /// bucket — there is no other surface the tail can be read on.
    @Test func showAllRevealsEveryRow() {
        #expect(EvidenceBucketDisplay.visibleCount(total: 60, showAll: true) == 60)
    }

    /// The bounded default is unchanged: a bucket past the cap shows the cap.
    @Test func bucketStaysCappedUntilAsked() {
        #expect(EvidenceBucketDisplay.visibleCount(total: 60, showAll: false)
            == EvidenceBucketDisplay.cap)
        #expect(EvidenceBucketDisplay.visibleCount(total: 5, showAll: false) == 5)
    }

    /// The affordance appears exactly while rows are hidden — never on a
    /// bucket within the cap, never after it has been expanded.
    @Test func affordanceShowsOnlyWhileRowsAreHidden() {
        #expect(EvidenceBucketDisplay.showsExpandAffordance(total: 60, showAll: false))
        #expect(!EvidenceBucketDisplay.showsExpandAffordance(total: 60, showAll: true))
        #expect(!EvidenceBucketDisplay.showsExpandAffordance(total: 20, showAll: false))
        #expect(!EvidenceBucketDisplay.showsExpandAffordance(total: 5, showAll: false))
    }
}
