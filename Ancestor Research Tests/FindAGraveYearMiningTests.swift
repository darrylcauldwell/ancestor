import Testing
import Foundation
@testable import Ancestor_Research

/// Year extraction from Find a Grave memorial inscription / biography free
/// text — fallback path when schema.org itemprop dates are absent.
struct FindAGraveYearMiningTests {

    // MARK: - extractYearsFromMemorialText

    @Test func yearRangeEmDash() {
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText("1919 — 2017")
        #expect(b == 1919)
        #expect(d == 2017)
    }

    @Test func yearRangeEnDash() {
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText("1919–2017")
        #expect(b == 1919)
        #expect(d == 2017)
    }

    @Test func yearRangeHyphen() {
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText("1919-2017")
        #expect(b == 1919)
        #expect(d == 2017)
    }

    @Test func yearRangeWordTo() {
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText("1919 to 2017")
        #expect(b == 1919)
        #expect(d == 2017)
    }

    @Test func explicitBornAndDied() {
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText(
            "Ernest Victor Cauldwell, born 18 August 1919, died 6 January 2017"
        )
        #expect(b == 1919)
        #expect(d == 2017)
    }

    @Test func explicitDiedOnly() {
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText("Died 6 Jan 2017 aged 97")
        #expect(b == nil)
        #expect(d == 2017)
    }

    @Test func loneYearTreatedAsDeath() {
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText("In memory of Ernest, gone 2017.")
        #expect(b == nil)
        #expect(d == 2017)
    }

    @Test func twoYearsEarliestIsBirth() {
        // No keywords, no dash — but two distinct years means we still
        // assign earliest=birth, latest=death.
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText(
            "Ernest Victor Cauldwell\n1919\n2017"
        )
        #expect(b == 1919)
        #expect(d == 2017)
    }

    @Test func emptyTextYieldsNil() {
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText("")
        #expect(b == nil)
        #expect(d == nil)
    }

    @Test func nonsenseOrderRejected() {
        // Death-before-birth signals we picked up unrelated dates (e.g.
        // "served WWII 1939-1945" sandwiched in a longer bio). Bail.
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText("died 1900, born 1950")
        #expect(b == nil)
        #expect(d == nil)
    }

    @Test func explicitBeatsRange() {
        // When "died" appears with a year that's NOT the later year of a
        // range, the explicit keyword should win.
        let (b, d) = FindAGraveSource.extractYearsFromMemorialText(
            "Served 1939-1945. Died 2010."
        )
        #expect(d == 2010)
        // birth from range fallback only if no contradiction
        #expect(b == 1939)
    }

    // MARK: - parseMemorialDetail end-to-end

    @Test func parserUsesInscriptionWhenItempropMissing() {
        // Memorial HTML with no schema.org dates but a year-range inscription.
        let html = """
        <html>
          <head><title>Ernest Victor Cauldwell (1919 - 2017) - Find a Grave Memorial</title></head>
          <body>
            <div id="inscriptionValue">1919 — 2017</div>
          </body>
        </html>
        """
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        #expect(burial.birthYear == 1919)
        #expect(burial.deathYear == 2017)
        #expect(burial.inscription == "1919 — 2017")
    }

    @Test func parserRejectsAntiBotBlockPage() {
        // The shape of Find a Grave's anti-bot / captcha shell — generic
        // site title, no schema.org memorial markup, no inscription/bio
        // divs. Without the guard this would parse a garbage record with
        // "Find a Grave - Millions of Cemetery Records" as the name.
        let html = """
        <html>
          <head>
            <title>Find a Grave - Millions of Cemetery Records</title>
            <meta name="google-site-verification" content="Wbl3..." />
          </head>
          <body>
            <div>Please verify you are human</div>
          </body>
        </html>
        """
        let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345)
        #expect(record == nil)
    }

    @Test func parserAcceptsRealMemorialEvenWithoutInscription() {
        // A real memorial may lack inscriptionValue/fullBio (some are
        // minimal listings) but will carry schema.org itemprops — the
        // guard should accept this.
        let html = """
        <html>
          <head><title>Ernest Cauldwell - Find a Grave Memorial</title></head>
          <body>
            <span itemprop="birthDate">1919</span>
            <span itemprop="deathDate">2017</span>
          </body>
        </html>
        """
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        #expect(burial.birthYear == 1919)
        #expect(burial.deathYear == 2017)
    }

    @Test func parserPrefersItempropOverInscription() {
        // Both itemprop dates AND inscription are present — itemprop wins.
        let html = """
        <html>
          <head><title>Ernest Victor Cauldwell - Find a Grave Memorial</title></head>
          <body>
            <span itemprop="birthDate">18 Aug 1919</span>
            <span itemprop="deathDate">6 Jan 2017</span>
            <div id="inscriptionValue">1920 - 2018</div>
          </body>
        </html>
        """
        guard let record = FindAGraveSource.parseMemorialDetail(html, memorialID: 12345),
              case .burial(let burial) = record else {
            Issue.record("Expected a burial record")
            return
        }
        // itemprop values, not the wrong years in the inscription.
        #expect(burial.birthYear == 1919)
        #expect(burial.deathYear == 2017)
    }
}
