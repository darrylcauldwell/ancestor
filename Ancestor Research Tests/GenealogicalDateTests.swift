import Testing
@testable import Ancestor_Research

struct GenealogicalDateTests {
    @Test func exactDate() {
        let date = GenealogicalDate(parsing: "1 JAN 1887")
        #expect(date.qualifier == .exact)
        #expect(date.earliest == 1887)
        #expect(date.latest == 1887)
        #expect(date.isApproximate == false)
        #expect(date.bestYear == 1887)
    }

    @Test func yearOnly() {
        let date = GenealogicalDate(parsing: "1887")
        #expect(date.qualifier == .yearOnly)
        #expect(date.earliest == 1887)
        #expect(date.latest == 1887)
        #expect(date.isApproximate == false)
    }

    @Test func aboutDate() {
        let date = GenealogicalDate(parsing: "ABT 1887")
        #expect(date.qualifier == .about)
        #expect(date.earliest == 1882)
        #expect(date.latest == 1892)
        #expect(date.isApproximate == true)
        #expect(date.bestYear == 1887)
    }

    @Test func estimatedDate() {
        let date = GenealogicalDate(parsing: "EST 1887")
        #expect(date.qualifier == .estimated)
        #expect(date.earliest == 1877)
        #expect(date.latest == 1897)
        #expect(date.isApproximate == true)
    }

    @Test func calculatedDate() {
        let date = GenealogicalDate(parsing: "CAL 1887")
        #expect(date.qualifier == .calculated)
        #expect(date.earliest == 1886)
        #expect(date.latest == 1888)
    }

    @Test func beforeDate() {
        let date = GenealogicalDate(parsing: "BEF 1890")
        #expect(date.qualifier == .before)
        #expect(date.earliest == nil)
        #expect(date.latest == 1890)
        #expect(date.isApproximate == true)
        #expect(date.bestYear == 1890)
    }

    @Test func afterDate() {
        let date = GenealogicalDate(parsing: "AFT 1880")
        #expect(date.qualifier == .after)
        #expect(date.earliest == 1880)
        #expect(date.latest == nil)
        #expect(date.isApproximate == true)
        #expect(date.bestYear == 1880)
    }

    @Test func betweenDate() {
        let date = GenealogicalDate(parsing: "BET 1885 AND 1890")
        #expect(date.qualifier == .between)
        #expect(date.earliest == 1885)
        #expect(date.latest == 1890)
        #expect(date.isApproximate == true)
        #expect(date.bestYear == 1887)
    }

    @Test func dateWithMonthAndYear() {
        let date = GenealogicalDate(parsing: "MAR 1840")
        #expect(date.qualifier == .exact)
        #expect(date.earliest == 1840)
        #expect(date.latest == 1840)
    }

    @Test func preservesOriginal() {
        let date = GenealogicalDate(parsing: "ABT 1887")
        #expect(date.original == "ABT 1887")
    }

    // MARK: - Natural Language Synonyms

    @Test func parseCirca() {
        let date = GenealogicalDate(parsing: "circa 1890")
        #expect(date.qualifier == .about)
        #expect(date.earliest == 1885)
        #expect(date.latest == 1895)
        #expect(date.original == "circa 1890")
    }

    @Test func parseAround() {
        let date = GenealogicalDate(parsing: "around 1890")
        #expect(date.qualifier == .about)
        #expect(date.bestYear == 1890)
    }

    @Test func parseApproximately() {
        let date = GenealogicalDate(parsing: "Approximately 1850")
        #expect(date.qualifier == .about)
        #expect(date.bestYear == 1850)
    }

    @Test func parseCaseInsensitive() {
        let date = GenealogicalDate(parsing: "CIRCA 1890")
        #expect(date.qualifier == .about)
        #expect(date.bestYear == 1890)
    }

    @Test func parseBeforeSynonym() {
        let date = GenealogicalDate(parsing: "before 1900")
        #expect(date.qualifier == .before)
        #expect(date.earliest == nil)
        #expect(date.latest == 1900)
    }

    @Test func parseAfterSynonym() {
        let date = GenealogicalDate(parsing: "after 1880")
        #expect(date.qualifier == .after)
        #expect(date.earliest == 1880)
        #expect(date.latest == nil)
    }

    // MARK: - Decade Ranges

    @Test func parseDecade1880s() {
        let date = GenealogicalDate(parsing: "1880s")
        #expect(date.qualifier == .between)
        #expect(date.earliest == 1880)
        #expect(date.latest == 1889)
        #expect(date.isApproximate == true)
    }

    @Test func parseDecade1790s() {
        let date = GenealogicalDate(parsing: "1790s")
        #expect(date.qualifier == .between)
        #expect(date.earliest == 1790)
        #expect(date.latest == 1799)
    }

    // MARK: - Month Names

    @Test func parseMarchYear() {
        let date = GenealogicalDate(parsing: "March 1887")
        #expect(date.qualifier == .exact)
        #expect(date.earliest == 1887)
        #expect(date.latest == 1887)
    }

    @Test func parseDayMonthYear() {
        let date = GenealogicalDate(parsing: "3 March 1887")
        #expect(date.qualifier == .exact)
        #expect(date.earliest == 1887)
    }

    // MARK: - Question Mark (Explicitly Unknown)

    @Test func parseQuestionMark() {
        let date = GenealogicalDate(parsing: "?")
        #expect(date.earliest == nil)
        #expect(date.latest == nil)
        #expect(date.original == "?")
    }

    // MARK: - Parse Preview

    @Test func parsePreview_validYear() {
        let result = GenealogicalDate.parsePreview("1887")
        #expect(result.isValid == true)
        #expect(result.parsed?.earliest == 1887)
        #expect(result.displayText == "1887")
    }

    @Test func parsePreview_circa() {
        let result = GenealogicalDate.parsePreview("circa 1890")
        #expect(result.isValid == true)
        #expect(result.displayText.contains("1885"))
        #expect(result.displayText.contains("1895"))
    }

    @Test func parsePreview_invalid() {
        let result = GenealogicalDate.parsePreview("hello")
        #expect(result.isValid == false)
        #expect(result.parsed == nil)
        #expect(result.displayText.contains("Could not parse"))
    }

    @Test func parsePreview_empty() {
        let result = GenealogicalDate.parsePreview("")
        #expect(result.isValid == true)
        #expect(result.parsed == nil)
        #expect(result.displayText == "")
    }

    @Test func parsePreview_questionMark() {
        let result = GenealogicalDate.parsePreview("?")
        #expect(result.isValid == true)
        #expect(result.parsed == nil)
        #expect(result.displayText.contains("Unknown"))
    }

    @Test func parsePreview_decade() {
        let result = GenealogicalDate.parsePreview("1880s")
        #expect(result.isValid == true)
        #expect(result.displayText.contains("1880"))
        #expect(result.displayText.contains("1889"))
    }

    @Test func parsePreview_before() {
        let result = GenealogicalDate.parsePreview("before 1900")
        #expect(result.isValid == true)
        #expect(result.displayText.contains("Before"))
        #expect(result.displayText.contains("1900"))
    }
}
