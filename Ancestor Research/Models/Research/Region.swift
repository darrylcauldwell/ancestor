import Foundation

/// Geographic region for source coverage and filtering.
nonisolated enum Region: Hashable, Codable, Sendable {
    case englandAndWales
    case scotland
    case ireland
    case commonwealthMilitary
    case county(String)              // "Derbyshire"
    case parish(String, county: String)
}
