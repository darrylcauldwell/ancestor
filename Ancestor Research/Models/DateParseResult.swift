/// Result of parsing a date string — used for live preview in date input fields.
nonisolated struct DateParseResult: Sendable {
    let displayText: String         // Human-readable interpretation
    let isValid: Bool               // Whether the input was parseable
    let parsed: GenealogicalDate?   // The parsed date, if valid
}
