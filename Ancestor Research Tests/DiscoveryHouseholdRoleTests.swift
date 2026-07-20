import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// DiscoveryExtractor role re-mapping — census roster roles are recorded
/// relative to the HEAD of household, so when the subject is a child in the
/// household the raw labels are wrong ("add my brother as my son"). Reproduces
/// William Cauldwell's 1891 household (William is a Son; John Henry/Robert are
/// his brothers, not his sons). No real family data beyond names.
struct DiscoveryHouseholdRoleTests {

    private func profile(_ id: String, first: String?, last: String?) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private let household = [
        HouseholdMember(name: "John CAULDWELL", relationship: "Head", sex: "M"),
        HouseholdMember(name: "Elizabeth CAULDWELL", relationship: "Wife", sex: "F"),
        HouseholdMember(name: "William CAULDWELL", relationship: "Son", sex: "M", isTarget: true),
        HouseholdMember(name: "Robert CAULDWELL", relationship: "Son", sex: "M"),
    ]

    @Test func findsSubjectRoleViaTargetFlag() {
        let william = profile("w", first: "William", last: "Cauldwell")
        #expect(DiscoveryExtractor.subjectHouseholdRole(household, subject: william) == "son")
    }

    @Test func findsSubjectRoleViaNameWhenNoTargetFlag() {
        let noFlag = [
            HouseholdMember(name: "John CAULDWELL", relationship: "Head"),
            HouseholdMember(name: "William CAULDWELL", relationship: "Son"),
        ]
        let william = profile("w", first: "William", last: "Cauldwell")
        #expect(DiscoveryExtractor.subjectHouseholdRole(noFlag, subject: william) == "son")
    }

    /// The bug: a fellow "Son" must become the subject's BROTHER, not son.
    @Test func fellowSonBecomesBrother() {
        let r = DiscoveryExtractor.relativeToSubject("Son", subjectRole: "son", memberSex: "M")
        #expect(r?.label == "brother")
        #expect(r?.isSibling == true)
    }

    @Test func fellowDaughterBecomesSister() {
        let r = DiscoveryExtractor.relativeToSubject("Daughter", subjectRole: "son", memberSex: "F")
        #expect(r?.label == "sister")
        #expect(r?.isSibling == true)
    }

    /// The Head is the subject's father; the Wife is the subject's mother.
    @Test func headAndWifeBecomeParents() {
        #expect(DiscoveryExtractor.relativeToSubject("Head", subjectRole: "son", memberSex: "M")?.label == "father")
        #expect(DiscoveryExtractor.relativeToSubject("Wife", subjectRole: "son", memberSex: "F")?.label == "mother")
    }

    /// When the subject IS the head, roles already read correctly → no re-map.
    @Test func noRemapWhenSubjectIsHead() {
        #expect(DiscoveryExtractor.relativeToSubject("Son", subjectRole: "head", memberSex: "M") == nil)
        #expect(DiscoveryExtractor.relativeToSubject("Wife", subjectRole: "head", memberSex: "F") == nil)
    }

    /// In-laws / grandparents are too ambiguous to re-map — left alone.
    @Test func inLawsAreNotRemapped() {
        #expect(DiscoveryExtractor.relativeToSubject("Mother-in-law", subjectRole: "son", memberSex: "F") == nil)
        #expect(DiscoveryExtractor.relativeToSubject("Son-in-law", subjectRole: "son", memberSex: "M") == nil)
    }

    /// Unknown subject role (subject not found in roster) → conservative, no re-map.
    @Test func noRemapWhenSubjectRoleUnknown() {
        #expect(DiscoveryExtractor.relativeToSubject("Son", subjectRole: nil, memberSex: "M") == nil)
    }

    // MARK: - addKind (actionable edge kind)

    @Test func addKindWhenSubjectIsChild() {
        #expect(DiscoveryExtractor.addKind(memberRole: "Son", subjectRole: "son") == .sibling)
        #expect(DiscoveryExtractor.addKind(memberRole: "Daughter", subjectRole: "son") == .sibling)
        #expect(DiscoveryExtractor.addKind(memberRole: "Head", subjectRole: "son") == .parent)
        #expect(DiscoveryExtractor.addKind(memberRole: "Wife", subjectRole: "son") == .parent)
        #expect(DiscoveryExtractor.addKind(memberRole: "Mother-in-law", subjectRole: "son") == nil)
    }

    @Test func addKindWhenSubjectIsHead() {
        #expect(DiscoveryExtractor.addKind(memberRole: "Son", subjectRole: "head") == .child)
        #expect(DiscoveryExtractor.addKind(memberRole: "Wife", subjectRole: "head") == .spouse)
        #expect(DiscoveryExtractor.addKind(memberRole: "Father", subjectRole: "head") == .parent)
        #expect(DiscoveryExtractor.addKind(memberRole: "Son-in-law", subjectRole: "head") == nil)
    }
}
