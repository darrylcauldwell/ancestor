import Testing
import Foundation
@testable import Ancestor_Research

/// The father/son guard on profile merge — the protection that stops a
/// "possible duplicate" false positive from re-creating a patronymic muddle.
struct MergeSafetyTests {

    private func profile(_ id: String, name: String, birth: Int? = nil) -> Profile {
        Profile(
            id: id, firstName: name, lastName: "Cauldwell",
            birthDate: birth.map { GenealogicalDate(parsing: String($0)) },
            isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func parentEdge(parent: String, child: String) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent, role: .father,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    @Test func matchingBirthYearsIsOk() {
        // The Geoffrey Wheeldon case: two copies, same birth year → safe.
        let a = profile("a", name: "Geoffrey", birth: 1855)
        let b = profile("b", name: "Geoffrey", birth: 1855)
        #expect(MergeSafety.assess(left: a, right: b, relationships: []) == .ok)
    }

    @Test func divergentBirthYearsWarns() {
        let a = profile("a", name: "Ernest", birth: 1887)
        let b = profile("b", name: "Ernest", birth: 1920)
        if case .warn(let reason) = MergeSafety.assess(left: a, right: b, relationships: []) {
            #expect(reason.contains("Birth years differ"))
        } else {
            Issue.record("expected a warning for divergent birth years")
        }
    }

    @Test func directParentChildIsBlocked() {
        // If the two are already linked father→son, merging is impossible.
        let father = profile("f", name: "Ernest", birth: 1887)
        let son = profile("s", name: "Ernest", birth: 1919)
        let rels = [parentEdge(parent: "f", child: "s")]
        if case .blocked = MergeSafety.assess(left: father, right: son, relationships: rels) {
            // expected
        } else {
            Issue.record("parent/child pair must be blocked from merging")
        }
    }

    @Test func divergentParentsWarnsWhenUndated() {
        // The Ernest stub case shape: one has parent William, the other a
        // different parent; neither dated → warn (may be father/son).
        let a = profile("a", name: "Ernest")               // stub, no birth
        let b = profile("b", name: "Ernest")
        let rels = [parentEdge(parent: "william", child: "a"),
                    parentEdge(parent: "someone", child: "b")]
        if case .warn = MergeSafety.assess(left: a, right: b, relationships: rels) {
            // expected
        } else {
            Issue.record("divergent parents on undated profiles must warn")
        }
    }

    @Test func oneDatedOneStubWarns() {
        // Ernest b.1887 vs a dateless Ernest stub → can't confirm same person.
        let dated = profile("d", name: "Ernest", birth: 1887)
        let stub = profile("s", name: "Ernest")
        if case .warn = MergeSafety.assess(left: dated, right: stub, relationships: []) {
            // expected
        } else {
            Issue.record("a dated-vs-undated pair must warn")
        }
    }

    @Test func twoDatelessStubsAreOk() {
        let a = profile("a", name: "Mabel")
        let b = profile("b", name: "Mabel")
        #expect(MergeSafety.assess(left: a, right: b, relationships: []) == .ok)
    }
}
