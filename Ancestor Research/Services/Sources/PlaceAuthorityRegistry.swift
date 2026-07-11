import Foundation
import os
import AncestorKit

/// The typed place-authority hierarchy for the app, **derived** from the three
/// existing seed sources (MODEL_EVOLUTION_SPEC §Change3 / ADR-004 E3):
///
///   1. `LocationGazetteer` — countries, ~56 counties, ~205 towns/parishes
///      (the `uk-places.json` entries, with their optional E3 hierarchy fields).
///   2. `FreeBMDDistrictCatalogue` — ~1121 registration districts, each already
///      carrying its county (Chapman code), validity years, and parish list.
///      This is the temporal-validity + district-hierarchy seed the spec's
///      schema sketch describes; E3 gives it a typed home.
///   3. `RegionConfig` — the hand-verified DBY district→parish lists (used only
///      to enrich DBY parish links; identical output to the flat path).
///
/// **No hardcoded regions.** There is not one Derbyshire-specific literal here:
/// every `PlaceAuthority` record is materialised from data. Feed the registry a
/// gazetteer that knows Leicestershire and it produces the Leicestershire
/// hierarchy, exactly as the no-hardcoded-regions invariant requires — E3 makes
/// that rule *stronger*, because county/district resolution now flows through a
/// data-derived hierarchy rather than county-name substring checks.
///
/// The registry is a thin, cached projection: it never becomes a second source
/// of truth. `RegionConfig.districts(forChapmanCode:)` and the gazetteer keep
/// their existing signatures and existing outputs; the authority is the
/// *hierarchy backing* those outputs can be proven against and, over time,
/// served from. The GENUKI ~12k-parish import lands as additional gazetteer
/// entries and flows straight through this derivation.
nonisolated final class PlaceAuthorityRegistry: Sendable {
    static let shared = PlaceAuthorityRegistry()

    /// All derived place-authority records, hierarchy links resolved.
    let places: [PlaceAuthority]

    /// id → record index for O(1) lookup on the hot resolution paths.
    private let byID: [String: PlaceAuthority]

    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "PlaceAuthorityRegistry"
    )

    private init() {
        self.places = Self.derive(
            gazetteer: LocationGazetteer.shared.all(),
            districts: FreeBMDDistrictCatalogue.shared.all()
        )
        self.byID = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Self.logger.info("Derived \(self.places.count) place-authority records")
    }

    /// Testable derivation seam — the initialiser wires in the shared singletons;
    /// tests pass synthetic seed data (e.g. a Leicestershire-only gazetteer) to
    /// prove the hierarchy is data-derived, not Derbyshire-baked.
    ///
    /// Registration-district ids use a `"{CHAPMAN}:{Name}-RD"` shape so a
    /// district never collides with a same-named town's `"{CHAPMAN}:{Name}"`
    /// gazetteer id. County ids are the bare Chapman code ("DBY"); country ids
    /// are the country name ("England").
    static func derive(
        gazetteer: [GazetteerEntry],
        districts: [FreeBMDDistrict]
    ) -> [PlaceAuthority] {
        var records: [PlaceAuthority] = []
        var countyIDs: Set<String> = []
        var countryIDs: Set<String> = []

        // Chapman code for a gazetteer id: the prefix before the first colon,
        // or the whole id for a bare county entry ("DBY"). Data-derived — no
        // region literal.
        func chapman(of id: String) -> String {
            if let colon = id.firstIndex(of: ":") { return String(id[..<colon]) }
            return id
        }

        // --- Tier 1: countries + counties + towns from the gazetteer ---
        for entry in gazetteer {
            let country = entry.country
            let countryID = country
            countryIDs.insert(countryID)

            if entry.kind == "county" {
                // County node. Parent is its country. id is the bare Chapman
                // code (== the gazetteer id for a county entry).
                countyIDs.insert(entry.id)
                records.append(PlaceAuthority(
                    id: entry.id,
                    name: entry.name,
                    kind: .county,
                    parentID: countryID,
                    validFrom: entry.validFrom,
                    validTo: entry.validTo,
                    county: entry.county,
                    country: country,
                    aliases: entry.aliases,
                    freeBMDCode: nil
                ))
            } else {
                // Town / place. Parent is its county (explicit parentID if the
                // seed carries one, else inferred from the id's Chapman prefix).
                let parent = entry.parentID ?? chapman(of: entry.id)
                records.append(PlaceAuthority(
                    id: entry.id,
                    name: entry.name,
                    kind: .place,
                    parentID: parent,
                    validFrom: entry.validFrom,
                    validTo: entry.validTo,
                    county: entry.county,
                    country: country,
                    aliases: entry.aliases,
                    freeBMDCode: nil
                ))
            }
        }

        // Synthesize any county referenced by a town but missing an explicit
        // county entry, so a town always has a resolvable county node. Derived
        // from the town's own county/country strings — still no region literal.
        for entry in gazetteer where entry.kind != "county" {
            let cid = entry.parentID ?? chapman(of: entry.id)
            guard !countyIDs.contains(cid) else { continue }
            countyIDs.insert(cid)
            records.append(PlaceAuthority(
                id: cid,
                name: entry.county,
                kind: .county,
                parentID: entry.country,
                validFrom: nil,
                validTo: nil,
                county: entry.county,
                country: entry.country,
                aliases: [],
                freeBMDCode: nil
            ))
        }

        // Country nodes (top of the hierarchy, no parent).
        for countryID in countryIDs {
            records.append(PlaceAuthority(
                id: countryID,
                name: countryID,
                kind: .country,
                parentID: nil,
                county: nil,
                country: countryID,
                aliases: []
            ))
        }

        // --- Tier 2: registration districts + their parishes from FreeBMD ---
        // The catalogue already carries county (Chapman), validity years, and
        // parish lists — the exact temporal + hierarchy data E3 promises. We map
        // it 1:1 into district + parish authority records.
        for district in districts {
            guard let chapmanCode = district.chapmanCode?.uppercased(),
                  !chapmanCode.isEmpty else { continue }

            // Ensure the county node exists (some district counties may not be
            // in the ~56-county gazetteer starter set). Derived from the
            // district's own Chapman code — data, not a literal.
            if !countyIDs.contains(chapmanCode) {
                countyIDs.insert(chapmanCode)
                records.append(PlaceAuthority(
                    id: chapmanCode,
                    name: chapmanCode,
                    kind: .county,
                    parentID: nil,          // country unknown from catalogue alone
                    county: nil,
                    country: nil,
                    aliases: []
                ))
            }

            let districtID = "\(chapmanCode):\(district.name)-RD"
            records.append(PlaceAuthority(
                id: districtID,
                name: district.name,
                kind: .registrationDistrict,
                parentID: chapmanCode,
                validFrom: district.startYear,
                validTo: district.endYear,
                county: nil,
                country: nil,
                aliases: [],
                freeBMDCode: district.code
            ))

            // Parishes under this district. The parish inherits the district's
            // validity window as its jurisdictional-relationship bound, so a
            // parish that appears under a pre-1974 district and its post-1974
            // successor resolves to the correct one for a given year (AC2).
            for parishName in district.parishes ?? [] {
                let parishID = "\(districtID)/\(parishName)"
                records.append(PlaceAuthority(
                    id: parishID,
                    name: parishName,
                    kind: .parish,
                    parentID: districtID,
                    validFrom: district.startYear,
                    validTo: district.endYear,
                    county: nil,
                    country: nil,
                    aliases: []
                ))
            }
        }

        return records
    }

    // MARK: - Hot-path lookups (indexed)

    func place(id: String) -> PlaceAuthority? { byID[id] }

    /// County a code/id rolls up to. Accepts a bare `COUNTY:Place` gazetteer
    /// code directly — the same ids `birthLocationCode` carries.
    func county(ofID id: String) -> PlaceAuthority? { places.county(of: id) }

    /// Registration district a code/id rolls up to.
    func registrationDistrict(ofID id: String) -> PlaceAuthority? {
        places.registrationDistrict(of: id)
    }
}
