import Testing
@testable import AncestorApp

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
}
