import Testing
import Foundation
@testable import Ancestor_Research

/// CONFLICT_LAYER_SPEC §4.2 — C2 detection rules shipped in CL1:
/// F1 (date fields), F2 (string/location fields), F4a (parent role),
/// F4b (spouse identity). Pure-function coverage; the apply-path wiring
/// is exercised in ApplyEngineConflictHookTests.
struct ConflictDetectorTests {

    // MARK: - F1 range relation

    @Test func identicalRangesAreNotAConflict() {
        // Two quarters inside one year share the (earliest, latest) window
        // — provably compatible at the model's year granularity.
        let r = ConflictDetector.relation(
            GenealogicalDate(parsing: "Mar 1900"),
            GenealogicalDate(parsing: "Sep 1900")
        )
        #expect(r == .identical)
    }

    @Test func strictContainmentIsRefinementNotConflict() {
        let r = ConflictDetector.relation(
            GenealogicalDate(parsing: "BET 1869 AND 1896"),
            GenealogicalDate(parsing: "Dec 1883")
        )
        #expect(r == .containment)
    }

    @Test func disjointRangesConflictWithGap() {
        let r = ConflictDetector.relation(
            GenealogicalDate(parsing: "1901"),
            GenealogicalDate(parsing: "Dec 1900")
        )
        #expect(r == .disjoint(gap: 1))
    }

    @Test func partialOverlapNeitherContainingIsAConflict() {
        let r = ConflictDetector.relation(
            GenealogicalDate(parsing: "BET 1900 AND 1902"),
            GenealogicalDate(parsing: "BET 1901 AND 1905")
        )
        #expect(r == .partialOverlap)
    }

    @Test func unparseableSideCannotProveAConflict() {
        let r = ConflictDetector.relation(
            GenealogicalDate(parsing: "?"),
            GenealogicalDate(parsing: "1900")
        )
        #expect(r == .unknown)
    }

    // MARK: - F1 detection

    /// DS-13's exact scenario: canonical '1901' (GEDCOM), incoming
    /// 'Dec 1900' (FreeBMD) — same span, disjoint years.
    @Test func ds13DeathDateScenarioProducesNoOverlapConflict() {
        let conflict = ConflictDetector.dateFieldConflict(
            field: .deathDate,
            existing: GenealogicalDate(parsing: "1901"),
            existingSources: [FieldSource(origin: .gedcom, raw: "1901", addedAt: Date())],
            candidate: GenealogicalDate(parsing: "Dec 1900"),
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict != nil)
        #expect(conflict?.kind == .fieldValue)
        #expect(conflict?.field == "deathDate")
        #expect(conflict?.reason == .noOverlap)
        #expect(conflict?.detectedBy == .applyEngine)
        // Both sides present: the attested 1901 row + the candidate.
        #expect(conflict?.competingSources.count == 2)
        #expect(conflict?.competingSources.contains { $0.raw == "1901" } == true)
        #expect(conflict?.competingSources.contains { $0.raw == "Dec 1900" } == true)
        #expect(conflict?.reasoning.isEmpty == false)
    }

    @Test func refinementProducesNoConflict() {
        // R1 filtered at detection: strictly-contained candidate never
        // opens a dispute.
        let conflict = ConflictDetector.dateFieldConflict(
            field: .birthDate,
            existing: GenealogicalDate(parsing: "BET 1869 AND 1896"),
            existingSources: [FieldSource(origin: .gedcom, raw: "BET 1869 AND 1896", addedAt: Date())],
            candidate: GenealogicalDate(parsing: "Dec 1883"),
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict == nil)
    }

    @Test func agreeingValueProducesNoConflict() {
        let conflict = ConflictDetector.dateFieldConflict(
            field: .deathDate,
            existing: GenealogicalDate(parsing: "1901"),
            existingSources: [FieldSource(origin: .gedcom, raw: "1901", addedAt: Date())],
            candidate: GenealogicalDate(parsing: "Mar 1901"),
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict == nil)
    }

    @Test func canonicalValueWithoutAttestationIsSynthesizedIntoCompetitors() {
        // Imports predating the provenance journal: canonical 1901 exists
        // but no field_sources row parses to it. The dispute must still
        // show both sides.
        let conflict = ConflictDetector.dateFieldConflict(
            field: .deathDate,
            existing: GenealogicalDate(parsing: "1901"),
            existingSources: [],
            candidate: GenealogicalDate(parsing: "Dec 1900"),
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict != nil)
        #expect(conflict?.competingSources.count == 2)
        #expect(conflict?.competingSources.contains {
            $0.raw == "1901" && $0.origin.identifier == "tree"
        } == true)
    }

    @Test func severityComesFromDiscrepancySeverityTable() {
        // Transcription tier, delta 1 → the table grades .none — the
        // dispute still opens (detection is range-based; severity is
        // grading, spec §4.2 note on DiscrepancySeverityTable).
        let delta1 = ConflictDetector.dateFieldConflict(
            field: .deathDate,
            existing: GenealogicalDate(parsing: "1901"),
            existingSources: [],
            candidate: GenealogicalDate(parsing: "1900"),
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(delta1?.severity == DiscrepancySeverityTable.severity(
            sourceID: "", sourceTier: .transcription, recordType: nil, absDelta: 1, convergence: .singleSource
        ).severity)

        // Transcription tier, delta 6 → .conflict.
        let delta6 = ConflictDetector.dateFieldConflict(
            field: .deathDate,
            existing: GenealogicalDate(parsing: "1907"),
            existingSources: [],
            candidate: GenealogicalDate(parsing: "1900"),
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(delta6?.severity == .conflict)
    }

    // MARK: - Interim trust-tier mapping parity (drift guard)

    @MainActor
    @Test func trustTierMappingMirrorsPluginDeclarations() {
        // The static origin→tier table must never drift from the source
        // plugins' declared trustTier (the values buildSourceInfoMap feeds
        // the severity table at run time).
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "freebmd") == FreeBMDSource().trustTier)
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "freecen") == FreeCenSource().trustTier)
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "freereg") == FreeREGSource().trustTier)
        // wirksworth: the PLUGIN is retired (SOURCE_WEIGHTING Change 0) but
        // persisted evidence keeps the origin id — the read-time tier
        // mapping must survive, pinned against the value the plugin
        // declared (.transcription).
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "wirksworth") == .transcription)
        // familysearch: same retired-plugin pattern (records leg deleted
        // 2026-07-21) — the read-time tier for persisted / enrichment FS
        // evidence survives, pinned to the value the plugin declared.
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "familysearch") == .transcription)
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "cwgc") == CWGCSource().trustTier)
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "probate") == ProbateSource().trustTier)
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "findagrave") == FindAGraveSource().trustTier)
        // Unknown identifiers grade community — the registry default.
        #expect(ConflictDetector.trustTier(forOriginIdentifier: "somewhere-new") == .community)
    }

    // MARK: - F2 detection

    @Test func normalisedEqualStringsProduceNoConflict() {
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "  BELPER,  Derbyshire ",
            existingSources: [],
            candidate: "belper, derbyshire",
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict == nil)
    }

    @Test func trailingCountyCollapseIsNotAConflict() {
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Belper",
            existingSources: [],
            candidate: "Belper, Derbyshire",
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict == nil)
    }

    @Test func differentPlacesSameCountyGradeNote() {
        // Belper and Bakewell both derive DBY via the district catalogue
        // → mismatch is a .note (census birthplace variance shape).
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Belper",
            existingSources: [FieldSource(origin: .gedcom, raw: "Belper", addedAt: Date())],
            candidate: "Bakewell",
            candidateOrigin: .freecen,
            profileID: "p1"
        )
        #expect(conflict != nil)
        #expect(conflict?.kind == .fieldValue)
        #expect(conflict?.reason == .valueMismatch)
        #expect(conflict?.severity == .note)
    }

    @Test func derivableCountiesDifferingUpgradeToConflict() {
        // Belper (DBY) vs Nottingham (NTT) — both derive via the catalogue,
        // counties differ → .conflict. No hardcoded regions: this is
        // catalogue data, not code. (Basford deliberately avoided as a
        // fixture: cross-border district whose catalogue chapman tag is
        // DBY — genuinely contested, so not an "uncontested counties
        // differ" pair.)
        let belper = ConflictDetector.chapmanCode(forPlaceText: "Belper")
        let nottingham = ConflictDetector.chapmanCode(forPlaceText: "Nottingham")
        // Guard the fixture: if the catalogue can't derive both, the
        // upgrade path can't be exercised with these names.
        guard let belper, let nottingham, belper != nottingham else {
            Issue.record("Catalogue fixture assumption failed: Belper→\(String(describing: belper)) Nottingham→\(String(describing: nottingham))")
            return
        }
        let conflict = ConflictDetector.stringFieldConflict(
            field: .birthLocation,
            existing: "Belper",
            existingSources: [],
            candidate: "Nottingham",
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict?.severity == .conflict)
        #expect(conflict?.reasoning.contains("counties differ") == true)
    }

    @Test func emptyOrNilExistingStringProducesNoConflict() {
        let conflict = ConflictDetector.stringFieldConflict(
            field: .deathLocation,
            existing: nil,
            existingSources: [],
            candidate: "Belper",
            candidateOrigin: .freebmd,
            profileID: "p1"
        )
        #expect(conflict == nil)
    }

    // MARK: - F4a occupied-role predicate

    private func makeProfile(id: String, first: String? = nil, last: String?, gender: Gender) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: last,
            gender: gender, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func parentEdge(from: String, to: String, role: ParentRole, subtype: RelationshipSubtype = .biological) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to, type: .parent, role: role,
            subtype: subtype, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    @Test func occupiedRoleDetectsExistingBiologicalMother() {
        let subject = makeProfile(id: "s", last: "Cauldwell", gender: .male)
        let mother = makeProfile(id: "m", first: "Mary", last: "Bown", gender: .female)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["s": subject, "m": mother],
            relationships: [parentEdge(from: "m", to: "s", role: .mother)]
        )
        let occupied = ConflictDetector.occupiedBiologicalRole(
            subjectID: "s", role: .mother, excludingParentID: nil, snapshot: snapshot
        )
        #expect(occupied?.occupant.id == "m")
        let warning = occupied.map {
            ConflictDetector.parentRoleWarning(role: .mother, occupant: $0.occupant)
        }
        #expect(warning == "Subject already has a mother: Mary Bown")
    }

    @Test func occupiedRoleExcludesTheParentBeingAccepted() {
        // Re-accepting the SAME parent (dedup matched the occupant) is
        // idempotent, never a conflict.
        let subject = makeProfile(id: "s", last: "Cauldwell", gender: .male)
        let mother = makeProfile(id: "m", first: "Mary", last: "Bown", gender: .female)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["s": subject, "m": mother],
            relationships: [parentEdge(from: "m", to: "s", role: .mother)]
        )
        let occupied = ConflictDetector.occupiedBiologicalRole(
            subjectID: "s", role: .mother, excludingParentID: "m", snapshot: snapshot
        )
        #expect(occupied == nil)
    }

    @Test func occupiedRoleIgnoresNonBiologicalEdgesAndOtherRoles() {
        let subject = makeProfile(id: "s", last: "Cauldwell", gender: .male)
        let step = makeProfile(id: "sm", first: "Ann", last: "Step", gender: .female)
        let father = makeProfile(id: "f", first: "John", last: "Cauldwell", gender: .male)
        let snapshot = FamilyGraphSnapshot(
            profiles: ["s": subject, "sm": step, "f": father],
            relationships: [
                parentEdge(from: "sm", to: "s", role: .mother, subtype: .step),
                parentEdge(from: "f", to: "s", role: .father),
            ]
        )
        #expect(ConflictDetector.occupiedBiologicalRole(
            subjectID: "s", role: .mother, excludingParentID: nil, snapshot: snapshot
        ) == nil)
        #expect(ConflictDetector.occupiedBiologicalRole(
            subjectID: "s", role: .unspecified, excludingParentID: nil, snapshot: snapshot
        ) == nil)
    }

    @Test func parentRoleConflictCarriesBothIdentitiesAndReferences() {
        let subject = makeProfile(id: "s", last: "Cauldwell", gender: .male)
        let mother = makeProfile(id: "m", first: "Mary", last: "Bown", gender: .female)
        let edge = parentEdge(from: "m", to: "s", role: .mother)
        let conflict = ConflictDetector.parentRoleConflict(
            subjectID: "s", role: .mother,
            occupant: mother, occupantEdge: edge,
            proposedParentDescription: "Sarah Land",
            proposedParentOrigin: .freebmd,
            evidenceRecordIDs: ["rec1"]
        )
        #expect(conflict.kind == .parentRole)
        #expect(conflict.field == "mother")
        #expect(conflict.severity == .conflict)
        // ⟨G11⟩ the tree is a witness too — incumbent listed beside rival.
        #expect(conflict.competingSources.contains { $0.origin.identifier == "tree" && $0.raw.contains("Mary Bown") })
        #expect(conflict.competingSources.contains { $0.raw.contains("Sarah Land") })
        #expect(conflict.evidenceJSON?.contains(edge.id.uuidString) == true)
        #expect(conflict.evidenceJSON?.contains("rec1") == true)
        _ = subject
    }

    // MARK: - F4b spouse identity

    @Test func spouseIdentityConflictAgainstKnownSpouseGradesConflict() {
        let subject = makeProfile(id: "s", first: "Ernest", last: "Cauldwell", gender: .male)
        let wife = makeProfile(id: "w", first: "Gertrude", last: "Jones", gender: .female)
        let edge = Relationship(
            id: UUID(), from: "s", to: "w", type: .spouse, role: nil,
            subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snapshot = FamilyGraphSnapshot(
            profiles: ["s": subject, "w": wife], relationships: [edge]
        )
        let m = MarriageRecord(
            common: RecordCommon(id: "m1", sourceID: "freebmd", rawFields: [:]),
            marriageYear: 1921, marriageDate: nil, marriagePlace: nil,
            quarter: "Jun", district: "Belper", volume: "7b", page: "1402",
            spouseName: "SMITH"
        )
        let conflict = ConflictDetector.spouseIdentityConflict(
            marriage: m, recordSpouseSurname: "SMITH",
            profileID: "s", spouseEdges: [edge], snapshot: snapshot,
            origin: .freebmd
        )
        #expect(conflict.kind == .spouseIdentity)
        #expect(conflict.field == "spouse")
        #expect(conflict.severity == .conflict)
        #expect(conflict.competingSources.contains { $0.raw.contains("SMITH") })
        #expect(conflict.competingSources.contains { $0.raw.contains("Gertrude Jones") })
        #expect(conflict.evidenceJSON?.contains("m1") == true)
        #expect(conflict.reasoning.contains("DS-12"))
    }

    @Test func spouseIdentityWithNoSpouseEdgesGradesNote() {
        let subject = makeProfile(id: "s", first: "Ernest", last: "Cauldwell", gender: .male)
        let snapshot = FamilyGraphSnapshot(profiles: ["s": subject], relationships: [])
        let m = MarriageRecord(
            common: RecordCommon(id: "m1", sourceID: "freebmd", rawFields: [:]),
            marriageYear: 1921, marriageDate: nil, marriagePlace: nil,
            quarter: nil, district: nil, volume: nil, page: nil,
            spouseName: "SMITH"
        )
        let conflict = ConflictDetector.spouseIdentityConflict(
            marriage: m, recordSpouseSurname: "SMITH",
            profileID: "s", spouseEdges: [], snapshot: snapshot,
            origin: .freebmd
        )
        #expect(conflict.severity == .note)
    }
}
