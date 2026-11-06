import Foundation

/// Describes a provider usage-limit (quota) failure detected from a server
/// error message, such as:
/// `"Usage limit reached for 5 hour. Your limit will reset at 2026-11-04 03:21:58"`.
///
/// The reset moment only exists inside the message text (providers embed it
/// without a timezone); `nextResetTime` epoch values from quota endpoints are
/// authoritative when available.
struct UsageLimitInfo: Equatable, Sendable {
    /// The original provider message, kept for display fallbacks.
    let message: String
    /// Parsed reset moment (UTC assumed for timezone-less timestamps).
    let resetAt: Date?

    /// Detects a usage-limit error from a provider message and optional HTTP status.
    /// Returns `nil` when the message does not look like a quota/rate limit.
    static func detect(message: String, status: Int? = nil) -> UsageLimitInfo? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        let mentionsLimit = lowered.contains("usage limit")
            || lowered.contains("rate limit")
            || lowered.contains("quota")
            || lowered.contains("limit will reset")
        guard mentionsLimit || status == 429 else { return nil }

        return UsageLimitInfo(message: trimmed, resetAt: parseResetDate(from: trimmed))
    }

    /// Extracts the reset moment from phrases like:
    /// - `"will reset at 2026-11-04 03:21:58"` (GLM/zai coding plan)
    /// - `"will reset on Feb 25, 2026 12:31 PM"` (OpenAI Codex)
    /// Timezone-less timestamps are interpreted as UTC.
    static func parseResetDate(from message: String) -> Date? {
        if let date = Self.parseFixedTimestamp(message) { return date }
        return Self.parseSpokenTimestamp(message)
    }

    private static func parseFixedTimestamp(_ message: String) -> Date? {
        guard let match = message.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(message[match]))
    }

    private static func parseSpokenTimestamp(_ message: String) -> Date? {
        guard let match = message.range(
            of: #"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* \d{1,2}, \d{4} \d{1,2}:\d{2} (AM|PM)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.date(from: String(message[match]))
    }
}
