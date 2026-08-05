import Testing
import Foundation
@testable import Ancestor_Research

/// First-version engine for the Chapman-templated memorial-inscription source:
/// URL templating (fetch only the local page, never the whole site) + MI-prose
/// parsing. Exercised against the REAL Youlgreave HOLMES inscriptions pulled from
/// places.wishful-thinking.org.uk/DBY/Youlgreave/MIs.html on 2026-08-05.
struct MemorialInscriptionSourceTests {

    // MARK: - URL templating (never the whole site)

    @Test func templatesTheURLOnChapmanCodeAndParish() {
        #expect(
            MemorialInscriptionSource.memorialPageURL(chapmanCode: "DBY", parish: "Youlgreave")?
                .absoluteString == "https://places.wishful-thinking.org.uk/DBY/Youlgreave/MIs.html")
        // A different county swaps the Chapman segment automatically.
        #expect(
            MemorialInscriptionSource.memorialPageURL(chapmanCode: "NTT", parish: "Mansfield")?
                .absoluteString == "https://places.wishful-thinking.org.uk/NTT/Mansfield/MIs.html")
        // Multi-word parishes drop interior spaces.
        #expect(
            MemorialInscriptionSource.memorialPageURL(chapmanCode: "DBY", parish: "South Darley")?
                .absoluteString == "https://places.wishful-thinking.org.uk/DBY/SouthDarley/MIs.html")
        // A county NAME (not a Chapman code) is rejected — no guessed URL.
        #expect(MemorialInscriptionSource.memorialPageURL(chapmanCode: "Derbyshire", parish: "Youlgreave") == nil)
        #expect(MemorialInscriptionSource.memorialPageURL(chapmanCode: "DBY", parish: "") == nil)
    }

    // MARK: - MI parsing → death year + age → birth year

    @Test func parsesRealYoulgreaveHolmesInscriptions() throws {
        // Verbatim transcriptions (kept in-test only, never republished).
        let text = """
        A67: John HOLMES, of Stanton, 10 May 1876, 89; Ellen, w, 25 Oct 1857, 73; Ann, grand-daughter, 14 July 1853, 15
        D77: Antoney HOLMES of Stanton, 12 Jan 1806, 56
        D121: John, s/o Samuel & Mary HOLMES, Of Stanton, 16 March 1833, 8yrs
        A68: Also two children who died in infancy
        """
        let people = MemorialInscriptionSource.parse(text)

        // Five DATED people; the undated "Also two children…" line yields none.
        #expect(people.count == 5)

        let john = try #require(people.first)
        #expect(john.surname == "Holmes")
        #expect(john.givenName == "John")
        #expect(john.deathYear == 1876)
        #expect(john.ageAtDeath == 89)
        #expect(john.birthYear == 1787)

        // Ellen has no surname of her own on the stone — she inherits HOLMES.
        let ellen = people[1]
        #expect(ellen.surname == "Holmes")
        #expect(ellen.givenName == "Ellen")
        #expect(ellen.relationship == "w")
        #expect(ellen.birthYear == 1784)   // 1857 − 73

        // The grand-daughter, dated but young.
        let ann = people[2]
        #expect(ann.givenName == "Ann")
        #expect(ann.birthYear == 1838)     // 1853 − 15

        // "8yrs" age form parses; the child's birth year falls out.
        let child = try #require(people.last)
        #expect(child.surname == "Holmes")
        #expect(child.givenName == "John")
        #expect(child.ageAtDeath == 8)
        #expect(child.birthYear == 1825)   // 1833 − 8
    }
}
