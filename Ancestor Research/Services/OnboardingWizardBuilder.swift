import Foundation

/// Pure-logic translator from onboarding-wizard input data into the
/// (profiles, relationships) tuple that AppState.addFamily expects.
/// Lives here, not inside the SwiftUI view, so it can be unit-tested.
nonisolated enum OnboardingWizardBuilder {

    /// Family-structure variant chosen at Step 0.
    enum Structure: Sendable {
        case standard       // Default — biological parents
        case adopted        // Adoptive parents (with optional biological alongside)
        case divorced       // Two parent couples (biological + step)
        // .complicated routes around the wizard entirely; not represented here.
    }

    /// Single-person input from any wizard step. Empty fields → unknown.
    /// `id` is stable across edits so SwiftUI ForEach can iterate child rows safely.
    struct PersonInput: Sendable, Identifiable {
        let id: UUID
        var firstName: String
        var middleName: String
        var lastName: String
        var gender: Gender?
        var birthDateText: String
        var birthLocation: String
        /// Structured place ID picked from the gazetteer (e.g. "DBY:Crich").
        /// nil for freeform entries that didn't match any gazetteer place.
        var birthLocationCode: String?

        init(
            id: UUID = UUID(),
            firstName: String, middleName: String = "", lastName: String, gender: Gender?,
            birthDateText: String, birthLocation: String,
            birthLocationCode: String? = nil
        ) {
            self.id = id
            self.firstName = firstName
            self.middleName = middleName
            self.lastName = lastName
            self.gender = gender
            self.birthDateText = birthDateText
            self.birthLocation = birthLocation
            self.birthLocationCode = birthLocationCode
        }

        var isPopulated: Bool {
            AutoSuggestService.normaliseName(firstName) != nil ||
                AutoSuggestService.normaliseName(middleName) != nil ||
                AutoSuggestService.normaliseName(lastName) != nil ||
                !birthDateText.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// All wizard input rolled into one struct so the builder is referentially transparent.
    struct Input: Sendable {
        var structure: Structure = .standard
        var you: PersonInput
        var father: PersonInput
        var mother: PersonInput
        var marriageDateText: String = ""
        var marriageLocation: String = ""
        var marriageLocationCode: String? = nil
        /// Optional third parent — surfaced via the wizard's "Add stepparent"
        /// button (DESIGN.md §7.5.1). When populated, attaches as a parent
        /// edge with `RelationshipSubtype.step`.
        var stepparent: PersonInput?
        var paternalGrandfather: PersonInput
        var paternalGrandmother: PersonInput
        var maternalGrandfather: PersonInput
        var maternalGrandmother: PersonInput
        var includeSpouseAndChildren: Bool = false
        var spouse: PersonInput
        var spouseMarriageDateText: String = ""
        var children: [PersonInput] = []

        /// Empty defaults — the wizard view starts every field blank.
        static var blank: Input {
            let empty = PersonInput(firstName: "", lastName: "", gender: nil,
                                    birthDateText: "", birthLocation: "")
            return Input(
                you: empty, father: empty, mother: empty,
                stepparent: nil,
                paternalGrandfather: empty, paternalGrandmother: empty,
                maternalGrandfather: empty, maternalGrandmother: empty,
                spouse: empty
            )
        }
    }

    /// Output of the builder — what AppState.addFamily and homePersonID need.
    struct Result: Sendable {
        let profiles: [Profile]
        let relationships: [Relationship]
        let homePersonID: String
        /// Default source for the addFamily transaction. Wired from
        /// `SourceDefaults.defaultSource(context: .homePerson)` so the
        /// wizard's persisted source is no longer hardcoded — kept as a
        /// computed default so future contexts (memory vs document) can
        /// flow through without changing the caller.
        let defaultSource: SourceOrigin
    }

    /// Build the result. Skipped steps simply omit profiles — the home person
    /// is always created. Returns nil if the user did not provide enough
    /// information to identify themselves (no name, no birth date).
    static func build(_ input: Input) -> Result? {
        guard input.you.isPopulated else { return nil }

        var profiles: [Profile] = []
        var relationships: [Relationship] = []

        // Step 1: home person
        let homeID = UUID().uuidString
        let homeProfile = makeProfile(id: homeID, from: input.you)
        profiles.append(homeProfile)

        // Step 2: parents
        let fatherID = appendIfPopulated(input.father, gender: .male, into: &profiles)
        let motherID = appendIfPopulated(input.mother, gender: .female, into: &profiles)

        // Subtype reflects the structural variant chosen in Step 0.
        let parentSubtype: RelationshipSubtype = input.structure == .adopted ? .adoptive : .biological

        if let fatherID {
            relationships.append(parentEdge(from: fatherID, to: homeID, role: .father, subtype: parentSubtype))
        }
        if let motherID {
            relationships.append(parentEdge(from: motherID, to: homeID, role: .mother, subtype: parentSubtype))
        }
        if let fatherID, let motherID {
            relationships.append(spouseEdge(
                a: fatherID, b: motherID,
                marriageDateText: input.marriageDateText,
                marriageLocation: input.marriageLocation,
                marriageLocationCode: input.marriageLocationCode
            ))
        }

        // Step 2 (extension): optional stepparent. Always attached with
        // RelationshipSubtype.step regardless of the structural variant —
        // the user explicitly tapped "Add stepparent" so the intent is
        // unambiguous. ParentRole is inferred from the supplied gender;
        // unknown gender falls through as .unspecified rather than guessed.
        if let stepparentInput = input.stepparent, stepparentInput.isPopulated {
            let stepID = UUID().uuidString
            profiles.append(makeProfile(id: stepID, from: stepparentInput))
            relationships.append(parentEdge(
                from: stepID, to: homeID,
                role: roleFor(stepparentInput.gender),
                subtype: .step
            ))
        }

        // Step 3a: paternal grandparents — only attach if father exists
        if let fatherID {
            let pgfID = appendIfPopulated(input.paternalGrandfather, gender: .male, into: &profiles)
            let pgmID = appendIfPopulated(input.paternalGrandmother, gender: .female, into: &profiles)
            if let pgfID {
                relationships.append(parentEdge(from: pgfID, to: fatherID, role: .father, subtype: .biological))
            }
            if let pgmID {
                relationships.append(parentEdge(from: pgmID, to: fatherID, role: .mother, subtype: .biological))
            }
            if let pgfID, let pgmID {
                relationships.append(spouseEdge(a: pgfID, b: pgmID, marriageDateText: "", marriageLocation: ""))
            }
        }

        // Step 3b: maternal grandparents — only attach if mother exists
        if let motherID {
            let mgfID = appendIfPopulated(input.maternalGrandfather, gender: .male, into: &profiles)
            let mgmID = appendIfPopulated(input.maternalGrandmother, gender: .female, into: &profiles)
            if let mgfID {
                relationships.append(parentEdge(from: mgfID, to: motherID, role: .father, subtype: .biological))
            }
            if let mgmID {
                relationships.append(parentEdge(from: mgmID, to: motherID, role: .mother, subtype: .biological))
            }
            if let mgfID, let mgmID {
                relationships.append(spouseEdge(a: mgfID, b: mgmID, marriageDateText: "", marriageLocation: ""))
            }
        }

        // Step 4: spouse + children (optional)
        if input.includeSpouseAndChildren {
            let spouseID = appendIfPopulated(input.spouse, gender: nil, into: &profiles)
            if let spouseID {
                relationships.append(spouseEdge(
                    a: homeID, b: spouseID,
                    marriageDateText: input.spouseMarriageDateText,
                    marriageLocation: ""
                ))
            }
            for child in input.children where child.isPopulated {
                let childID = UUID().uuidString
                profiles.append(makeProfile(id: childID, from: child))
                relationships.append(parentEdge(
                    from: homeID, to: childID,
                    role: roleFor(homeProfile.gender), subtype: .biological
                ))
                if let spouseID {
                    relationships.append(parentEdge(
                        from: spouseID, to: childID,
                        role: roleFor(input.spouse.gender), subtype: .biological
                    ))
                }
            }
        }

        // Wizard step 1 is the home person; `SourceDefaults` returns
        // `.manualMemory` for that context. Routed through the helper
        // (rather than hardcoded) so changing the default is a one-line
        // edit in `SourceDefaults`. Step 2/3/4 contexts (.relativeOf,
        // .grandparent) all also resolve to `.manualMemory` today, so
        // a single source for the batch is faithful — see DESIGN.md
        // §7.5.9.
        let source = SourceDefaults.defaultSource(context: .homePerson)
        return Result(
            profiles: profiles,
            relationships: relationships,
            homePersonID: homeID,
            defaultSource: source
        )
    }

    // MARK: - Private helpers

    private static func appendIfPopulated(
        _ input: PersonInput,
        gender: Gender?,
        into profiles: inout [Profile]
    ) -> String? {
        guard input.isPopulated else { return nil }
        let id = UUID().uuidString
        profiles.append(makeProfile(id: id, from: input, fallbackGender: gender))
        return id
    }

    private static func makeProfile(
        id: String,
        from input: PersonInput,
        fallbackGender: Gender? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: AutoSuggestService.normaliseName(input.firstName),
            middleName: AutoSuggestService.normaliseName(input.middleName),
            lastName: AutoSuggestService.normaliseName(input.lastName),
            gender: input.gender ?? fallbackGender,
            attributes: nil,
            birthDate: GenealogicalDate.parsePreview(input.birthDateText).parsed,
            birthLocation: AutoSuggestService.normaliseName(input.birthLocation),
            birthLocationCode: input.birthLocationCode,
            deathDate: nil,
            deathLocation: nil,
            deathLocationCode: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private static func parentEdge(
        from: String, to: String,
        role: ParentRole, subtype: RelationshipSubtype
    ) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: role, subtype: subtype,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private static func spouseEdge(
        a: String, b: String,
        marriageDateText: String,
        marriageLocation: String,
        marriageLocationCode: String? = nil
    ) -> Relationship {
        Relationship(
            id: UUID(), from: a, to: b,
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: GenealogicalDate.parsePreview(marriageDateText).parsed,
            marriageLocation: AutoSuggestService.normaliseName(marriageLocation),
            marriageLocationCode: marriageLocationCode,
            divorceDate: nil
        )
    }

    private static func roleFor(_ gender: Gender?) -> ParentRole {
        switch gender {
        case .female: return .mother
        case .male: return .father
        default: return .unspecified
        }
    }
}
