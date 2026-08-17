import Foundation
import AncestorKit
import os

/// LOCATION_MODEL_SPEC Part II Slice E's deferred tier — the local-model proposer
/// for places the deterministic resolver cannot settle.
///
/// The catalogue lists *parishes*. A tree is full of hamlets, farms and bridges
/// that sit inside one — Pilhough, Priestcliffe, Bolehill, Darley Bridge — and
/// none of them resolve, so the Places tab shows them unresolved with nothing to
/// offer. This asks the local model which parish a hamlet belongs to.
///
/// **The model is never asked an open question.** It is handed the closed list of
/// parishes in the county the text itself names and told to pick one or decline.
/// That is the whole safety design, and it is what makes the answer checkable:
/// an open "which parish is Pilhough in?" produces a confident invention that
/// nothing downstream can test, because the hamlet is precisely what the
/// authority does not contain. A choice from a supplied list can be verified
/// against that list, and is rejected outright when it is not on it.
///
/// Nothing here writes. A proposal is a suggestion in the Places tab that a
/// person accepts or ignores, labelled as model-suggested — so this composes with
/// the tiered rule (deterministic first, model only at the wall, rules validate,
/// human decides) rather than bypassing it.
nonisolated enum PlaceProposer {

    private static let logger = Logger(subsystem: "dev.dreamfold.AncestorResearch", category: "PlaceProposer")

    /// A parish the model picked, already checked against the catalogue.
    struct Proposal: Sendable, Equatable, Identifiable {
        /// The location text this answers.
        let id: String
        var text: String { id }
        /// The catalogue parish chosen — guaranteed to be one we offered.
        let parish: String
        /// The registration district that parish resolves to.
        let districtID: String
        let districtName: String
        /// The model's own words, shown verbatim. A suggestion with no stated
        /// reasoning is not reviewable, and this tier is only safe because it is
        /// reviewed.
        let rationale: String
    }

    /// Why a proposal was refused. Every one of these is a refusal to show the
    /// user something unverifiable.
    enum Rejection: String, Error, Sendable, Equatable {
        /// The text states no county, so there is no closed list to choose from.
        /// Asking without one is an open question, which is the thing we do not do.
        case noStatedCounty
        /// The model named a parish that was not on the list it was given.
        case parishNotOffered
        /// The model declined, or answered in a shape we could not read.
        case noAnswer
        /// The parish is real but does not resolve to a district for this year.
        case parishHasNoDistrict
    }

    // MARK: - The closed list

    /// Every parish in the county a place string names, era-filtered. Empty when
    /// the string states no county.
    static func offeredParishes(for text: String, year: Int?) -> (chapman: String, parishes: [String])? {
        let scope = RegistrationDistrictResolver.statedChapmanScope(in: text)
        guard let chapman = scope.first else { return nil }
        let places = PlaceAuthorityRegistry.shared.places
        var names: Set<String> = []
        for code in scope {
            for district in places.districts(inCounty: code) {
                guard year.map({ district.valid(in: $0) }) ?? true else { continue }
                for parish in places.parishes(inDistrict: district.id, year: year) {
                    names.insert(parish.name)
                }
            }
        }
        return (chapman, names.sorted())
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You are a British genealogy assistant with knowledge of historical English \
    settlements. You answer only with JSON. You never invent place names: you \
    choose from the list you are given, or you decline.
    """

    static func prompt(for text: String, county: String, parishes: [String]) -> String {
        """
        A family tree records this place: "\(text)"

        It is not itself a parish. It is probably a hamlet, farm, house, bridge \
        or district within one of the civil parishes of \(county) listed below.

        Which of these parishes contains it?

        PARISHES:
        \(parishes.joined(separator: "\n"))

        Answer with JSON only:
        {"parish": "<exactly one name copied from the list above>", "confidence": "high|medium|low", "reason": "<one sentence>"}

        If you do not know, or the place is not in \(county), answer:
        {"parish": null, "confidence": "low", "reason": "<why>"}

        Rules:
        - The parish MUST be copied exactly from the list. Do not invent one.
        - Do not guess from spelling similarity alone; say so if that is all you have.
        """
    }

    // MARK: - Verification

    /// Check a model answer against the list it was given and the catalogue.
    /// Pure — this is where the safety lives, so it is unit-tested without a model.
    static func verify(
        _ answer: [String: Any], text: String, offered: [String],
        chapman: String, year: Int?
    ) -> Result<Proposal, Rejection> {
        guard let parish = answer["parish"] as? String,
              !parish.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(.noAnswer)
        }
        // The one check that matters: it must be on the list we supplied. A
        // near-match is not accepted — "Stanton by Bridge" for "Stanton in Peak"
        // is a different village, and fuzzy acceptance here would re-admit
        // exactly the invention the closed list exists to prevent.
        guard let matched = offered.first(where: { $0.caseInsensitiveCompare(parish) == .orderedSame }) else {
            logger.warning("model proposed a parish that was not offered")
            return .failure(.parishNotOffered)
        }
        let districts = PlaceAuthorityRegistry.shared.places
            .districts(forParish: matched, year: year, chapman: chapman)
        guard let district = districts.first else { return .failure(.parishHasNoDistrict) }

        let reason = (answer["reason"] as? String) ?? ""
        let confidence = (answer["confidence"] as? String) ?? "unknown"
        return .success(Proposal(
            id: text, parish: matched, districtID: district.id, districtName: district.name,
            rationale: reason.isEmpty ? "No reason given (\(confidence) confidence)."
                                      : "\(reason) (\(confidence) confidence)"))
    }

    // MARK: - Ask

    /// Ask the local model. Returns nil when no model is loaded — every path in
    /// this app works with no model at all, and this one is no exception.
    static func propose(for text: String, year: Int?) async -> Result<Proposal, Rejection>? {
        guard await LocalInferenceService.shared.isAvailable else { return nil }
        guard let (chapman, parishes) = offeredParishes(for: text, year: year), !parishes.isEmpty else {
            return .failure(.noStatedCounty)
        }
        let county = PlaceAuthorityRegistry.shared.places.place(id: chapman)?.name ?? chapman
        // `reason` + `extractJSONDictionary` rather than `reasonJSON`: the actor
        // returns `Any?`, which is not Sendable and cannot cross back out to a
        // nonisolated caller. The house pattern (ResearchInterpreter,
        // ClusterAdjudicator, ProseCorpusExtractor) takes the String across and
        // parses on this side.
        guard let raw = await LocalInferenceService.shared.reason(
            prompt: prompt(for: text, county: county, parishes: parishes),
            systemPrompt: systemPrompt,
            maxTokens: 256
        ), let answer = LocalInferenceService.extractJSONDictionary(from: raw) else {
            return .failure(.noAnswer)
        }
        return verify(answer, text: text, offered: parishes, chapman: chapman, year: year)
    }
}
