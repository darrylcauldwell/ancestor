import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// LOCATION_MODEL_SPEC Part II Slice D deferred items — the picker's district line.
///
/// The line was a first-match over the county's districts in file order with no
/// year, so it displayed "Crich · Amber Valley" (Amber Valley RD began in 1994)
/// and "Matlock · Bakewell" (began 1839) on Victorian records, and named one of
/// several rivals as though it were the answer on roughly two rows in five.
/// Slice D recorded era-awareness as "data-blocked" because uk-places.json leaves
/// validFrom/validTo nil — but the DISTRICT catalogue carries startYear/endYear,
/// which is the side that was actually needed.
///
/// The view is not unit-tested (house rule: test services and models). These pin
/// the resolver behaviour the view now renders.
@MainActor
struct LocationPickerDistrictTests {

    private func districts(_ place: String, chapman: String?, year: Int?) -> [String] {
        (RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: place, chapman: chapman, year: year)?.districts ?? []).map(\.name)
    }

    // MARK: - Era awareness

    /// The headline defect. Amber Valley RD began in 1994 and cannot hold an
    /// 1861 birth, but the picker offered it because it asked without a year.
    @Test func aDistrictFromTheFutureIsNotOfferedForAVictorianEvent() {
        let dated = districts("Crich", chapman: "DBY", year: 1861)
        #expect(!dated.contains("Amber Valley"),
                "Amber Valley RD began 1994 — got \(dated)")
        #expect(!dated.isEmpty, "era filtering must not empty the list")
    }

    /// And the same query without a year still sees it, which is what the old
    /// call was doing — this pins the difference the year makes.
    @Test func withoutAYearTheFutureDistrictIsStillPresent() {
        #expect(districts("Crich", chapman: "DBY", year: nil).contains("Amber Valley"),
                "precondition for the era fix: undated resolution does include it")
    }

    @Test func matlockIsNotOfferedBeforeBakewellExisted() {
        let dated = districts("Matlock", chapman: "DBY", year: 1830)
        #expect(!dated.contains("Bakewell"), "Bakewell RD began 1839 — got \(dated)")
    }

    // MARK: - Honest ties

    /// Crich sits in more than one Derbyshire district even after era filtering.
    /// The picker must say so rather than name the first.
    @Test func aPlaceSpanningRivalDistrictsReportsAllOfThem() {
        let dated = districts("Cromford", chapman: "DBY", year: 1861)
        #expect(dated.count > 1, "precondition: Cromford is a genuine tie — got \(dated)")
    }

    /// A county entry has no registration district and must produce none rather
    /// than resolving to some district that shares a name fragment.
    @Test func aCountyHasNoDistrictLine() {
        let county = RegistrationDistrictResolver.candidates(
            forPlaceOrDistrict: "Derbyshire", chapman: "DBY", year: 1861)
        #expect(county == nil || county?.districts.isEmpty == true,
                "got \(county?.districts.map(\.name) ?? [])")
    }

    /// The picker resolves through the SAME entry point the scorer and apply use,
    /// so what a user is shown matches what an applied record would record. The
    /// old doc comment claimed this while calling a different, year-blind path.
    @Test func thePickerAndTheApplyPathAgree() {
        let applied = RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Hognaston", chapman: "DBY", year: 1861)
        let shown = districts("Hognaston", chapman: "DBY", year: 1861)
        #expect(applied != nil)
        if let applied, let name = PlaceAuthorityRegistry.shared.places.place(id: applied)?.name {
            #expect(shown.contains(name),
                    "the picker must show the district apply would write — \(name) not in \(shown)")
        }
    }
}
