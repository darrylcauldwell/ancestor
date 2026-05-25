import Foundation

/// Third axis on a research run — what *kind* of evidence to dispatch
/// for. Orthogonal to `ResearchMode` (depth) and `ResearchScope`
/// (geography). When set, `ResearchState.init(subject:)` narrows
/// `activeRecordTypes` to `focus.recordTypes`; when nil, the full
/// record-type set is used (today's behaviour).
///
/// See RESEARCH_PIPELINE_SPEC §11.4.
nonisolated enum ResearchFocus: String, Sendable, CaseIterable {
    case parents
    case siblings
    case marriages
    case death
    case birth
    case children
    case occupation

    /// Record types this focus expands to. Macros (`.parents`,
    /// `.children`) include multiple types because the genealogical
    /// task isn't single-source.
    var recordTypes: Set<RecordType> {
        switch self {
        case .parents:    return [.birth, .census, .baptism]
        case .siblings:   return [.birth]
        case .marriages:  return [.marriage]
        case .death:      return [.death, .burial, .probate, .military]
        case .birth:      return [.birth, .baptism]
        case .children:   return [.marriage, .census]
        case .occupation: return [.census, .probate]
        }
    }

    /// Short, action-shaped UI label — used on the per-gap Research
    /// button in `SharedProfileLayout.missingFactsSection` so the user
    /// sees "Research parents" rather than the generic "Research".
    var actionLabel: String {
        switch self {
        case .parents:    return "Research parents"
        case .siblings:   return "Research siblings"
        case .marriages:  return "Research marriages"
        case .death:      return "Research death"
        case .birth:      return "Research birth"
        case .children:   return "Research children"
        case .occupation: return "Research occupation"
        }
    }
}

extension CompletenessCheck {
    /// Maps a missing-fact item to the research focus that targets it.
    /// Returns nil for identity / structural fields that aren't
    /// research-targetable (firstName, gender, bio, etc.).
    var researchFocus: ResearchFocus? {
        switch self {
        case .hasParents: return .parents
        case .field(let field):
            switch field {
            case .birthDate, .birthLocation: return .birth
            case .deathDate, .deathLocation: return .death
            case .marriedSurname:            return .marriages
            case .mothersMaidenName:         return .parents
            case .firstName, .middleName, .lastName, .nickName, .gender, .bio:
                // Identity fields aren't engine-researchable. Bio is
                // deferred behind PROSE_CORPUS Phase B.
                return nil
            }
        }
    }
}
