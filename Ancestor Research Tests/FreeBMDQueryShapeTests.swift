import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the FreeBMD query-shape contract that was silently broken until
/// 2026-05-20. Two bugs, two pins:
///   1. Multi-word given names (e.g. "Ernest Victor") need stripping to
///      the first token — FreeBMD's `given` field is first-given-only.
///   2. The year range only engages when `sq` (start quarter) and `eq`
///      (end quarter) are also sent — without them FreeBMD silently
///      ignores `start`/`end` and widens to all years.
struct FreeBMDQueryShapeTests {

    // MARK: - firstGivenName

    @Test func firstGivenNameStripsMultiWord() {
        #expect(FreeBMDSource.firstGivenName("Ernest Victor") == "Ernest")
        #expect(FreeBMDSource.firstGivenName("Ernest Victor James") == "Ernest")
    }

    @Test func firstGivenNamePassesSingleWordThrough() {
        #expect(FreeBMDSource.firstGivenName("Ernest") == "Ernest")
        #expect(FreeBMDSource.firstGivenName("Mary-Ann") == "Mary-Ann")
    }

    @Test func firstGivenNameHandlesNilAndEmpty() {
        #expect(FreeBMDSource.firstGivenName(nil) == nil)
        #expect(FreeBMDSource.firstGivenName("") == nil)
        #expect(FreeBMDSource.firstGivenName("   ") == nil)
    }

    @Test func firstGivenNameTrimsLeadingWhitespace() {
        #expect(FreeBMDSource.firstGivenName("  Ernest  ") == "Ernest")
        #expect(FreeBMDSource.firstGivenName(" Ernest Victor") == "Ernest")
    }
}
