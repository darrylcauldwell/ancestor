import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Location model Part II Slice E's deferred local-model tier.
///
/// The model is never asked an open question. It is handed the closed list of
/// parishes in the county the text names and told to pick one or decline —
/// because "which parish is Pilhough in?" produces a confident invention that
/// nothing downstream can test, the hamlet being exactly what the authority does
/// not contain. Everything safety-critical here is pure and tested without a
/// model loaded.
@MainActor
struct PlaceProposerTests {

    private func offered(_ text: String, year: Int? = 1861) -> (chapman: String, parishes: [String]) {
        PlaceProposer.offeredParishes(for: text, year: year) ?? ("", [])
    }

    // MARK: - The closed list

    @Test func theListIsTheStatedCountysParishes() {
        let (chapman, parishes) = offered("Pilhough, Derbyshire")
        #expect(chapman == "DBY")
        #expect(parishes.count > 100, "got \(parishes.count)")
        #expect(parishes.contains("Youlgreave"))
        #expect(!parishes.contains { $0 == "Warslow & Elkstones" }, "that is Staffordshire")
    }

    /// No stated county means no closed list, which means the only question we
    /// could ask is an open one. We decline instead.
    @Test func withoutACountyThereIsNoListAndNoQuestion() async {
        #expect(PlaceProposer.offeredParishes(for: "Darley Hall", year: 1861) == nil)
        let result = await PlaceProposer.propose(for: "Darley Hall", year: 1861)
        // nil = no model loaded (the usual case in tests); otherwise it must be
        // the refusal, never an answer.
        if let result {
            #expect(result == .failure(.noStatedCounty))
        }
    }

    @Test func theListIsEraFiltered() {
        let victorian = Set(offered("Pilhough, Derbyshire", year: 1861).parishes)
        let modern = Set(offered("Pilhough, Derbyshire", year: 2000).parishes)
        #expect(victorian != modern, "district validity windows must reach the parish list")
    }

    // MARK: - The prompt

    @Test func thePromptCarriesTheWholeListAndForbidsInvention() {
        let text = "Pilhough, Derbyshire"
        let (_, parishes) = offered(text)
        let prompt = PlaceProposer.prompt(for: text, county: "Derbyshire", parishes: parishes)

        #expect(prompt.contains(text))
        #expect(prompt.contains("Youlgreave"), "the list itself must be in the prompt")
        #expect(prompt.contains("Do not invent"))
        #expect(prompt.contains("copied exactly from the list"))
        #expect(prompt.contains("If you do not know"), "declining must be an offered answer")
    }

    // MARK: - Verification — where the safety lives

    /// The property this whole tier rests on.
    @Test func aParishTheModelInventedIsRejected() {
        let result = PlaceProposer.verify(
            ["parish": "Notaplace Magna", "confidence": "high", "reason": "I am certain."],
            text: "Pilhough, Derbyshire", offered: ["Youlgreave", "Bakewell"],
            chapman: "DBY", year: 1861)
        #expect(result == .failure(.parishNotOffered),
                "a confident invention is still an invention")
    }

    /// Near-misses are inventions too. "Stanton by Bridge" and "Stanton in Peak"
    /// are twenty miles apart; fuzzy acceptance would re-admit exactly what the
    /// closed list exists to prevent.
    @Test func aNearMissIsNotAccepted() {
        let result = PlaceProposer.verify(
            ["parish": "Stanton by Bridge"],
            text: "Pilhough, Derbyshire", offered: ["Stanton in Peak"],
            chapman: "DBY", year: 1861)
        #expect(result == .failure(.parishNotOffered))
    }

    @Test func decliningIsAccepted() {
        #expect(PlaceProposer.verify(
            ["parish": NSNull(), "reason": "Not enough to go on."],
            text: "X, Derbyshire", offered: ["Youlgreave"], chapman: "DBY", year: 1861)
            == .failure(.noAnswer))

        #expect(PlaceProposer.verify(
            [:], text: "X, Derbyshire", offered: ["Youlgreave"], chapman: "DBY", year: 1861)
            == .failure(.noAnswer))
    }

    @Test func anOfferedParishResolvesToItsDistrict() {
        let result = PlaceProposer.verify(
            ["parish": "Youlgreave", "confidence": "medium", "reason": "Pilhough is a hamlet there."],
            text: "Pilhough, Derbyshire", offered: offered("Pilhough, Derbyshire").parishes,
            chapman: "DBY", year: 1861)

        guard case .success(let proposal) = result else {
            Issue.record("expected success, got \(result)"); return
        }
        #expect(proposal.parish == "Youlgreave")
        #expect(proposal.districtID.hasPrefix("DBY:"))
        #expect(proposal.text == "Pilhough, Derbyshire")
    }

    /// The model's own words are carried through verbatim. A suggestion with no
    /// stated reasoning is not reviewable, and this tier is only safe reviewed.
    @Test func theRationaleIsCarriedThrough() {
        let result = PlaceProposer.verify(
            ["parish": "Youlgreave", "confidence": "low", "reason": "Only spelling similarity."],
            text: "Pilhough, Derbyshire", offered: ["Youlgreave"], chapman: "DBY", year: 1861)
        guard case .success(let proposal) = result else { Issue.record("\(result)"); return }
        #expect(proposal.rationale.contains("Only spelling similarity"))
        #expect(proposal.rationale.contains("low"), "the model's own confidence must survive")
    }

    /// Matching is case-insensitive but exact in substance — a model that
    /// lowercases its answer has still picked from the list.
    @Test func caseDiffersButTheChoiceStands() {
        let result = PlaceProposer.verify(
            ["parish": "youlgreave"], text: "Pilhough, Derbyshire",
            offered: ["Youlgreave"], chapman: "DBY", year: 1861)
        guard case .success(let proposal) = result else { Issue.record("\(result)"); return }
        #expect(proposal.parish == "Youlgreave", "the catalogue's spelling wins")
    }

    // MARK: - No model, no problem

    /// Every path in this app works with no model loaded, and this one is no
    /// exception: nil, never a fabricated answer.
    @Test func withNoModelLoadedItReturnsNothing() async {
        let result = await PlaceProposer.propose(for: "Pilhough, Derbyshire", year: 1861)
        if await !LocalInferenceService.shared.isAvailable {
            #expect(result == nil)
        }
    }
}
