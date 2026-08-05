import Testing
import Foundation
@testable import Ancestor_Research

/// TEMPLATED_NARRATIVE_SOURCE_SPEC Stage 1 — the config-driven Chapman-templated
/// resolver. Adding a source is a config; the resolver fills it per-subject and
/// never emits a URL with an unfilled placeholder.
struct TemplatedURLResolverTests {

    @Test func fillsTheWishfulThinkingConfigFromASubject() {
        let subject = TemplatedURLResolver.Subject(
            chapmanCode: "DBY", parish: "Youlgreave", surname: "Holmes", county: "Derbyshire")
        let url = TemplatedURLResolver.resolve(TemplatedSourceCatalogue.wishfulThinkingMIs, subject: subject)
        #expect(url?.absoluteString == "https://places.wishful-thinking.org.uk/DBY/Youlgreave/MIs.html")
        // The generic resolver reproduces the bespoke Stage-0 builder — proving the
        // hand-written source is just one instance of the template mechanism.
        #expect(url == MemorialInscriptionSource.memorialPageURL(chapmanCode: "DBY", parish: "Youlgreave"))
    }

    @Test func swapsTheChapmanSegmentForAnotherCounty() {
        // The whole point of your idea: a Nottinghamshire subject auto-retargets.
        let subject = TemplatedURLResolver.Subject(chapmanCode: "ntt", parish: "Mansfield")
        let url = TemplatedURLResolver.resolve(TemplatedSourceCatalogue.wishfulThinkingMIs, subject: subject)
        #expect(url?.absoluteString == "https://places.wishful-thinking.org.uk/NTT/Mansfield/MIs.html")
    }

    @Test func neverEmitsAURLWithAnUnfilledPlaceholder() {
        // Missing parish -> no query, no guess.
        let noParish = TemplatedURLResolver.Subject(chapmanCode: "DBY", parish: nil)
        #expect(TemplatedURLResolver.resolve(TemplatedSourceCatalogue.wishfulThinkingMIs, subject: noParish) == nil)
        // A county NAME where a Chapman code is required -> nil.
        let badCode = TemplatedURLResolver.Subject(chapmanCode: "Derbyshire", parish: "Youlgreave")
        #expect(TemplatedURLResolver.resolve(TemplatedSourceCatalogue.wishfulThinkingMIs, subject: badCode) == nil)
        // A template placeholder the subject can't fill leaves a brace -> refuse.
        let noSurname = TemplatedURLResolver.Subject(chapmanCode: "DBY", parish: "Youlgreave", surname: nil)
        #expect(TemplatedURLResolver.resolve(
            template: "https://x.org/{chapman}/{parish}/{surname}.html",
            parishStyle: .concatenated, subject: noSurname) == nil)
    }

    @Test func generalisesToAnyPlaceholderTemplate() {
        // A synthetic template exercising every placeholder proves the mechanism is
        // site-agnostic — a GENUKI or OPC config is just another template string.
        let subject = TemplatedURLResolver.Subject(
            chapmanCode: "ntt", parish: "West Bridgford", surname: "de la Warr", county: "Nottinghamshire")
        let url = TemplatedURLResolver.resolve(
            template: "https://example.org/{county}/{chapman}/{parish}/{surname}.html",
            parishStyle: .concatenated, subject: subject)
        #expect(url?.absoluteString
            == "https://example.org/Nottinghamshire/NTT/WestBridgford/DeLaWarr.html")
    }

    @Test func hyphenatedParishStyle() {
        let url = TemplatedURLResolver.resolve(
            template: "https://ex.org/{chapman}/{parish}/",
            parishStyle: .hyphenated,
            subject: .init(chapmanCode: "DBY", parish: "South Darley"))
        #expect(url?.absoluteString == "https://ex.org/DBY/South-Darley/")
    }

    @Test func onlyVerifiedConfigsAreBundled() {
        #expect(TemplatedSourceCatalogue.bundled.count == 1)
        #expect(TemplatedSourceCatalogue.bundled.first?.sourceID == "wishful-thinking-mi")
        #expect(TemplatedSourceCatalogue.wishfulThinkingMIs.attributionRequired)
    }
}
