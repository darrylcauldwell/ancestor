import Foundation
import os

/// Bundled lookup of surname transcription variants, used by the dispatcher
/// when fanning out a query at `SearchStrictness.variant`.
///
/// Loaded once from `Resources/surname-variants.json` (~30 seed entries).
/// Keys are canonical lowercase surnames; values are lowercase variant arrays
/// **excluding** the canonical form itself. Lookup is case-insensitive;
/// unknown surnames return an empty variant list — the dispatcher's variant
/// fan-out becomes a single-query no-op for those.
///
/// See RESEARCH_AXES_SPEC §7 and §8 Change 5.
nonisolated final class SurnameVariants: Sendable {
    static let shared = SurnameVariants()

    let map: [String: [String]]

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "SurnameVariants"
    )

    private init() {
        guard let url = Bundle.main.url(
            forResource: "surname-variants",
            withExtension: "json"
        ) else {
            Self.logger.error("surname-variants.json not found in bundle")
            self.map = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var parsed: [String: [String]] = [:]
            for (key, value) in raw {
                if let arr = value as? [String] { parsed[key.lowercased()] = arr.map { $0.lowercased() } }
            }
            self.map = parsed
            Self.logger.info("Loaded \(self.map.count) surname-variant entries")
        } catch {
            Self.logger.error("Failed to load surname-variants.json: \(error.localizedDescription)")
            self.map = [:]
        }
    }

    /// Variants for a given surname, excluding the surname itself. Empty array
    /// if the surname has no entry in the dictionary — callers can branch on
    /// `isEmpty` to short-circuit a variant fan-out.
    func variants(of surname: String) -> [String] {
        map[surname.lowercased()] ?? []
    }
}
