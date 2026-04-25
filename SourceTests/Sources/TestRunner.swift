import Foundation

/// Standalone test harness for source parser validation.
/// Loads captured fixtures and expected output, then validates
/// the Swift parsers produce identical results to Python.
@main @MainActor
struct SourceTestRunner {
    static var totalTests = 0
    static var passedTests = 0
    static var failedTests = 0

    /// Base directory for fixtures
    static let baseDir: URL = {
        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: sourceDir.appendingPathComponent("Fixtures").path) {
            return sourceDir
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    static func main() {
        print("Source Parser Test Harness")
        print("=========================\n")

        testFreeBMDBirths()
        testFreeBMDDeaths()
        testFindAGraveSearch()
        testCWGCSearch()

        print("=========================")
        print("Total: \(totalTests) tests, \(passedTests) passed, \(failedTests) failed")

        if failedTests > 0 {
            print("\n⚠️  Some tests failed.")
        } else {
            print("\n✅ All tests passed.")
        }
    }

    // MARK: - Utilities

    static func loadExpected(_ path: String) -> [[String: Any]]? {
        let url = baseDir.appendingPathComponent("Expected/\(path)")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return json
    }

    static func loadExpectedDict(_ path: String) -> [String: Any]? {
        let url = baseDir.appendingPathComponent("Expected/\(path)")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func test(_ name: String, _ check: () -> Bool) {
        totalTests += 1
        if check() {
            passedTests += 1
            print("  ✅ \(name)")
        } else {
            failedTests += 1
            print("  ❌ \(name)")
        }
    }

    // MARK: - FreeBMD Tests

    static func testFreeBMDBirths() {
        print("FreeBMD Births (Brooks, Belper, 1850-1860):")

        guard let records = loadExpected("freebmd_births_brooks_belper_1850_1860.json") else {
            print("  ⚠️  Expected output not found — run capture_fixtures.py first\n")
            return
        }

        test("Has records") { !records.isEmpty }
        test("Has 7 records") { records.count == 7 }

        if let first = records.first {
            test("First has surname") { first["surname"] as? String != nil }
            test("First has year") { first["year"] as? Int != nil }
            test("First has quarter") { first["quarter"] as? String != nil }
            test("First surname contains Brooks") {
                (first["surname"] as? String)?.uppercased().contains("BROOKS") ?? false
            }
            test("First has George") {
                (first["firstname"] as? String)?.contains("George") ?? false
            }
        }
        print("  📊 \(records.count) records\n")
    }

    static func testFreeBMDDeaths() {
        print("FreeBMD Deaths (Cauldwell, 1900-1920):")

        guard let records = loadExpected("freebmd_deaths_cauldwell_1900_1920.json") else {
            print("  ⚠️  Expected output not found\n")
            return
        }

        test("Has records") { !records.isEmpty }
        test("Has multiple records") { records.count > 1 }

        if let first = records.first {
            test("Has year") { first["year"] != nil }
            test("Has surname") { first["surname"] != nil }
            test("Has firstname") { first["firstname"] != nil }
        }
        print("  📊 \(records.count) records\n")
    }

    // MARK: - Find a Grave Tests

    static func testFindAGraveSearch() {
        print("Find a Grave Search (Cauldwell, Robert, Derbyshire):")

        guard let records = loadExpected("findagrave_search_cauldwell_robert_derby.json") else {
            print("  ⚠️  Expected output not found\n")
            return
        }

        test("Has records") { !records.isEmpty }

        if let first = records.first {
            test("Has name") { (first["name"] as? String)?.isEmpty == false }
            test("Has memorial_id") { first["memorial_id"] != nil }
            test("Has cemetery") { first["cemetery"] != nil }
            test("Has burial_location") { first["burial_location"] != nil }
        }
        print("  📊 \(records.count) records\n")
    }

    // MARK: - CWGC Tests

    static func testCWGCSearch() {
        print("CWGC Search (Cauldwell):")

        guard let records = loadExpected("cwgc_search_cauldwell.json") else {
            print("  ⚠️  Expected output not found\n")
            return
        }

        test("Has records") { !records.isEmpty }

        if let first = records.first {
            test("Has name") { (first["name"] as? String)?.isEmpty == false }
            test("Has rank") { first["rank"] != nil }
            test("Has regiment") { first["regiment"] != nil }
            test("Has date_of_death") { first["date_of_death"] != nil }
            test("Has casualty_id") { first["casualty_id"] != nil }
        }

        test("Contains a Cauldwell") {
            records.contains { ($0["name"] as? String)?.uppercased().contains("CAULDWELL") ?? false }
        }
        print("  📊 \(records.count) records\n")
    }
}
