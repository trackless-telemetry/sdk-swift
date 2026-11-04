import Testing
@testable import TracklessTelemetry

/// The cross-SDK normalization table: input, then what is stored, or `nil` when it is rejected.
/// `field-normalization-parity.test.ts` in the monorepo fails if these rows drift from its own.
private let normalizationParityTable: [(input: String, stored: String?)] = [
    ("123e4567-e89b-12d3-a456-426614174000", nil),
    ("123E4567-E89B-12D3-A456-426614174000", nil),
    ("550e8400_e29b_41d4_a716_446655440000", nil),
    ("550e8400.e29b.41d4.a716.446655440000", nil),
    ("550e8400 e29b 41d4 a716 446655440000", nil),
    ("user-123e4567-e89b-12d3-a456-426614174000", nil),
    ("err.123e4567-e89b-12d3-a456-426614174000", nil),
    ("user-abcdefab-cdef-abcd-efab-cdefabcdefab", nil),
    ("abcdefab-cdef-abcd-efab-cdefabcdefab_retry", nil),
    ("checkout_flow_step_checkout_flow_step_checkout_flow_step_checkout_flow_step_checkout_flow_step_123e4567-e89b-12d3-a456-426614174000", nil),
    ("507f1f77bcf86cd799439011", nil),
    ("550e8400e29b41d4a716446655440000", nil),
    ("tok_507f1f77bcf86cd799439011", nil),
    ("tok-abcdefabcdefabcdefabcdef", nil),
    ("tok_550e8400e29b41d4a716446655440000", nil),
    ("tok-abcdefabcdefabcdefabcde", "tok-abcdefabcdefabcdefabcde"),
    ("abcdefabcdefabcde", nil),
    ("1234567890123", nil),
    ("123e4567-e89b-12d3-a_redacted", nil),
    ("550e8400e29b41d4a_redacted", nil),
    ("user-6fe8b8e2-0bd_redacted_aeb89f4d624", nil),
    ("tok_94efbda267a_redacted_a9061dd2", nil),
    ("deadbeef-555-123-4567", nil),
    ("555-123-4567", "redacted"),
    ("+1 (555) 123-4567", "redacted"),
    ("call 555-123-4567", "call_redacted"),
    ("err.555-123-4567", "err._redacted"),
    ("user@example.com", "redacted"),
    ("signup_failed user@example.com", "signup_failed_redacted"),
    ("123-45-6789", "redacted"),
    ("settings.theme", "settings.theme"),
    ("err_001", "err_001"),
    ("java.lang.illegalstateexception", "java.lang.illegalstateexception"),
    ("java.lang.IllegalStateException", "java.lang.illegalstateexception"),
    ("Sign Up Button", "sign_up_button"),
    ("cafe_fade_added", "cafe_fade_added"),
    ("add_face_redacted", "add_face_redacted"),
    ("123e4567", "123e4567"),
    ("e10b90f6--b4f5--4c42--b4cf--317b5d116211", nil),
    ("c2008c33__92bc__48b7__b93f__c0a61d76418a", nil),
    ("1cae8043 - 4d24 - 4e22 - 956f - 698a933e3b5b", nil),
    ("9b7ee1c2-9299-4ec0-af1e-c102392226c", nil),
    ("7b59744c-d299-44ad-b30d", nil),
    ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.y", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"),
    ("deadbeefdead_555-123-4567", nil),
    ("555-123-4567_12345678", nil),
    ("trackless.uncaught", "trackless.uncaught"),
    ("NSInvalidArgumentException", "nsinvalidargumentexception"),
    ("TypeError", "typeerror"),
    ("com.example.app.Checkout$PaymentException", "com.example.app.checkout_paymentexception"),
    ("!!!", nil),
    // An address may hold non-ASCII characters, but not a Unicode space; the rest of the value stays.
    ("éric@example.com", "redacted"),
    ("日本user@example.com", "redacted"),
    ("user@example.comé", "redacted"),
    ("signup é user@example.com", "signup_redacted"),
    ("us\u{0301}er@example.com", "redacted"),
    ("uſer@example.com", "redacted"),
    ("\u{212A}evin@example.com", "redacted"),
    ("user@exämple.com", "redacted"),
    ("user@\u{0301}example.com", "redacted"),
    ("josé@example.com", "redacted"),
    ("user＠example.com", "user_example.com"),
    ("user@localhost", "user_localhost"),
    ("user@example.c0m", "user_example.c0m"),
    ("日本語@example.com", "redacted"),
    ("user@example.みんな", "redacted"),
    ("user@example.com_x", "redacted__x"),
    ("user@example.com2", "redacted_2"),
    ("a@b.com_c@d.com", "redacted_redacted"),
    ("login失敗user@example.com", "redacted"),
    ("clicked\u{3000}user@example.com", "clicked_redacted"),
    ("user@example.com\u{00A0}clicked", "redacted_clicked"),
    ("abc😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀@example.com", "redacted"),
    ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx@example.com", "xxxxxx_redacted"),
    ("a@b.com-c@d.com", "redacted_redacted"),
    ("x .foo@example.com", "x_redacted"),
    ("é123456789", "redacted"),
    ("123456789é", "redacted"),
    ("日本123-45-6789", "redacted"),
    ("123-45-6789é", "redacted"),
    ("é555-123-4567", "redacted"),
    // Non-ASCII digits are not digits to the patterns, and sanitizing removes them.
    ("٠١٢٣٤٥٦٧٨", nil),
    ("１２３４５６７８９", nil),
    ("𝟏𝟐𝟑𝟒𝟓𝟔𝟕𝟖𝟗", nil),
    ("٠١٢-٣٤-٥٦٧٨", "-_-"),
    ("call ٠١٢٣٤٥٦٧٨", "call"),
    ("12345٠67890", "12345_67890"),
    ("٠123456789", "redacted"),
    // Unicode spaces separate a phone number; other invisible characters do not.
    ("555\u{00A0}123\u{00A0}4567", "redacted"),
    ("555\u{FEFF}123\u{FEFF}4567", "redacted"),
    ("555\u{202F}123\u{202F}4567", "redacted"),
    ("555\u{3000}123\u{3000}4567", "redacted"),
    ("555\u{000B}123\u{000B}4567", "redacted"),
    ("555\u{0085}123\u{0085}4567", "555_123_4567"),
    ("555\u{200B}123\u{200B}4567", "555_123_4567"),
]

@Suite("FeatureValidator Tests")
struct FeatureValidatorTests {

    // MARK: - Test 12: Feature name validation (valid names)

    @Test("Valid feature names pass validation")
    func validNames() {
        #expect(FeatureValidator.isValid("export_clicked") == true)
        #expect(FeatureValidator.isValid("settings-opened") == true)
        #expect(FeatureValidator.isValid("theme.dark") == true)
        #expect(FeatureValidator.isValid("distance_preset.1_mile") == true)
        #expect(FeatureValidator.isValid("a") == true)
        #expect(FeatureValidator.isValid("feature123") == true)
        #expect(FeatureValidator.isValid("page_view_home") == true)
        #expect(FeatureValidator.isValid("cafe_fade_added") == true)
        #expect(FeatureValidator.isValid("event_20260301") == true)
    }

    // MARK: - Test 13: Invalid feature name silently ignored

    @Test("Empty string is invalid")
    func emptyString() {
        #expect(FeatureValidator.isValid("") == false)
    }

    @Test("Name exceeding 100 characters is invalid")
    func tooLong() {
        let longName = String(repeating: "a", count: 101)
        #expect(FeatureValidator.isValid(longName) == false)
    }

    @Test("Name at exactly 100 characters is valid")
    func exactlyMaxLength() {
        // Use 'x' (not a hex char) to avoid triggering isEntirelyHexAndLong
        let name = String(repeating: "x", count: 100)
        #expect(FeatureValidator.isValid(name) == true)
    }

    @Test("Uppercase characters are invalid (validator only — client normalizes before calling)")
    func uppercaseInvalid() {
        // The validator itself still rejects uppercase — the client normalizes before calling
        #expect(FeatureValidator.isValid("Export_Clicked") == false)
        #expect(FeatureValidator.isValid("SETTINGS") == false)
    }

    @Test("Spaces are invalid")
    func spacesInvalid() {
        #expect(FeatureValidator.isValid("export clicked") == false)
    }

    @Test("Name starting with dot is invalid")
    func startsWithDot() {
        #expect(FeatureValidator.isValid(".settings") == false)
    }

    @Test("Name ending with dot is invalid")
    func endsWithDot() {
        #expect(FeatureValidator.isValid("settings.") == false)
    }

    @Test("Consecutive dots are invalid")
    func consecutiveDots() {
        #expect(FeatureValidator.isValid("settings..opened") == false)
    }

    @Test("Multiple dots are accepted by the regex")
    func multipleDots() {
        #expect(FeatureValidator.isValid("a.b.c") == true)
        #expect(FeatureValidator.isValid("settings.theme.dark") == true)
        #expect(FeatureValidator.isValid("nav.settings.display") == true)
    }

    @Test("Special characters are invalid")
    func specialChars() {
        #expect(FeatureValidator.isValid("export@clicked") == false)
        #expect(FeatureValidator.isValid("export#clicked") == false)
        #expect(FeatureValidator.isValid("export/clicked") == false)
    }

    // MARK: - Anti-identifier patterns

    @Test("UUID pattern is rejected")
    func uuidRejected() {
        #expect(FeatureValidator.isValid("550e8400-e29b-41d4-a716-446655440000") == false)
        // With underscores
        #expect(FeatureValidator.isValid("550e8400_e29b_41d4_a716_446655440000") == false)
    }

    @Test("Long hex sequence (>24 chars) is rejected")
    func longHexRejected() {
        let hex = String(repeating: "abcdef0123456789", count: 2).prefix(25)
        #expect(FeatureValidator.isValid(String(hex)) == false)
    }

    @Test("Short hex sequences are allowed")
    func shortHexAllowed() {
        // 16 chars, all hex but not > 16 for the entirely-hex check
        #expect(FeatureValidator.isValid("abcdef0123456789") == true)
    }

    @Test("Entirely hex and > 16 chars is rejected")
    func entirelyHexLongRejected() {
        // 17 hex-only characters
        #expect(FeatureValidator.isValid("abcdef01234567890") == false)
    }

    @Test("Long numeric-only string (>12) is rejected")
    func longNumericRejected() {
        #expect(FeatureValidator.isValid("1234567890123") == false)
    }

    @Test("Short numeric-only string (<=12) is allowed")
    func shortNumericAllowed() {
        #expect(FeatureValidator.isValid("123456789012") == true)
    }

    @Test("Hex chars mixed with non-hex letters are allowed")
    func hexWithNonHexAllowed() {
        // Contains 'g' which is not hex, so not entirely-hex
        #expect(FeatureValidator.isValid("abcdefg0123456789") == true)
    }

    // MARK: - PII Stripping

    @Test("stripPII replaces email addresses with [REDACTED]")
    func stripEmail() {
        #expect(FeatureValidator.stripPII("contact user@example.com now") == "contact [REDACTED] now")
    }

    @Test("stripPII replaces dashed SSN patterns with [REDACTED]")
    func stripSSNDashed() {
        #expect(FeatureValidator.stripPII("ssn 123-45-6789 here") == "ssn [REDACTED] here")
    }

    @Test("stripPII replaces 9-digit SSN patterns with [REDACTED]")
    func stripSSNPlain() {
        #expect(FeatureValidator.stripPII("id 123456789 entered") == "id [REDACTED] entered")
    }

    @Test("stripPII replaces phone numbers with [REDACTED]")
    func stripPhone() {
        #expect(FeatureValidator.stripPII("called +1 (555) 123-4567") == "called [REDACTED]")
    }

    @Test("stripPII replaces unformatted phone numbers with [REDACTED]")
    func stripPhoneUnformatted() {
        #expect(FeatureValidator.stripPII("number 5551234567") == "number [REDACTED]")
    }

    @Test("stripPII handles multiple PII patterns in one string")
    func stripMultiplePII() {
        let result = FeatureValidator.stripPII("email: a@b.com phone: 555-123-4567")
        #expect(!result.contains("a@b.com"))
        #expect(!result.contains("555-123-4567"))
    }

    @Test("stripPII leaves non-PII strings unchanged")
    func stripPIINoChange() {
        #expect(FeatureValidator.stripPII("dark_mode") == "dark_mode")
        #expect(FeatureValidator.stripPII("export_clicked") == "export_clicked")
    }

    // MARK: - Normalization

    @Test("normalize lowercases and replaces spaces with underscores")
    func normalizeSpaces() {
        #expect(FeatureValidator.normalize("My Feature") == "my_feature")
        #expect(FeatureValidator.normalize("Product Details Page") == "product_details_page")
    }

    @Test("normalize replaces special characters with underscores")
    func normalizeSpecialChars() {
        #expect(FeatureValidator.normalize("export!clicked") == "export_clicked")
        #expect(FeatureValidator.normalize("feature@name#here") == "feature_name_here")
    }

    @Test("normalize collapses consecutive dots")
    func normalizeConsecutiveDots() {
        #expect(FeatureValidator.normalize("foo..bar") == "foo.bar")
        #expect(FeatureValidator.normalize("a...b...c") == "a.b.c")
    }

    @Test("normalize trims leading/trailing underscores and dots")
    func normalizeTrimming() {
        #expect(FeatureValidator.normalize("...foo...") == "foo")
        #expect(FeatureValidator.normalize("___bar___") == "bar")
        #expect(FeatureValidator.normalize("._foo._") == "foo")
    }

    @Test("normalize returns nil for empty result")
    func normalizeEmpty() {
        #expect(FeatureValidator.normalize("") == nil)
        #expect(FeatureValidator.normalize("!!!") == nil)
        #expect(FeatureValidator.normalize("...") == nil)
    }

    @Test("normalize returns nil for abuse patterns")
    func normalizeAbusePattern() {
        // 18 hex-only chars triggers the entirely-hex-and-long abuse check
        #expect(FeatureValidator.normalize("abcdefabcdefabcdef") == nil)
        #expect(FeatureValidator.normalize(String(repeating: "a", count: 25)) == nil)
    }

    @Test("normalize truncates to max length")
    func normalizeTruncation() {
        let long = String(repeating: "x", count: 150)
        let result = FeatureValidator.normalize(long)
        #expect(result?.count == 100)
    }

    @Test("normalize strips PII before normalizing")
    func normalizePII() {
        // Email gets stripped to [REDACTED], then brackets normalized away
        #expect(FeatureValidator.normalize("user@example.com") == "redacted")
    }

    @Test("normalize preserves valid strings")
    func normalizeValidStrings() {
        #expect(FeatureValidator.normalize("export_clicked") == "export_clicked")
        #expect(FeatureValidator.normalize("theme.dark") == "theme.dark")
        #expect(FeatureValidator.normalize("my-feature") == "my-feature")
    }

    @Test("The email pattern's limits keep a long value cheap")
    func longValues() {
        for value in [
            String(repeating: "a", count: 200_000),
            String(repeating: "日", count: 200_000),
            "a@" + String(repeating: "b", count: 200_000),
            String(repeating: "a@b", count: 70_000),
        ] {
            #expect(FeatureValidator.stripPII(value) == value)
        }
    }

    @Test("Normalization matches the cross-SDK table")
    func normalizationParity() {
        for row in normalizationParityTable {
            #expect(FeatureValidator.normalize(row.input) == row.stored, "input: \(row.input)")
        }
    }
}
