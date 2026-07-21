import Testing
import Foundation
@testable import Ancestor_Research

/// FamilySearch pivot (owner 2026-07-21): the live-handshake connection check.
/// The network call isn't unit-tested, but its two load-bearing pure parts are
/// — the authenticated endpoint URL (must hit apibeta on Beta) and the
/// users/current response parse (proves we read the signed-in identity).
struct FamilySearchConnectionTests {

    @Test func currentUserURLTargetsTheEnvironmentAPIHost() {
        #expect(FamilySearchConnection.currentUserURL(environment: .beta).absoluteString
                == "https://apibeta.familysearch.org/platform/users/current")
        #expect(FamilySearchConnection.currentUserURL(environment: .production).absoluteString
                == "https://api.familysearch.org/platform/users/current")
    }

    @Test func parsesContactNameFromUsersCurrent() {
        let json = """
        {"users":[{"id":"cis.user.MMMM-MMM","contactName":"Darryl Cauldwell","displayName":"darrylc"}]}
        """
        let user = FamilySearchConnection.parseCurrentUser(Data(json.utf8))
        #expect(user?.id == "cis.user.MMMM-MMM")
        #expect(user?.displayName == "Darryl Cauldwell")
    }

    @Test func fallsBackToDisplayNameThenID() {
        let noContact = """
        {"users":[{"id":"cis.user.X","displayName":"just_a_handle"}]}
        """
        #expect(FamilySearchConnection.parseCurrentUser(Data(noContact.utf8))?.displayName == "just_a_handle")

        let idOnly = """
        {"users":[{"id":"cis.user.Y"}]}
        """
        #expect(FamilySearchConnection.parseCurrentUser(Data(idOnly.utf8))?.displayName == "cis.user.Y")
    }

    @Test func returnsNilOnShapeMismatch() {
        #expect(FamilySearchConnection.parseCurrentUser(Data("{}".utf8)) == nil)
        #expect(FamilySearchConnection.parseCurrentUser(Data("{\"users\":[]}".utf8)) == nil)
        #expect(FamilySearchConnection.parseCurrentUser(Data("not json".utf8)) == nil)
    }

    /// Blank/whitespace names don't win over a real fallback.
    @Test func blankContactNameFallsThrough() {
        let json = """
        {"users":[{"id":"cis.user.Z","contactName":"  ","displayName":"real"}]}
        """
        #expect(FamilySearchConnection.parseCurrentUser(Data(json.utf8))?.displayName == "real")
    }
}
