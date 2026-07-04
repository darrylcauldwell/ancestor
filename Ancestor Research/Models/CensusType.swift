import Foundation

/// Catalogue of UK decennial censuses we can transcribe via the
/// AddFamilyView "Transcribing a census record?" mode (M16.4).
///
/// `.other` is a free-form escape hatch — when picked, the user types
/// the year manually. The known cases auto-fill their year so the
/// common path is one click.
nonisolated enum CensusType: String, CaseIterable, Sendable, Identifiable {
    case census1841
    case census1851
    case census1861
    case census1871
    case census1881
    case census1891
    case census1901
    case census1911
    case census1921
    case other

    var id: String { rawValue }

    /// Display label for the picker.
    var displayName: String {
        switch self {
        case .census1841: return "1841"
        case .census1851: return "1851"
        case .census1861: return "1861"
        case .census1871: return "1871"
        case .census1881: return "1881"
        case .census1891: return "1891"
        case .census1901: return "1901"
        case .census1911: return "1911"
        case .census1921: return "1921"
        case .other: return "Other"
        }
    }

    /// Year associated with the census type. `.other` returns nil so
    /// the form falls back to the user-typed value.
    var year: Int? {
        switch self {
        case .census1841: return 1841
        case .census1851: return 1851
        case .census1861: return 1861
        case .census1871: return 1871
        case .census1881: return 1881
        case .census1891: return 1891
        case .census1901: return 1901
        case .census1911: return 1911
        case .census1921: return 1921
        case .other: return nil
        }
    }

    /// Pure helper — birth year inferred from age at census. Tolerance is
    /// always ±1 year (the census date isn't your birthday) and is the
    /// caller's concern; this just does the arithmetic.
    nonisolated static func computeBirthYear(censusYear: Int, ageAtCensus: Int) -> Int {
        censusYear - ageAtCensus
    }
}
