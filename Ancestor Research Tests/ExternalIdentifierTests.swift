import Testing
import Foundation
@testable import AncestorKit
@testable import Ancestor_Research

/// Unit tests for the E1 typed external-identifier records
/// (MODEL_EVOLUTION_SPEC §Change1 / ADR-004 E1): the `externalIDs` legacy
/// projection, the deprecation-chain resolver, idempotent upsert, and the
/// full-URL guard. Pure value-type logic — no database.
nonisolated struct ExternalIdentifierTests {

    // MARK: Legacy projection round-trip (AC 4)

    @Test func legacyMapRoundTripsLosslesslyThroughRecords() {
        let legacy = ["wikitree": "Smith-123", "gedcom": "@I42@"]
        let profile = Profile(
            id: "p1", externalIDs: legacy, isDeleted: false, sources: [:], disputes: [:])

        // Every entry becomes a .primary record …
        #expect(profile.externalIdentifiers.count == 2)
        #expect(profile.externalIdentifiers.allSatisfy { $0.kind == .primary })
        // … and the projection reconstructs the original map exactly.
        #expect(profile.externalIDs == legacy)
        #expect(profile.wikiTreeID == "Smith-123")
    }

    @Test func emptyLegacyMapProducesNoRecords() {
        let profile = Profile(id: "p1", externalIDs: [:], isDeleted: false, sources: [:], disputes: [:])
        #expect(profile.externalIdentifiers.isEmpty)
        #expect(profile.externalIDs.isEmpty)
        #expect(profile.wikiTreeID == nil)
    }

    // MARK: Deprecation chain (AC 1)

    @Test func deprecatedValueResolvesToPrimaryViaChain() {
        let records: [ExternalIdentifier] = [
            ExternalIdentifier(system: "familysearch", value: "LZZZ-NEW", kind: .primary),
            ExternalIdentifier(system: "familysearch", value: "LYYY-OLD",
                               kind: .deprecated, supersededBy: "LZZZ-NEW"),
        ]
        // Look up by the deprecated value → resolves to the survivor.
        #expect(records.resolveCurrentValue(from: "LYYY-OLD", system: "familysearch") == "LZZZ-NEW")
        // The primary resolves to itself.
        #expect(records.resolveCurrentValue(from: "LZZZ-NEW", system: "familysearch") == "LZZZ-NEW")
        // The projection surfaces the primary, never the deprecated one.
        #expect(records.primaryValuesBySystem["familysearch"] == "LZZZ-NEW")
    }

    @Test func multiHopDeprecationChainResolvesToFinalSurvivor() {
        // A → B → C, only C is primary.
        let records: [ExternalIdentifier] = [
            ExternalIdentifier(system: "fs", value: "A", kind: .deprecated, supersededBy: "B"),
            ExternalIdentifier(system: "fs", value: "B", kind: .deprecated, supersededBy: "C"),
            ExternalIdentifier(system: "fs", value: "C", kind: .primary),
        ]
        #expect(records.resolveCurrentValue(from: "A", system: "fs") == "C")
        #expect(records.resolveCurrentValue(from: "B", system: "fs") == "C")
    }

    @Test func deprecatedDeadEndResolvesToNil() {
        // Merged away, survivor unknown (supersededBy nil).
        let records: [ExternalIdentifier] = [
            ExternalIdentifier(system: "fs", value: "GONE", kind: .deprecated, supersededBy: nil),
        ]
        #expect(records.resolveCurrentValue(from: "GONE", system: "fs") == nil)
        // Projection omits a system with only an unresolvable deprecated record.
        #expect(records.primaryValuesBySystem["fs"] == nil)
    }

    @Test func cyclicChainDoesNotSpinAndTerminates() {
        // Corrupt A ↔ B cycle — resolver must terminate, not hang.
        let records: [ExternalIdentifier] = [
            ExternalIdentifier(system: "fs", value: "A", kind: .deprecated, supersededBy: "B"),
            ExternalIdentifier(system: "fs", value: "B", kind: .deprecated, supersededBy: "A"),
        ]
        // Bounded walk returns *some* value rather than looping forever.
        let resolved = records.resolveCurrentValue(from: "A", system: "fs")
        #expect(resolved == "A" || resolved == "B")
    }

    // MARK: Primary + deprecated for the same system simultaneously (AC 1)

    @Test func primaryAndDeprecatedCoexistForSameSystem() {
        var records: [ExternalIdentifier] = [
            ExternalIdentifier(system: "familysearch", value: "SURVIVOR", kind: .primary),
        ]
        records = records.deprecating(system: "familysearch", value: "MERGED", supersededBy: "SURVIVOR")
        let fsRecords = records.filter { $0.system == "familysearch" }
        #expect(fsRecords.count == 2)
        #expect(fsRecords.contains { $0.kind == .primary && $0.value == "SURVIVOR" })
        #expect(fsRecords.contains { $0.kind == .deprecated && $0.value == "MERGED" })
        #expect(records.primaryValuesBySystem["familysearch"] == "SURVIVOR")
    }

    // MARK: Idempotency (AC 2)

    @Test func recordingSameSystemValueTwiceIsIdempotent() {
        var records: [ExternalIdentifier] = []
        records = records.upsertingPrimary(system: "wikitree", value: "Smith-1")
        records = records.upsertingPrimary(system: "wikitree", value: "Smith-1")
        #expect(records.count == 1)
    }

    @Test func deprecatingSameChainTwiceIsIdempotent() {
        var records: [ExternalIdentifier] = [
            ExternalIdentifier(system: "fs", value: "NEW", kind: .primary),
        ]
        records = records.deprecating(system: "fs", value: "OLD", supersededBy: "NEW")
        let afterFirst = records.count
        records = records.deprecating(system: "fs", value: "OLD", supersededBy: "NEW")
        #expect(records.count == afterFirst)
    }

    // MARK: Second ID for the same namespace

    @Test func secondIdForSameSystemPreservesBothLosslessly() {
        // Assigning a *different* value through the string-map setter must not
        // silently drop the prior one — the old dict would have. The prior
        // primary demotes to .persistent (stash-don't-destroy).
        var profile = Profile(
            id: "p1", externalIDs: ["wikitree": "Old-1"], isDeleted: false, sources: [:], disputes: [:])
        profile.externalIDs = ["wikitree": "New-2"]
        let wtRecords = profile.externalIdentifiers.filter { $0.system == "wikitree" }
        #expect(wtRecords.count == 2)
        #expect(wtRecords.contains { $0.value == "Old-1" && $0.kind == .persistent })
        #expect(wtRecords.contains { $0.value == "New-2" && $0.kind == .primary })
        // Projection now points at the new primary.
        #expect(profile.externalIDs["wikitree"] == "New-2")
    }

    // MARK: Full-URL guard (AC 3)

    @Test func fullURLValuesAreFlaggedButArkPathSegmentIsNot() {
        #expect(ExternalIdentifier.isLikelyFullURL("https://www.familysearch.org/tree/person/LZZZ-123"))
        #expect(ExternalIdentifier.isLikelyFullURL("http://wikitree.com/wiki/Smith-1"))
        #expect(ExternalIdentifier.isLikelyFullURL("www.familysearch.org/ark:/61903/1:1:XXXX"))
        // A bare ARK path segment is the *correct* stored form — not flagged.
        #expect(!ExternalIdentifier.isLikelyFullURL("ark:/61903/1:1:XXXX"))
        #expect(!ExternalIdentifier.isLikelyFullURL("Smith-123"))
        #expect(!ExternalIdentifier.isLikelyFullURL("@I42@"))
    }

    // MARK: Codable round-trip of the type itself

    @Test func externalIdentifierCodableRoundTrips() throws {
        let original = ExternalIdentifier(
            system: "familysearch", value: "LYYY-OLD",
            kind: .deprecated, supersededBy: "LZZZ-NEW",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExternalIdentifier.self, from: data)
        #expect(decoded == original)
    }

    // MARK: Profile Codable back-compat (legacy blob → records)

    @Test func profileDecodesLegacyExternalIDsBlobLosslessly() throws {
        // A Profile JSON blob authored *before* E1: carries `externalIDs`,
        // has no `externalIdentifiers` key. Must decode losslessly. `sources`
        // and `disputes` are omitted — the decoder defaults them (they are
        // dictionaries with a String-rawValue enum key, which Swift Codable
        // serialises as an unkeyed array, not a JSON object, so hand-authoring
        // them here would misrepresent the wire shape).
        let legacyBlob = """
        {"id":"p1","externalIDs":{"wikitree":"Smith-123"},"isDeleted":false}
        """
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(legacyBlob.utf8))
        #expect(decoded.wikiTreeID == "Smith-123")
        #expect(decoded.externalIdentifiers.count == 1)
        #expect(decoded.externalIdentifiers.first?.kind == .primary)
    }

    @Test func profileEncodeThenDecodeRoundTripsRecords() throws {
        let profile = Profile(
            id: "p1",
            externalIdentifiers: [
                ExternalIdentifier(system: "familysearch", value: "SURVIVOR", kind: .primary),
                ExternalIdentifier(system: "familysearch", value: "MERGED",
                                   kind: .deprecated, supersededBy: "SURVIVOR"),
            ],
            isDeleted: false, sources: [:], disputes: [:])
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded.externalIdentifiers.count == 2)
        #expect(decoded.externalIDs["familysearch"] == "SURVIVOR")
        #expect(decoded.externalIdentifiers.resolveCurrentValue(from: "MERGED", system: "familysearch") == "SURVIVOR")
    }

    // MARK: Hashable-on-id contract unchanged (blast-radius pin)

    @Test func profilesDifferingOnlyInExternalIDsRemainEqualAndHashEqual() {
        let a = Profile(id: "same", externalIDs: ["wikitree": "A-1"],
                        isDeleted: false, sources: [:], disputes: [:])
        let b = Profile(id: "same",
                        externalIdentifiers: [
                            ExternalIdentifier(system: "familysearch", value: "Z-9", kind: .primary),
                        ],
                        isDeleted: false, sources: [:], disputes: [:])
        // Identity is id-only — external identifiers must not affect it.
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        var set: Set<Profile> = [a]
        #expect(set.insert(b).inserted == false)
    }
}
