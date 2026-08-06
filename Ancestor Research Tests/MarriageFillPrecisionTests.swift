import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// PARISH_ABSORPTION follow-up — `fillRelationshipMarriage` is directional on
/// year-span, but a parish register's exact day ("30 Jan 1915") and a FreeBMD
/// registration quarter ("Mar 1915") both collapse to year-span 0, so the tie
/// never broke and the coarser value stayed (owner report 2026-08-06, Ernest
/// Cauldwell × Mary Ward). The fill now breaks a same-year tie by intra-year
/// precision, and prefers a more-specific (parish vs registration-district)
/// location. Synthetic couple; no real family data.
@MainActor
struct MarriageFillPrecisionTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func profile(_ id: String, first: String, last: String) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: last,
                gender: .unknown, attributes: nil, birthDate: nil, birthLocation: nil,
                deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    /// Build the edge carrying a coarse BMD registration date/place already,
    /// then apply the precise parish values. Returns the resulting edge row.
    private func fillAndRead(
        existingDate: GenealogicalDate?, existingLocation: String?,
        candidateDate: GenealogicalDate?, candidateLocation: String?
    ) throws -> (date: String?, location: String?) {
        let db = try makeDB()
        _ = try db.addProfile(profile("h", first: "Ernest", last: "Cauldwell"), source: .gedcom)
        _ = try db.addProfile(profile("w", first: "Mary", last: "Ward"), source: .gedcom)
        let edgeID = UUID()
        _ = try db.addRelationship(Relationship(
            id: edgeID, from: "h", to: "w", type: .spouse, role: nil, subtype: .biological,
            marriageDate: existingDate, marriageLocation: existingLocation, divorceDate: nil))
        _ = try db.fillRelationshipMarriage(
            relationshipID: edgeID, candidateDate: candidateDate, candidateLocation: candidateLocation)
        let row = try db.dbQueue.read { d in
            try Row.fetchOne(d, sql: "SELECT marriage_date_original, marriage_location FROM relationships WHERE id = ?",
                             arguments: [edgeID.uuidString])
        }
        return (row?["marriage_date_original"], row?["marriage_location"])
    }

    @Test func exactDayUpgradesRegistrationQuarter() throws {
        // Mar 1915 (BMD quarter) already on the edge; 30 Jan 1915 (parish) wins.
        let out = try fillAndRead(
            existingDate: GenealogicalDate(parsing: "Mar 1915"), existingLocation: "Ashbourne",
            candidateDate: GenealogicalDate(parsing: "30 Jan 1915"), candidateLocation: "Kirk Ireton, Derbyshire")
        #expect(out.date == "30 Jan 1915")
        #expect(out.location == "Kirk Ireton, Derbyshire")
    }

    @Test func coarserDateNeverDowngradesPreciseOne() throws {
        // The reverse must NOT happen: a quarter can't replace an exact day.
        let out = try fillAndRead(
            existingDate: GenealogicalDate(parsing: "30 Jan 1915"), existingLocation: "Kirk Ireton, Derbyshire",
            candidateDate: GenealogicalDate(parsing: "Mar 1915"), candidateLocation: "Ashbourne")
        #expect(out.date == "30 Jan 1915")
        #expect(out.location == "Kirk Ireton, Derbyshire")
    }

    @Test func fillsEmptyDateAndLocation() throws {
        let out = try fillAndRead(
            existingDate: nil, existingLocation: nil,
            candidateDate: GenealogicalDate(parsing: "30 Jan 1915"), candidateLocation: "Kirk Ireton, Derbyshire")
        #expect(out.date == "30 Jan 1915")
        #expect(out.location == "Kirk Ireton, Derbyshire")
    }

    @Test func equalSpecificityLocationDoesNotChurn() throws {
        // Two 2-part places at the same granularity: keep the existing.
        let out = try fillAndRead(
            existingDate: GenealogicalDate(parsing: "1915"), existingLocation: "Duffield, Derbyshire",
            candidateDate: nil, candidateLocation: "Kirk Ireton, Derbyshire")
        #expect(out.location == "Duffield, Derbyshire")
    }
}
