/// Result of parsing a date string — used for live preview in date input fields.
public nonisolated struct DateParseResult: Sendable {
    public let displayText: String         // Human-readable interpretation
    public let isValid: Bool               // Whether the input was parseable
    public let parsed: GenealogicalDate?   // The parsed date, if valid

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(displayText: String, isValid: Bool, parsed: GenealogicalDate? = nil) {
        self.displayText = displayText
        self.isValid = isValid
        self.parsed = parsed
    }

}
