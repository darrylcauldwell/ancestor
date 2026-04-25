import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the Evidence Firewall — validates that findings are properly
/// checked before reaching the 4-gate scorer.
struct EvidenceFirewallTests {

    private func makeFinding(
        field: String = "birthDate",
        value: String = "6 April 1834",
        sourceURL: String = "https://freereg.org.uk/test",
        evidenceText: String = "Thomas son of William Land, bpt 6 April 1834"
    ) -> PendingFact {
        PendingFact(
            id: "test", profileID: "test-profile",
            field: field, value: value,
            sourceURL: sourceURL, sourceTitle: "Test Source",
            evidenceText: evidenceText,
            reasoning: "test", confidence: "high",
            agentID: "test", submittedAt: Date(),
            verificationStatus: .pending
        )
    }

    // MARK: - Rule 2: URL Required

    @Test func emptyURLRejected() async {
        let finding = makeFinding(sourceURL: "")
        let result = await EvidenceFirewall.validate(
            finding: finding, existingCitedURLs: [],
            profileBirthYear: nil, profileDeathYear: nil
        )
        #expect(result != nil)
        #expect(result!.contains("no source URL"))
    }

    // MARK: - Rule 2: Blocked URLs

    @Test func socialMediaBlocked() async {
        let finding = makeFinding(sourceURL: "https://www.facebook.com/groups/genealogy")
        let result = await EvidenceFirewall.validate(
            finding: finding, existingCitedURLs: [],
            profileBirthYear: nil, profileDeathYear: nil
        )
        #expect(result != nil)
        #expect(result!.contains("social media"))
    }

    @Test func aiSiteBlocked() async {
        let finding = makeFinding(sourceURL: "https://chatgpt.com/share/abc123")
        let result = await EvidenceFirewall.validate(
            finding: finding, existingCitedURLs: [],
            profileBirthYear: nil, profileDeathYear: nil
        )
        #expect(result != nil)
        #expect(result!.contains("AI-generated"))
    }

    // MARK: - Rule 5: Source Tier Registry

    @Test func freeregURLGetsTranscriptionTier() {
        let tier = SourceTierRegistry.lookup(url: "https://www.freereg.org.uk/search_records/123")
        #expect(tier.trustTier == .transcription)
        #expect(tier.directness == .directTranscription)
    }

    @Test func cwgcURLGetsPrimaryTier() {
        let tier = SourceTierRegistry.lookup(url: "https://www.cwgc.org/find-records/find-war-dead/casualty-details/123")
        #expect(tier.trustTier == .primary)
    }

    @Test func unknownURLGetsDefaultTier() {
        let tier = SourceTierRegistry.lookup(url: "https://obscure-genealogy-site.example.com/records")
        #expect(tier.trustTier == .community)
        #expect(tier.directness == .derivative)
    }

    @Test func restrictedSourceDetected() {
        #expect(SourceTierRegistry.isRestricted(url: "https://www.ancestry.co.uk/records/123"))
        #expect(!SourceTierRegistry.isRestricted(url: "https://www.freereg.org.uk/records/123"))
    }

    // MARK: - Rule 6: Hallucination Detection

    @Test func futureYearRejected() async {
        let finding = makeFinding(value: "born 2099")
        let result = await EvidenceFirewall.validate(
            finding: finding, existingCitedURLs: [],
            profileBirthYear: nil, profileDeathYear: nil
        )
        #expect(result != nil)
        #expect(result!.contains("date sanity"))
    }

    @Test func ancientYearRejected() async {
        let finding = makeFinding(value: "born 1200")
        let result = await EvidenceFirewall.validate(
            finding: finding, existingCitedURLs: [],
            profileBirthYear: nil, profileDeathYear: nil
        )
        #expect(result != nil)
        #expect(result!.contains("date sanity"))
    }

    @Test func deathBeforeBirthRejected() async {
        let finding = makeFinding(field: "deathDate", value: "1820")
        let result = await EvidenceFirewall.validate(
            finding: finding, existingCitedURLs: [],
            profileBirthYear: 1834, profileDeathYear: nil
        )
        #expect(result != nil)
        #expect(result!.contains("temporal impossibility"))
    }

    @Test func marriageAtAge3Rejected() async {
        let finding = makeFinding(field: "marriageDate", value: "1837")
        let result = await EvidenceFirewall.validate(
            finding: finding, existingCitedURLs: [],
            profileBirthYear: 1834, profileDeathYear: nil
        )
        #expect(result != nil)
        #expect(result!.contains("temporal impossibility"))
    }

    @Test func validFindingPasses() async {
        let finding = makeFinding()
        let result = await EvidenceFirewall.validate(
            finding: finding, existingCitedURLs: [],
            profileBirthYear: 1834, profileDeathYear: 1890
        )
        #expect(result == nil) // nil = passed
    }

    // MARK: - §13: Idempotency

    @Test func idempotencyKeyIsDeterministic() {
        let key1 = EvidenceFirewall.idempotencyKey(
            profileID: "abc", field: "birthDate", value: "1834", sourceURL: "https://example.com"
        )
        let key2 = EvidenceFirewall.idempotencyKey(
            profileID: "abc", field: "birthDate", value: "1834", sourceURL: "https://example.com"
        )
        #expect(key1 == key2)
    }

    @Test func differentContentProducesDifferentKeys() {
        let key1 = EvidenceFirewall.idempotencyKey(
            profileID: "abc", field: "birthDate", value: "1834", sourceURL: "https://example.com"
        )
        let key2 = EvidenceFirewall.idempotencyKey(
            profileID: "abc", field: "birthDate", value: "1835", sourceURL: "https://example.com"
        )
        #expect(key1 != key2)
    }
}
