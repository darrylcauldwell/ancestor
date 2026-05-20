import Testing
import Foundation
@testable import Ancestor_Research

/// Covers the prose-corpus integration on `ResearchViewModel` — the
/// pure helpers that turn a `ResearchSubject` + `ResearchMode` into
/// the right `RecordQuery` and the right top-K limit. The full
/// async dispatch is exercised end-to-end by `ProseCorpusSourceTests`;
/// this file pins just the contract at the view-model seam.
@MainActor
struct ResearchViewModelProseCorpusTests {

    // MARK: - K-per-mode mapping (spec §9.3)

    @Test func proseCorpusLimitMatchesSpecForVerifyAndExtend() {
        #expect(ResearchViewModel.proseCorpusLimit(for: .verify) == 3)
        #expect(ResearchViewModel.proseCorpusLimit(for: .extend) == 3)
    }

    @Test func proseCorpusLimitWidensForDiscoverAndAll() {
        #expect(ResearchViewModel.proseCorpusLimit(for: .discover) == 5)
        #expect(ResearchViewModel.proseCorpusLimit(for: .all) == 8)
    }

    // MARK: - buildProseQuery — year range plumbing

    private func makeSubject(
        surname: String? = "Cauldwell",
        givenName: String? = nil,
        birthYearFrom: Int? = nil,
        birthYearTo: Int? = nil,
        deathYearFrom: Int? = nil,
        deathYearTo: Int? = nil,
        region: Region? = nil
    ) -> ResearchSubject {
        ResearchSubject(
            profileID: "test-1",
            surname: surname,
            givenName: givenName,
            birthYearFrom: birthYearFrom,
            birthYearTo: birthYearTo,
            deathYearFrom: deathYearFrom,
            deathYearTo: deathYearTo,
            gender: nil,
            region: region,
            mode: .extend
        )
    }

    @Test func buildProseQueryUsesBirthYearFromAsLowerBound() {
        let subject = makeSubject(birthYearFrom: 1782, deathYearTo: 1856)
        let query = ResearchViewModel.buildProseQuery(subject: subject, surname: "Cauldwell")
        #expect(query.yearFrom == 1782)
        #expect(query.yearTo == 1856)
    }

    @Test func buildProseQueryFallsBackToBirthPlus95WhenDeathUnknown() {
        let subject = makeSubject(birthYearFrom: 1800, birthYearTo: 1810)
        let query = ResearchViewModel.buildProseQuery(subject: subject, surname: "Cauldwell")
        #expect(query.yearFrom == 1800)
        // birthYearTo (1810) + 95 — gives the corpus a generous window
        // for late-life mentions.
        #expect(query.yearTo == 1905)
    }

    @Test func buildProseQueryFallsBackToBirthYearFromPlus95WhenNoBirthYearTo() {
        let subject = makeSubject(birthYearFrom: 1820)
        let query = ResearchViewModel.buildProseQuery(subject: subject, surname: "Cauldwell")
        #expect(query.yearFrom == 1820)
        #expect(query.yearTo == 1915)
    }

    @Test func buildProseQueryReturnsNilBoundsForSubjectWithNoYears() {
        let subject = makeSubject()
        let query = ResearchViewModel.buildProseQuery(subject: subject, surname: "Cauldwell")
        #expect(query.yearFrom == nil)
        #expect(query.yearTo == nil)
    }

    @Test func buildProseQueryUsesDeathYearFromPlus2WhenOnlyDeathFromKnown() {
        // Subject has a death-year lower bound but no upper — bump it
        // by 2 so a corpus page that talks about death year ± 2 still
        // scores. Mirrors the convention `yearRange(for:)` uses for
        // death-typed queries.
        let subject = makeSubject(deathYearFrom: 1880)
        let query = ResearchViewModel.buildProseQuery(subject: subject, surname: "Cauldwell")
        #expect(query.yearTo == 1882)
    }

    @Test func buildProseQueryPropagatesSurnameAndGivenAndRegion() {
        let subject = makeSubject(
            givenName: "Thomas",
            birthYearFrom: 1780,
            region: .county("Derbyshire")
        )
        let query = ResearchViewModel.buildProseQuery(subject: subject, surname: "Cauldwell")
        #expect(query.surname == "Cauldwell")
        #expect(query.givenName == "Thomas")
        #expect(query.region == .county("Derbyshire"))
        // recordType is .pedigree by convention — the prose source
        // ignores it, but using a meaningful value keeps the query
        // self-documenting at call sites that log it.
        #expect(query.recordType == .pedigree)
    }
}
