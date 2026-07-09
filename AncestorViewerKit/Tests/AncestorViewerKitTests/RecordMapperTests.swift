import Testing
import CloudKit
import Foundation
@testable import AncestorViewerKit

struct RecordMapperTests {

    private func personRecord(id: String = "P1", manifestID: String = "M1") -> CKRecord {
        let record = CKRecord(
            recordType: RecordMapper.personType,
            recordID: CKRecord.ID(recordName: "\(id):publishedPersons"))
        let enc = record.encryptedValues
        enc["id"] = id
        enc["manifestID"] = manifestID
        enc["schemaVersion"] = 1
        enc["displayName"] = "Ernest Cauldwell"
        enc["givenName"] = "Ernest"
        enc["familyName"] = "Cauldwell"
        enc["genderRaw"] = "male"
        enc["birthOriginal"] = "1887"
        enc["birthEarliest"] = Int64(1887)
        enc["birthLatest"] = Int64(1887)
        enc["birthQualifierRaw"] = "yearOnly"
        enc["birthIsApproximate"] = Int64(0)
        enc["birthPlace"] = "Crich, Derbyshire"
        enc["bioText"] = "Ernest was born in 1887."
        enc["citationsJSON"] = "[]"
        enc["badgesJSON"] = "{}"
        enc["isRedacted"] = Int64(0)
        enc["isProvisional"] = Int64(0)
        return record
    }

    @Test func mapsFullPersonFromEncryptedValues() {
        guard case .person(let row)? = RecordMapper.map(personRecord()) else {
            Issue.record("expected a person row")
            return
        }
        #expect(row.id == "P1")
        #expect(row.manifestID == "M1")
        #expect(row.displayName == "Ernest Cauldwell")
        #expect(row.givenName == "Ernest")
        #expect(row.genderRaw == "male")
        #expect(row.birthEarliest == 1887)
        #expect(row.birthQualifierRaw == "yearOnly")
        #expect(row.birthIsApproximate == false)
        #expect(row.birthPlace == "Crich, Derbyshire")
        #expect(row.bioText == "Ernest was born in 1887.")
        #expect(row.isRedacted == false)
        #expect(row.deathOriginal == nil)
    }

    @Test func boolFieldsDecodeFromInt64() {
        let record = personRecord()
        record.encryptedValues["isRedacted"] = Int64(1)
        guard case .person(let row)? = RecordMapper.map(record) else {
            Issue.record("expected a person row")
            return
        }
        #expect(row.isRedacted == true)
    }

    @Test func unknownRecordTypeIsIgnored() {
        let record = CKRecord(
            recordType: "publishedFutureThings",
            recordID: CKRecord.ID(recordName: "X:publishedFutureThings"))
        record.encryptedValues["id"] = "X"
        #expect(RecordMapper.map(record) == nil)
    }

    @Test func missingIDFallsBackToRecordNameConvention() {
        let record = CKRecord(
            recordType: RecordMapper.manifestType,
            recordID: CKRecord.ID(recordName: "ABC-123:publishedManifests"))
        record.encryptedValues["generation"] = Int64(4)
        guard case .manifest(let row)? = RecordMapper.map(record) else {
            Issue.record("expected a manifest row")
            return
        }
        #expect(row.id == "ABC-123")
        #expect(row.generation == 4)
    }

    @Test func shareRecordNameYieldsNoRowID() {
        #expect(RecordMapper.rowID(fromRecordName: "cloudkit.share") == nil)
        #expect(RecordMapper.rowID(fromRecordName: "share-abc:spikeManifests") == "share-abc")
        #expect(RecordMapper.tableName(fromRecordName: "u1:publishedPersons") == "publishedPersons")
    }

    @Test func personWithoutManifestIDIsSkipped() {
        let record = CKRecord(
            recordType: RecordMapper.personType,
            recordID: CKRecord.ID(recordName: "P9:publishedPersons"))
        record.encryptedValues["id"] = "P9"
        record.encryptedValues["displayName"] = "Nobody"
        #expect(RecordMapper.map(record) == nil)
    }

    @Test func mediaWithoutAssetKeepsNilLocalPath() {
        let record = CKRecord(
            recordType: RecordMapper.mediaType,
            recordID: CKRecord.ID(recordName: "MD1:publishedMedia"))
        let enc = record.encryptedValues
        enc["id"] = "MD1"
        enc["personID"] = "P1"
        enc["kind"] = "portrait"
        enc["relativePath"] = "photos/ernest.jpg"
        guard case .media(let row)? = RecordMapper.map(record) else {
            Issue.record("expected a media row")
            return
        }
        #expect(row.localAssetPath == nil)
        #expect(row.kind == "portrait")
    }

    @Test func mediaAssetIsMaterialisedThroughHandler() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-asset-\(UUID().uuidString).bin")
        try Data([0x01, 0x02]).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let record = CKRecord(
            recordType: RecordMapper.mediaType,
            recordID: CKRecord.ID(recordName: "MD2:publishedMedia"))
        record.encryptedValues["id"] = "MD2"
        record.encryptedValues["personID"] = "P1"
        record.encryptedValues["kind"] = "document"
        record["asset"] = CKAsset(fileURL: temp)

        guard case .media(let row)? = RecordMapper.map(record, materialiseAsset: { url, id in
            #expect(id == "MD2")
            return url.path
        }) else {
            Issue.record("expected a media row")
            return
        }
        #expect(row.localAssetPath == temp.path)
    }
}
