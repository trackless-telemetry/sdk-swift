import Foundation

/// Validates feature names against the Trackless naming rules.
///
/// Rules (from Section 6.2):
/// - Lowercase alphanumeric, underscores, hyphens, and dots: [a-z0-9_.-]
/// - 1-100 characters
/// - Must not start or end with "."
/// - No consecutive dots ("..")
/// - No leading, trailing, or consecutive dots
/// - Must not look like a UUID, hash, or encoded identifier
enum FeatureValidator {

    /// Maximum allowed length for a feature name.
    static let maxLength = 100

    /// Returns `true` if the feature name is valid per Trackless rules.
    static func isValid(_ name: String) -> Bool {
        // Non-empty, within length
        guard !name.isEmpty, name.count <= maxLength else {
            return false
        }

        // Must not start or end with "."
        guard !name.hasPrefix("."), !name.hasSuffix(".") else {
            return false
        }

        // No consecutive dots
        guard !name.contains("..") else {
            return false
        }

        // Only allowed characters: [a-z0-9_.-]
        let allowedCharSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard name.unicodeScalars.allSatisfy({ allowedCharSet.contains($0) }) else {
            return false
        }

        return !isAbusePattern(name)
    }

    // MARK: - PII Stripping

    /// JavaScript's `\b`, which only ASCII letters, digits and `_` count for. ICU's `\b`, `\d`,
    /// `\s` and case folding take in non-ASCII characters and the web SDK's do not, so none of
    /// them appear in these patterns: `é123456789` would keep its digits.
    private static let asciiWordBoundary =
        "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"

    /// Every non-ASCII character but the Unicode spaces `phonePattern` lists can be part of an
    /// address.
    private static let emailNonASCII = "\\u00A1-\\u167F\\u1681-\\u1FFF\\u200B-\\u2027\\u202A-\\u202E\\u2030-\\u205E\\u2060-\\u2FFF\\u3001-\\uFEFE\\uFF00-\\x{10FFFF}"

    /// Regex patterns for PII detection. The email limits are the RFC's, and what keeps it linear
    /// with no boundary to start from.
    private static let emailPattern = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+\\-\(emailNonASCII)]{1,64}@[A-Za-z0-9.\\-\(emailNonASCII)]{1,255}\\.[A-Za-z\(emailNonASCII)]{2,}",
        options: []
    )
    private static let ssnDashedPattern = try! NSRegularExpression(
        pattern: asciiWordBoundary + "[0-9]{3}-[0-9]{2}-[0-9]{4}" + asciiWordBoundary,
        options: []
    )
    private static let ssnPlainPattern = try! NSRegularExpression(
        pattern: asciiWordBoundary + "[0-9]{9}" + asciiWordBoundary,
        options: []
    )
    private static let phonePattern = try! NSRegularExpression(
        pattern: "\\+?[0-9][0-9\\t\\n\\x0B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF\\-.()]{8,}[0-9]",
        options: []
    )

    /// Strip PII patterns (emails, SSNs, phone numbers) from a string,
    /// replacing matches with [REDACTED].
    static func stripPII(_ value: String) -> String {
        var result = value

        // Email addresses. By scalar, because "@" with a combining mark is another Character.
        if result.unicodeScalars.contains("@") {
            result = emailPattern.stringByReplacingMatches(
                in: result, options: [], range: NSRange(result.startIndex..., in: result),
                withTemplate: "[REDACTED]"
            )
        }
        // SSN patterns (check before phone numbers to avoid false matches)
        result = ssnDashedPattern.stringByReplacingMatches(
            in: result, options: [], range: NSRange(result.startIndex..., in: result),
            withTemplate: "[REDACTED]"
        )
        result = ssnPlainPattern.stringByReplacingMatches(
            in: result, options: [], range: NSRange(result.startIndex..., in: result),
            withTemplate: "[REDACTED]"
        )
        // Phone numbers
        result = phonePattern.stringByReplacingMatches(
            in: result, options: [], range: NSRange(result.startIndex..., in: result),
            withTemplate: "[REDACTED]"
        )
        return result
    }

    // MARK: - Normalization

    /// Normalize a field value (name, detail, step, code) into a valid format.
    /// Strips PII, lowercases, replaces invalid chars with underscores, and validates.
    /// Returns `nil` if the result is empty or matches an abuse pattern.
    ///
    /// The abuse patterns run on the whole value before the PII strip as well as on
    /// the result: the phone pattern eats runs of digits inside a UUID or hex ID, and
    /// truncating can cut one short, either of which leaves a part no rule matches.
    static func normalize(_ value: String) -> String? {
        guard !isAbusePattern(sanitize(value)) else { return nil }
        var result = sanitize(stripPII(value))
        guard !result.isEmpty else { return nil }
        // Truncate to max length; a cut can leave a trailing ".", which ingest rejects
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: "_."))
        }
        // Reject abuse patterns
        guard !isAbusePattern(result) else { return nil }
        return result
    }

    /// Lowercases and reduces a value to the characters and shape a field allows.
    private static func sanitize(_ value: String) -> String {
        var result = value.lowercased()
        // Replace runs of non-allowed chars with a single underscore
        let allowedChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        var normalized = ""
        var lastWasUnderscore = false
        for scalar in result.unicodeScalars {
            if allowedChars.contains(scalar) {
                normalized.append(Character(scalar))
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                normalized.append("_")
                lastWasUnderscore = true
            }
        }
        result = normalized
        // Trim leading/trailing underscores and dots
        let trimChars = CharacterSet(charactersIn: "_.")
        result = result.trimmingCharacters(in: trimChars)
        // Collapse consecutive dots
        while result.contains("..") {
            result = result.replacingOccurrences(of: "..", with: ".")
        }
        return result
    }

    // MARK: - Abuse Detection

    /// Returns `true` if the name matches anti-identifier abuse patterns.
    static func isAbusePattern(_ name: String) -> Bool {
        if matchesUUIDPattern(name) { return true }
        if containsLongHexSequence(name) { return true }
        if isLongNumericOnly(name) { return true }
        if isEntirelyHexAndLong(name) { return true }
        if hasRedactedIDResidue(name) { return true }
        return false
    }

    // MARK: - Private Helpers

    /// Finds a UUID anywhere in the value, by its first four groups (8-4-4-4) so one with its
    /// tail cut off is found too, with any run of hyphens, underscores or dots between them.
    private static func matchesUUIDPattern(_ name: String) -> Bool {
        let pattern = "[0-9a-f]{8}[-_.]+[0-9a-f]{4}[-_.]+[0-9a-f]{4}[-_.]+[0-9a-f]{4}"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Checks for 24 or more consecutive hex characters ([0-9a-f]) anywhere in the value.
    private static func containsLongHexSequence(_ name: String) -> Bool {
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        var consecutiveCount = 0
        for scalar in name.unicodeScalars {
            if hexChars.contains(scalar) {
                consecutiveCount += 1
                if consecutiveCount >= 24 {
                    return true
                }
            } else {
                consecutiveCount = 0
            }
        }
        return false
    }

    /// Checks if the name is numeric-only (all digits) and longer than 12 characters.
    private static func isLongNumericOnly(_ name: String) -> Bool {
        guard name.count > 12 else { return false }
        return name.allSatisfy { $0.isNumber }
    }

    /// Checks if the name is entirely hex characters (no underscores, hyphens, dots,
    /// no letters g-z) and longer than 16 characters.
    private static func isEntirelyHexAndLong(_ name: String) -> Bool {
        guard name.count > 16 else { return false }
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        return name.unicodeScalars.allSatisfy { hexChars.contains($0) }
    }

    /// The PII marker beside 8+ characters of hex-only tokens: what remains of an ID.
    private static func hasRedactedIDResidue(_ name: String) -> Bool {
        guard name.contains("redacted") else { return false }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
        let hexChars = name.replacingOccurrences(of: "redacted", with: "_")
            .split(whereSeparator: { "-_.".contains($0) })
            .filter { $0.unicodeScalars.allSatisfy { hexDigits.contains($0) } }
            .reduce(0) { $0 + $1.count }
        return hexChars >= 8
    }
}
