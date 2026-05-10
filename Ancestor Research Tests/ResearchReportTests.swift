import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for M10 Research Report (DESIGN.md §7.9.5). Cover the composer
/// (pure logic — scope, focus filter, grouping, dedup) and the Markdown
/// renderer's section ordering.
struct ResearchReportTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String,
        first: String? = nil,
        last: String? = nil,
        birth: Int? = nil,
        death: Int? = nil,
        birthLocation: String? = nil,
        deathLocation: String? = nil,
        sources: [ProfileField: [FieldSource]] = [:]
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: first,
            lastName: last,
            gender: nil,
            attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: "\($0)") },
            birthLocation: birthLocation,
            deathDate: death.map { GenealogicalDate(parsing: "\($0)") },
            deathLocation: deathLocation,
            bio: nil,
            isDeleted: false,
            sources: sources,
            disputes: [:]
        )
    }

    private func makeQuestion(
        text: String,
        profileIDs: [String] = [],
        priority: QuestionPriority = .medium,
        status: QuestionStatus = .open,
        tried: String? = nil,
        resolution: String? = nil
    ) -> OpenQuestion {
        OpenQuestion(
            id: UUID(),
            text: text,
            profileIDs: profileIDs,
            priority: priority,
            status: status,
            triedSources: tried,
            promotedFrom: nil,
            createdAt: Date(),
            resolvedAt: status == .resolved ? Date() : nil,
            resolution: resolution
        )
    }

    private func makeHypothesis(
        claim: HypothesisClaim,
        status: HypothesisStatus = .active,
        dismissal: String? = nil
    ) -> Hypothesis {
        Hypothesis(
            id: UUID(),
            claim: claim,
            confidence: .working,
            reasoning: "test reasoning",
            supportingEvidence: [],
            contradictingEvidence: [],
            status: status,
            createdAt: Date(),
            resolvedAt: status == .active ? nil : Date(),
            dismissalReason: dismissal
        )
    }

    private func makeSnapshot(_ profiles: [Profile]) -> FamilyGraphSnapshot {
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return FamilyGraphSnapshot(profiles: dict, relationships: [])
    }

    // MARK: - Scope

    @Test func wholeTreeScope_mentionsProfileCount() {
        let snapshot = makeSnapshot([
            makeProfile(id: "a", first: "Ann"),
            makeProfile(id: "b", first: "Ben"),
            makeProfile(id: "c", first: "Cal"),
        ])
        let doc = ResearchReportComposer.compose(
            focusSetID: nil,
            snapshot: snapshot,
            notes: [], questions: [], hypotheses: [],
            focusSets: [], sessions: []
        )
        #expect(doc.scopeSummary.contains("Whole tree"))
        #expect(doc.scopeSummary.contains("3"))
    }

    @Test func focusSetScope_namesFocusSet_andExcludesOutsideQuestions() {
        let snapshot = makeSnapshot([
            makeProfile(id: "a", first: "Ann", birth: 1880, death: 1950, birthLocation: "Belper"),
            makeProfile(id: "b", first: "Ben"),
        ])
        let focusID = UUID()
        let focus = FocusSet(
            id: focusID,
            title: "My grandparents",
            profileIDs: ["a"],
            createdAt: Date(),
            lastActiveAt: Date()
        )
        let inScope = makeQuestion(text: "Who were Ann's parents?", profileIDs: ["a"])
        let outOfScope = makeQuestion(text: "Who were Ben's parents?", profileIDs: ["b"])

        let doc = ResearchReportComposer.compose(
            focusSetID: focusID,
            snapshot: snapshot,
            notes: [],
            questions: [inScope, outOfScope],
            hypotheses: [],
            focusSets: [focus],
            sessions: []
        )

        #expect(doc.scopeSummary.contains("My grandparents"))
        #expect(doc.scopeSummary.contains("Belper"))
        #expect(doc.scopeSummary.contains("1880"))
        let openQs = doc.questionsByStatus[.open] ?? []
        #expect(openQs.count == 1)
        #expect(openQs.first?.id == inScope.id)
    }

    @Test func emptyWorkbench_producesValidEmptyDocument() {
        let snapshot = makeSnapshot([makeProfile(id: "a")])
        let doc = ResearchReportComposer.compose(
            focusSetID: nil,
            snapshot: snapshot,
            notes: [], questions: [], hypotheses: [],
            focusSets: [], sessions: []
        )
        #expect(doc.scopeSummary.contains("Whole tree"))
        for status in QuestionStatus.allCases {
            #expect((doc.questionsByStatus[status] ?? []).isEmpty)
        }
        for status in HypothesisStatus.allCases {
            #expect((doc.hypothesesByStatus[status] ?? []).isEmpty)
        }
        #expect(doc.findings.isEmpty)
        #expect(doc.stillOpen.isEmpty)
        #expect(doc.sourcesConsulted.isEmpty)
    }

    // MARK: - Grouping

    @Test func questions_groupByStatus() {
        let snapshot = makeSnapshot([makeProfile(id: "a")])
        let q1 = makeQuestion(text: "Q1", status: .open)
        let q2 = makeQuestion(text: "Q2", status: .open)
        let q3 = makeQuestion(text: "Q3", status: .resolved, resolution: "Found in census")

        let doc = ResearchReportComposer.compose(
            focusSetID: nil,
            snapshot: snapshot,
            notes: [],
            questions: [q1, q2, q3],
            hypotheses: [],
            focusSets: [], sessions: []
        )
        #expect(doc.questionsByStatus[.open]?.count == 2)
        #expect(doc.questionsByStatus[.resolved]?.count == 1)
        #expect(doc.questionsByStatus[.inProgress]?.isEmpty == true)
    }

    @Test func hypotheses_dismissalReasonPreserved() {
        let snapshot = makeSnapshot([makeProfile(id: "a")])
        let h = makeHypothesis(
            claim: .fieldValue(profileID: "a", field: .birthDate, value: "1880"),
            status: .dismissed,
            dismissal: "Census confirms 1882."
        )
        let doc = ResearchReportComposer.compose(
            focusSetID: nil,
            snapshot: snapshot,
            notes: [], questions: [],
            hypotheses: [h],
            focusSets: [], sessions: []
        )
        let dismissed = doc.hypothesesByStatus[.dismissed] ?? []
        #expect(dismissed.count == 1)
        #expect(dismissed.first?.dismissalReason == "Census confirms 1882.")
    }

    // MARK: - Sources dedup

    @Test func sourcesConsulted_dedupsIdenticalTriedSources() {
        let snapshot = makeSnapshot([makeProfile(id: "a")])
        let q1 = makeQuestion(text: "Q1", profileIDs: ["a"], tried: "FreeBMD 1810-1820")
        let q2 = makeQuestion(text: "Q2", profileIDs: ["a"], tried: "FreeBMD 1810-1820")
        let q3 = makeQuestion(text: "Q3", profileIDs: ["a"], tried: "Wirksworth 1815")

        let doc = ResearchReportComposer.compose(
            focusSetID: nil,
            snapshot: snapshot,
            notes: [],
            questions: [q1, q2, q3],
            hypotheses: [],
            focusSets: [], sessions: []
        )
        let occurrences = doc.sourcesConsulted.filter { $0 == "FreeBMD 1810-1820" }.count
        #expect(occurrences == 1)
        #expect(doc.sourcesConsulted.contains("Wirksworth 1815"))
    }

    @Test func sourcesConsulted_includesCitationRepositoriesAndCollections() {
        let citation = Citation(
            repository: "The National Archives",
            collection: "1851 Census of England",
            title: nil, page: nil, url: nil, dateAccessed: nil, notes: nil
        )
        let source = FieldSource(
            origin: .freecen, raw: "FreeCen", addedAt: Date(),
            citation: citation, quality: .primary
        )
        let profile = makeProfile(
            id: "a", first: "Ann",
            sources: [.birthDate: [source]]
        )
        let doc = ResearchReportComposer.compose(
            focusSetID: nil,
            snapshot: makeSnapshot([profile]),
            notes: [], questions: [], hypotheses: [],
            focusSets: [], sessions: []
        )
        #expect(doc.sourcesConsulted.contains { $0.contains("1851 Census of England") })
        #expect(doc.sourcesConsulted.contains { $0.contains("The National Archives") })
    }

    // MARK: - Findings heuristic

    @Test func findings_includesProfilesWithNonManualSources() {
        let manual = FieldSource(origin: .manual, raw: "manual", addedAt: Date())
        let auto = FieldSource(origin: .freebmd, raw: "auto", addedAt: Date())

        let manualOnly = makeProfile(id: "m", first: "Mark",
                                     sources: [.firstName: [manual]])
        let autoSourced = makeProfile(id: "a", first: "Ann",
                                      sources: [.birthDate: [auto]])

        let doc = ResearchReportComposer.compose(
            focusSetID: nil,
            snapshot: makeSnapshot([manualOnly, autoSourced]),
            notes: [], questions: [], hypotheses: [],
            focusSets: [], sessions: []
        )
        let foundIDs = Set(doc.findings.map(\.id))
        #expect(foundIDs.contains("a"))
        #expect(!foundIDs.contains("m"))
    }

    // MARK: - Still open

    @Test func stillOpen_includesOpenQuestionsAndActiveHypotheses() {
        let snapshot = makeSnapshot([makeProfile(id: "a")])
        let openQ = makeQuestion(text: "Find parents", priority: .high, status: .open)
        let resolvedQ = makeQuestion(text: "Find spouse", status: .resolved,
                                     resolution: "Done.")
        let activeH = makeHypothesis(
            claim: .existence(description: "Younger sibling Sarah", relatedProfileIDs: ["a"])
        )
        let dismissedH = makeHypothesis(
            claim: .existence(description: "Younger sibling Tom", relatedProfileIDs: ["a"]),
            status: .dismissed,
            dismissal: "No record"
        )

        let doc = ResearchReportComposer.compose(
            focusSetID: nil,
            snapshot: snapshot,
            notes: [],
            questions: [openQ, resolvedQ],
            hypotheses: [activeH, dismissedH],
            focusSets: [], sessions: []
        )

        let joined = doc.stillOpen.joined(separator: "\n")
        #expect(joined.contains("Find parents"))
        #expect(!joined.contains("Find spouse"))
        #expect(joined.contains("Younger sibling Sarah"))
        #expect(!joined.contains("Younger sibling Tom"))
    }

    // MARK: - Markdown rendering

    @Test func markdown_startsWithTitle_andHasSectionsInOrder() {
        let snapshot = makeSnapshot([makeProfile(id: "a", first: "Ann")])
        let md = ResearchReport.renderMarkdown(
            focusSetID: nil,
            snapshot: snapshot,
            notes: [], questions: [], hypotheses: [],
            focusSets: [], sessions: []
        )
        #expect(md.hasPrefix("# Research Report"))

        // Required headers, in document order.
        let expected: [String] = [
            "## Scope",
            "## Questions investigated",
            "## Hypotheses",
            "## Findings",
            "## Still open",
            "## Sources consulted",
        ]
        var lastIndex = md.startIndex
        for header in expected {
            guard let range = md.range(of: header, range: lastIndex..<md.endIndex) else {
                Issue.record("Missing section header: \(header)")
                return
            }
            lastIndex = range.upperBound
        }
    }
}
