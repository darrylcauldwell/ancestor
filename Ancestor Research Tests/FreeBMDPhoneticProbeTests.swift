import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// FT-06 verification probe — env-gated LIVE test (2 search requests).
///
/// The FT-06 FIX (omit `Phonetic` unless enabling) is correct under BOTH
/// possible server interpretations, so it ships without waiting on a probe.
/// This probe VERIFIES the two things the fix assumes:
///   1. Omitting the field (strict, post-fix) returns EXACT matches only.
///   2. `Phonetic=true` (loose) actually ENABLES soundex — i.e. it widens
///      to differently-spelled soundex siblings.
/// If (2) holds and (1) is exact-only, the strict/loose distinction — which
/// the old `Phonetic=false`-on-strict silently collapsed if search.pl uses
/// checkbox-presence semantics — is genuinely restored.
///
///   env TEST_RUNNER_RUN_FREEBMD_PHONETIC_PROBE=1 xcodebuild test … \
///     -parallel-testing-enabled NO \
///     -only-testing:"Ancestor Research Tests/FreeBMDPhoneticProbeTests"
///
/// Surname with a soundex sibling: "Cauldwell" ↔ "Caldwell" (both C443),
/// both present in Derbyshire, so soundex must pull "Caldwell" into a
/// "Cauldwell" search. Prints findings; asserts only that the requests
/// succeed and that loose ⊇ strict (soundex can only widen).
@MainActor
struct FreeBMDPhoneticProbeTests {

    private func surnames(_ records: [SourceRecord]) -> Set<String> {
        var out: Set<String> = []
        for r in records {
            if case .birth(let b) = r, let s = b.common.surname, !s.isEmpty {
                out.insert(s.lowercased())
            }
        }
        return out
    }

    @Test func loosePhoneticWidensToSoundexSiblings() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FREEBMD_PHONETIC_PROBE"] == "1" else {
            return // gated off — no live traffic
        }
        func run(_ strictness: SearchStrictness) async -> [SourceRecord] {
            let query = RecordQuery(
                surname: "Cauldwell", givenName: nil, recordType: .birth,
                yearFrom: 1860, yearTo: 1900, gender: nil, region: nil,
                sourceParams: .freeBMD(FreeBMDParams(
                    districtCode: nil,
                    countyCode: RegionConfig.freeBMDCountyID(forChapmanCode: "DBY"),
                    wildcardSurname: false
                )),
                strictness: strictness
            )
            return await FreeBMDSource().search(query).records
        }

        let strict = await run(.strict)   // post-fix: Phonetic OMITTED
        let loose = await run(.loose)     // Phonetic=true

        let sStrict = surnames(strict), sLoose = surnames(loose)
        print("PROBE strict (omitted):   \(strict.count) rows, surnames=\(sStrict.sorted())")
        print("PROBE loose (sndx=on): \(loose.count) rows, surnames=\(sLoose.sorted())")

        let strictIsExactOnly = sStrict.allSatisfy { $0.contains("cauldwell") }
        let looseHasSoundexSibling = sLoose.contains { $0.contains("caldwell") && !$0.contains("cauldwell") }
        print("PROBE VERDICT: strict-exact-only=\(strictIsExactOnly), loose-pulls-soundex-sibling=\(looseHasSoundexSibling)")
        print("PROBE: if both true, FT-06 fix restores the strict/loose distinction and sndx=on is the correct enable value.")

        #expect(!strict.isEmpty, "baseline exact query returned nothing")
        #expect(loose.count >= strict.count, "soundex (loose) must not return fewer rows than exact (strict)")
    }
}
