import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Drop-trace finding 2026-07-30: FreeREG returns `.parish` records for
/// EVERY dispatched record type, so the stage ladder's survivors check
/// (`record.recordType == dispatchedType`) could never see a FreeREG hit
/// under its own target — real marriage/baptism hits read as "genuine
/// miss" and the ladder widened on a lie. `recordSatisfies` maps parish
/// EVENTS onto their dispatched targets.
struct StageLadderSatisfactionTests {

    private func parish(eventType: String?) -> SourceRecord {
        .parish(ParishRecord(
            common: RecordCommon(id: "freereg_t1", sourceID: "freereg", rawFields: [:]),
            eventType: eventType, eventYear: 1896
        ))
    }

    @Test func parishMarriageSatisfiesMarriageTarget() {
        #expect(ResearchPipeline.recordSatisfies(parish(eventType: "marriage"), dispatchedType: .marriage))
    }

    @Test func parishBaptismSatisfiesBaptismAndChristening() {
        #expect(ResearchPipeline.recordSatisfies(parish(eventType: "baptism"), dispatchedType: .baptism))
        #expect(ResearchPipeline.recordSatisfies(parish(eventType: "christening"), dispatchedType: .christening))
        #expect(ResearchPipeline.recordSatisfies(parish(eventType: "baptism"), dispatchedType: .christening))
    }

    @Test func parishBurialSatisfiesBurialTarget() {
        #expect(ResearchPipeline.recordSatisfies(parish(eventType: "burial"), dispatchedType: .burial))
    }

    @Test func parishUmbrellaAcceptsAnyParishRecord() {
        #expect(ResearchPipeline.recordSatisfies(parish(eventType: "marriage"), dispatchedType: .parish))
        #expect(ResearchPipeline.recordSatisfies(parish(eventType: nil), dispatchedType: .parish))
    }

    @Test func crossEventParishDoesNotLeakAcrossTargets() {
        #expect(!ResearchPipeline.recordSatisfies(parish(eventType: "marriage"), dispatchedType: .baptism))
        #expect(!ResearchPipeline.recordSatisfies(parish(eventType: "burial"), dispatchedType: .marriage))
        #expect(!ResearchPipeline.recordSatisfies(parish(eventType: nil), dispatchedType: .marriage),
                "an untyped parish record must not satisfy a specific event target")
    }

    @Test func nonParishTypesRemainExactMatch() {
        let birth = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b1", sourceID: "freebmd", rawFields: [:]),
            birthYear: 1875))
        #expect(ResearchPipeline.recordSatisfies(birth, dispatchedType: .birth))
        #expect(!ResearchPipeline.recordSatisfies(birth, dispatchedType: .baptism))
    }
}
