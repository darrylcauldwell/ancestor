import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the registrable-host equivalence rules used by both the
/// crawler (link following) and the add-corpus verifier (same-host
/// link counting). Three accepted relationships: identical hosts,
/// `www.` normalisation, and parent/child subdomain spanning.
/// Sibling subdomains explicitly NOT accepted — that needs PSL
/// knowledge to disambiguate from siblings under a public suffix.
nonisolated struct ProseCorpusCrawlerHostMatchTests {

    private func u(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Identical hosts

    @Test func identicalHostsMatch() {
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://example.com/a"), u("https://example.com/b")) == true)
    }

    @Test func hostCaseIsIgnored() {
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://Example.COM/a"), u("https://example.com/b")) == true)
    }

    // MARK: - www. normalisation

    @Test func wwwAndBareAreSameSite() {
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://www.example.com/a"), u("https://example.com/b")) == true)
    }

    @Test func wwwOnBothSidesNormalisesEqually() {
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://www.example.com/a"), u("https://www.example.com/b")) == true)
    }

    // MARK: - Parent/child subdomain spanning

    @Test func subdomainAndParentAreSameSite() {
        // The scenario the prose-corpus TODO called out — a genealogy
        // site that runs staff pages on a subdomain.
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://staff.example.com/about"),
            u("https://example.com/")) == true)
    }

    @Test func deepSubdomainAndParentAreSameSite() {
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://a.b.c.example.com/x"),
            u("https://example.com/")) == true)
    }

    @Test func parentSubdomainAndSubdomainSymmetric() {
        // Symmetric in both directions — order of arguments doesn't
        // change the verdict.
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://example.com/"),
            u("https://staff.example.com/about")) == true)
    }

    // MARK: - Negative cases

    @Test func unrelatedHostsDoNotMatch() {
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://example.com/"), u("https://other.org/")) == false)
    }

    @Test func suffixCollisionDoesNotMatch() {
        // `attacker-example.com` and `example.com` share a textual suffix
        // but not a subdomain boundary. The leading `.` in the suffix
        // check is what prevents the false positive — drop it and this
        // test fails.
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://attacker-example.com/"),
            u("https://example.com/")) == false)
    }

    @Test func siblingSubdomainsDoNotMatch() {
        // Out of scope for v2; needs PSL knowledge to do safely. The
        // test pins the *current* conservative behaviour so a future
        // PSL-aware change has a deliberate signal that it's loosening
        // this rule.
        #expect(ProseCorpusCrawler.sameRegistrableHost(
            u("https://staff.example.com/"),
            u("https://news.example.com/")) == false)
    }
}
