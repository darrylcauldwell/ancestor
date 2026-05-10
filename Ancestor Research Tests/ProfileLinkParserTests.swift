import Testing
import Foundation
@testable import Ancestor_Research

struct ProfileLinkParserTests {

    // MARK: - Fixtures

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

    // MARK: - parse()

    @Test func plainTextEmitsSingleTextToken() {
        let snap = snapshot([])
        let tokens = ProfileLinkParser.parse("Just some plain prose.", snapshot: snap)
        #expect(tokens == [.text("Just some plain prose.")])
    }

    @Test func emptyStringEmitsEmptyArray() {
        let snap = snapshot([])
        let tokens = ProfileLinkParser.parse("", snapshot: snap)
        #expect(tokens.isEmpty)
    }

    @Test func uniqueLinkResolvesToProfileID() {
        let p = makeProfile(id: "abc-123", firstName: "Thomas", lastName: "Land")
        let snap = snapshot([p])
        let tokens = ProfileLinkParser.parse("Talked to [[Thomas Land]] today", snapshot: snap)
        #expect(tokens.count == 3)
        #expect(tokens[0] == .text("Talked to "))
        #expect(tokens[1] == .link(displayName: "Thomas Land", profileID: "abc-123"))
        #expect(tokens[2] == .text(" today"))
    }

    @Test func ambiguousLinkLeavesProfileIDNil() {
        let p1 = makeProfile(id: "id-1", firstName: "Thomas", lastName: "Land")
        let p2 = makeProfile(id: "id-2", firstName: "Thomas", lastName: "Land")
        let snap = snapshot([p1, p2])
        let tokens = ProfileLinkParser.parse("[[Thomas Land]]", snapshot: snap)
        #expect(tokens.count == 1)
        #expect(tokens[0] == .link(displayName: "Thomas Land", profileID: nil))

        let candidates = ProfileLinkParser.candidates(for: "Thomas Land", snapshot: snap)
        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.id)) == Set(["id-1", "id-2"]))
    }

    @Test func unknownNameLinkHasNilIDAndZeroCandidates() {
        let snap = snapshot([makeProfile(id: "x", firstName: "Alice", lastName: "Smith")])
        let tokens = ProfileLinkParser.parse("Ref [[Unknown Person]]", snapshot: snap)
        #expect(tokens.count == 2)
        #expect(tokens[0] == .text("Ref "))
        #expect(tokens[1] == .link(displayName: "Unknown Person", profileID: nil))

        let candidates = ProfileLinkParser.candidates(for: "Unknown Person", snapshot: snap)
        #expect(candidates.isEmpty)
    }

    @Test func multipleLinksInOneStringAllParse() {
        let alice = makeProfile(id: "a", firstName: "Alice", lastName: "Jones")
        let bob = makeProfile(id: "b", firstName: "Bob", lastName: "Smith")
        let snap = snapshot([alice, bob])
        let tokens = ProfileLinkParser.parse("From [[Alice Jones]] and [[Bob Smith]] both.", snapshot: snap)
        #expect(tokens == [
            .text("From "),
            .link(displayName: "Alice Jones", profileID: "a"),
            .text(" and "),
            .link(displayName: "Bob Smith", profileID: "b"),
            .text(" both.")
        ])
    }

    @Test func adjacentLinksHaveNoTextTokenBetween() {
        let a = makeProfile(id: "a", firstName: "A", lastName: nil)
        let b = makeProfile(id: "b", firstName: "B", lastName: nil)
        let snap = snapshot([a, b])
        let tokens = ProfileLinkParser.parse("[[A]][[B]]", snapshot: snap)
        #expect(tokens.count == 2)
        #expect(tokens[0] == .link(displayName: "A", profileID: "a"))
        #expect(tokens[1] == .link(displayName: "B", profileID: "b"))
    }

    @Test func malformedUnmatchedBracketsTreatedAsText() {
        let snap = snapshot([])
        let tokens = ProfileLinkParser.parse("[[unmatched", snapshot: snap)
        #expect(tokens == [.text("[[unmatched")])
    }

    @Test func singleBracketIsPlainText() {
        let snap = snapshot([])
        let tokens = ProfileLinkParser.parse("Just [one bracket]", snapshot: snap)
        #expect(tokens == [.text("Just [one bracket]")])
    }

    @Test func emptyMarkerEmitsAsText() {
        let snap = snapshot([])
        let tokens = ProfileLinkParser.parse("Saw [[]] here", snapshot: snap)
        // Regex requires at least one non-`]` character inside the brackets,
        // so `[[]]` doesn't match — the whole string is plain text.
        #expect(tokens == [.text("Saw [[]] here")])
    }

    @Test func whitespaceOnlyMarkerHandledGracefully() {
        let snap = snapshot([])
        let tokens = ProfileLinkParser.parse("Saw [[   ]] here", snapshot: snap)
        // Inner content is whitespace-only — trimmed name is empty so we
        // emit the original marker text rather than a broken link.
        #expect(tokens == [.text("Saw "), .text("[[   ]]"), .text(" here")])
    }

    // MARK: - candidates()

    @Test func candidatesIsCaseInsensitive() {
        let p = makeProfile(id: "x", firstName: "Thomas", lastName: "Land")
        let snap = snapshot([p])
        #expect(ProfileLinkParser.candidates(for: "thomas land", snapshot: snap).count == 1)
        #expect(ProfileLinkParser.candidates(for: "THOMAS LAND", snapshot: snap).count == 1)
    }

    @Test func candidatesTrimsWhitespace() {
        let p = makeProfile(id: "x", firstName: "Thomas", lastName: "Land")
        let snap = snapshot([p])
        #expect(ProfileLinkParser.candidates(for: "  Thomas Land  ", snapshot: snap).count == 1)
        #expect(ProfileLinkParser.candidates(for: "\tThomas Land\n", snapshot: snap).count == 1)
    }

    @Test func candidatesExcludesSoftDeleted() {
        let alive = makeProfile(id: "alive", firstName: "Thomas", lastName: "Land", isDeleted: false)
        let dead = makeProfile(id: "dead", firstName: "Thomas", lastName: "Land", isDeleted: true)
        let snap = snapshot([alive, dead])
        let result = ProfileLinkParser.candidates(for: "Thomas Land", snapshot: snap)
        #expect(result.count == 1)
        #expect(result.first?.id == "alive")
    }

    @Test func parseDeduplicatesViaSoftDeleteSoSingleResolves() {
        // If one of two same-named profiles is soft-deleted, the link should
        // resolve uniquely to the survivor rather than be reported ambiguous.
        let alive = makeProfile(id: "alive", firstName: "Thomas", lastName: "Land", isDeleted: false)
        let dead = makeProfile(id: "dead", firstName: "Thomas", lastName: "Land", isDeleted: true)
        let snap = snapshot([alive, dead])
        let tokens = ProfileLinkParser.parse("[[Thomas Land]]", snapshot: snap)
        #expect(tokens == [.link(displayName: "Thomas Land", profileID: "alive")])
    }
}
