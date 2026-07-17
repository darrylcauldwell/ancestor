import Testing
import Foundation
@testable import Ancestor_Research

/// Phase 5 — the shared identity-constraint core (LEAD_DISCOVERY_SPEC §7).
/// One rule set for both clustering roles; these tests pin each rule and the
/// deliberate relationships between the constants.
struct IdentityConstraintsTests {

    // MARK: - Constants relationships (drift detectors)

    @Test func constantsEncodeDeliberateRelationships() {
        // Birth-vs-death lag is strictly tighter than general event-vs-death
        // lag: probate/burial can trail a death by years; a birth registration
        // cannot.
        #expect(IdentityConstraints.postDeathBirthMarginYears
                < IdentityConstraints.postDeathMarginYears)
        // Cross-surname bridging earns less birth slack than within-block merges.
        #expect(IdentityConstraints.bridgeBirthYearTolerance
                < IdentityConstraints.birthYearTolerance)
        // The acceptance engine's aliases ARE the shared constants.
        #expect(ClusteringEngine.maxLifespanYears == IdentityConstraints.maxLifespanYears)
        #expect(ClusteringEngine.maxAdultAgeYears == IdentityConstraints.maxAdultAgeYears)
        #expect(ClusteringEngine.postDeathMarginYears == IdentityConstraints.postDeathMarginYears)
    }

    // MARK: - Rules

    @Test func givenNameContradiction() {
        #expect(IdentityConstraints.givenNamesContradict("Ernest", "Mabel"))
        #expect(!IdentityConstraints.givenNamesContradict("Ernest", "Ernest"))
        #expect(!IdentityConstraints.givenNamesContradict(nil, "Mabel"))     // missing = permissive
        #expect(!IdentityConstraints.givenNamesContradict(" ?", "Mabel"))    // placeholder = permissive
    }

    @Test func birthYearContradiction() {
        #expect(!IdentityConstraints.birthYearsContradict(1887, 1890))       // within ±5
        #expect(IdentityConstraints.birthYearsContradict(1887, 1895))        // beyond ±5
        #expect(!IdentityConstraints.birthYearsContradict(nil, 1890))        // missing = permissive
        #expect(IdentityConstraints.birthYearsContradict(1887, 1890, tolerance: 2))
    }

    @Test func bornAfterDeathAndEventAfterDeathUseTheirOwnMargins() {
        // Birth: only registration lag (+1).
        #expect(!IdentityConstraints.bornAfterDeath(birth: 1891, death: 1890))
        #expect(IdentityConstraints.bornAfterDeath(birth: 1892, death: 1890))
        // Other events: burial/probate lag (+2).
        #expect(!IdentityConstraints.eventAfterDeath(eventYear: 1892, deathYear: 1890))
        #expect(IdentityConstraints.eventAfterDeath(eventYear: 1893, deathYear: 1890))
        // Missing data is permissive on both.
        #expect(!IdentityConstraints.bornAfterDeath(birth: nil, death: 1890))
        #expect(!IdentityConstraints.eventAfterDeath(eventYear: 1990, deathYear: nil))
    }

    @Test func distinctDeathsRule() {
        #expect(!IdentityConstraints.distinctDeaths(1917, 1918))             // one death, jitter
        #expect(IdentityConstraints.distinctDeaths(1917, 1920))              // two deaths
        #expect(!IdentityConstraints.distinctDeaths(nil, 1920))              // missing = permissive
    }

    @Test func countyContradiction() {
        #expect(IdentityConstraints.countiesContradict("DBY", "WRY"))
        #expect(!IdentityConstraints.countiesContradict("DBY", "dby"))       // case-insensitive same
        #expect(!IdentityConstraints.countiesContradict(nil, "WRY"))         // unknown = permissive
    }

    @Test func impliedBirthYearGuardsImplausibleAges() {
        #expect(IdentityConstraints.impliedBirthYear(deathYear: 1960, ageAtDeath: 74) == 1886)
        #expect(IdentityConstraints.impliedBirthYear(deathYear: 1960, ageAtDeath: 999) == nil)
        #expect(IdentityConstraints.impliedBirthYear(deathYear: 1960, ageAtDeath: -3) == nil)
        #expect(IdentityConstraints.impliedBirthYear(deathYear: nil, ageAtDeath: 74) == nil)
    }
}
