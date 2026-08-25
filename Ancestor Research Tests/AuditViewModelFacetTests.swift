import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// The Health filter is two facets — category (Issues/Gaps) × severity
/// (Error/Warning/Info) — that AND together, and whose pill counts are FACETED:
/// each pill's number reflects the OTHER axis's current selection, so tapping
/// Issues re-counts the severity pills to issues only and vice versa. This lets
/// a user triage the cross-product (Issue/Error, then Issue/Warning, Gap/Warning…).
@MainActor
struct AuditViewModelFacetTests {

    private func result(_ name: String, _ severity: Severity, _ category: AuditCategory) -> AuditResult {
        AuditResult(profileID: name, profileName: name, severity: severity,
                    category: category, ruleID: "r", message: "m")
    }

    /// 2 errors, 3 warnings, 2 info; split across issue/gap so every cell of the
    /// 2×3 matrix is populated (issue: 1 err / 1 warn / 1 info; gap: 1 / 2 / 1).
    private func viewModel() -> AuditViewModel {
        let vm = AuditViewModel()
        vm.summary = AuditSummary(
            errors: [result("IssErr", .error, .issue), result("GapErr", .error, .gap)],
            warnings: [result("IssWarn", .warning, .issue),
                       result("GapWarn", .warning, .gap), result("GapWarn2", .warning, .gap)],
            info: [result("IssInfo", .info, .issue), result("GapInfo", .info, .gap)],
            total: 7, profilesChecked: 7)
        return vm
    }

    @Test func unfilteredCountsAreGlobal() {
        let vm = viewModel()
        #expect(vm.categoryCount(.issue) == 3)
        #expect(vm.categoryCount(.gap) == 4)
        #expect(vm.severityCount(.error) == 2)
        #expect(vm.severityCount(.warning) == 3)
        #expect(vm.severityCount(.info) == 2)
    }

    /// #HR2 — `.research` findings never reach the Health surface: not the
    /// rows, not the pills, not the severity badges. They stay in the summary
    /// (MCP reads it); the view model is the choke point.
    @Test func researchFindingsAreInvisibleToEveryFacet() {
        let vm = viewModel()
        vm.summary = AuditSummary(
            errors: vm.summary!.errors,
            warnings: vm.summary!.warnings + [result("ResWarn", .warning, .research)],
            info: vm.summary!.info + [
                result("ResInfo", .info, .research), result("ResInfo2", .info, .research)],
            total: 10, profilesChecked: 10)
        #expect(vm.filteredResults.count == 7, "the 3 research rows never render")
        #expect(vm.categoryCount(.research) == 0)
        #expect(vm.severityCount(.warning) == 3, "badge ignores the research warning")
        #expect(vm.severityCount(.info) == 2, "badge ignores the research info rows")
        #expect(vm.issueCount == 3)
        #expect(vm.gapCount == 4)
        vm.searchText = "Res"
        #expect(vm.filteredResults.isEmpty, "search cannot resurface them")
    }

    /// #HR2 review fix — any "audit found N items" message routing the user
    /// to Health must use `actionableTotal`, which excludes `.research`;
    /// `total` stays engine-wide for MCP/Settings.
    @Test func actionableTotalExcludesResearchFindings() {
        let summary = AuditSummary(
            errors: [result("IssErr", .error, .issue)],
            warnings: [result("GapWarn", .warning, .gap),
                       result("ResWarn", .warning, .research)],
            info: [result("ResInfo", .info, .research)],
            total: 4, profilesChecked: 4)
        #expect(summary.actionableTotal == 2)
        #expect(summary.total == 4, "engine-wide total is untouched")
    }

    @Test func selectingCategoryRefacetsSeverityCounts() {
        let vm = viewModel()
        vm.filterCategory = .issue
        #expect(vm.severityCount(.error) == 1)     // issue errors only
        #expect(vm.severityCount(.warning) == 1)
        #expect(vm.severityCount(.info) == 1)
    }

    @Test func selectingSeverityRefacetsCategoryCounts() {
        let vm = viewModel()
        vm.filterSeverity = .warning
        #expect(vm.categoryCount(.issue) == 1)     // issue warnings
        #expect(vm.categoryCount(.gap) == 2)       // gap warnings
    }

    @Test func bothFacetsAndTogether() {
        let vm = viewModel()
        vm.filterCategory = .gap
        vm.filterSeverity = .warning
        #expect(Set(vm.filteredResults.map(\.profileName)) == ["GapWarn", "GapWarn2"])
    }

    @Test func searchNarrowsFacetCountsToo() {
        let vm = viewModel()
        vm.searchText = "GapWarn"
        #expect(vm.categoryCount(.gap) == 2)
        #expect(vm.categoryCount(.issue) == 0)
        #expect(vm.severityCount(.warning) == 2)
    }
}
