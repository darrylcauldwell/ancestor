import Testing
import Foundation
@testable import Ancestor_Research

/// Regression tests for the LinkAwareNoteText flow (M17.8). The view
/// itself isn't unit-tested — these cover the parser and resolver that
/// drive its output. The picker for ambiguous matches is implemented
/// inside `LinkAwareNoteText` via an `.alert` (binary) plus a
/// `.confirmationDialog` (3+); verifying that surface lives in the
/// ProfileLinkParser test file. These tests pin the behaviours the
/// view depends on so a regression in either layer is caught.
struct LinkAwareNoteTests {

    private func makeProfile(
        id: String,
        firstName: String?,
        lastName: String?,
        isDeleted: Bool = false
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: nil,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: isDeleted, sources: [:], disputes: [:]
        )
    }

    private func snapshot(_ profiles: [Profile]) -> FamilyGraphSnapshot {
        var dict: [String: Profile] = [:]
        for p in profiles { dict[p.id] = p }
        return FamilyGraphSnapshot(profiles: dict, relationships: [])
    }

    @Test func parserExtractsBracketedNames() {
        // Mixed prose: leading text, two link markers, trailing text. The
        // parser should emit the markers as link tokens regardless of
        // whether they resolve.
        let snap = snapshot([])
        let tokens = ProfileLinkParser.parse(
            "Spoke to [[Alice Smith]] yesterday and [[Bob Jones]] today.",
            snapshot: snap
        )
        // Filter to just the link tokens — order-preserving.
        let names: [String] = tokens.compactMap { token in
            if case .link(let displayName, _) = token { return displayName }
            return nil
        }
        #expect(names == ["Alice Smith", "Bob Jones"])
    }

    @Test func resolverReturnsExactMatchProfile() {
        let alice = makeProfile(id: "alice-id", firstName: "Alice", lastName: "Smith")
        let snap = snapshot([alice])
        let candidates = ProfileLinkParser.candidates(
            for: "Alice Smith",
            snapshot: snap
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.id == "alice-id")

        // The parser's resolved-ID path mirrors the candidates count of 1.
        let tokens = ProfileLinkParser.parse("[[Alice Smith]]", snapshot: snap)
        #expect(tokens == [.link(displayName: "Alice Smith", profileID: "alice-id")])
    }

    @Test func resolverReturnsMultipleCandidatesWhenAmbiguous() {
        // Two profiles share an exact display name — the picker should be
        // surfaced (parser returns nil profileID, resolver returns both).
        let mary1 = makeProfile(id: "mary-1880", firstName: "Mary", lastName: "Smith")
        let mary2 = makeProfile(id: "mary-1910", firstName: "Mary", lastName: "Smith")
        let snap = snapshot([mary1, mary2])

        let candidates = ProfileLinkParser.candidates(
            for: "Mary Smith",
            snapshot: snap
        )
        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.id)) == Set(["mary-1880", "mary-1910"]))

        let tokens = ProfileLinkParser.parse("Met [[Mary Smith]] today", snapshot: snap)
        // Ambiguous → token carries displayName with nil profileID; the
        // view layer reads `candidates(for:snapshot:)` itself when the
        // user taps and routes into the disambiguation picker.
        #expect(tokens.contains(.link(displayName: "Mary Smith", profileID: nil)))
    }

    @Test func resolverReturnsEmptyWhenNoMatch() {
        let snap = snapshot([
            makeProfile(id: "x", firstName: "Alice", lastName: "Smith")
        ])
        // A name that doesn't exist in the tree.
        let candidates = ProfileLinkParser.candidates(
            for: "Nonexistent Person",
            snapshot: snap
        )
        #expect(candidates.isEmpty)

        // The parser still emits the link token (with nil profileID) so
        // the view can render the dangling reference visibly. Soft-deleted
        // profiles also count as no-match — we sanity-check that here.
        let withDeleted = snapshot([
            makeProfile(id: "alive", firstName: "Alice", lastName: "Smith"),
            makeProfile(id: "dead", firstName: "Ghost", lastName: "User", isDeleted: true)
        ])
        let ghostCandidates = ProfileLinkParser.candidates(
            for: "Ghost User",
            snapshot: withDeleted
        )
        #expect(ghostCandidates.isEmpty)
    }
}
