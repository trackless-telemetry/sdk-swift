import Foundation

/// Result from the HTTP send operation.
struct SendResult: Sendable {
    let status: Int
    let body: Data?
}

/// URLSession-based HTTP client for sending event payloads.
///
/// - 10-second timeout
/// - POST with Content-Type: application/json and X-Api-Key header
/// - JSON encoding via JSONEncoder
enum HTTPClient {

    /// Default flush timeout: 10 seconds
    static let flushTimeoutSeconds: TimeInterval = 10

    /// Send an event payload to the ingest endpoint.
    ///
    /// - Parameters:
    ///   - endpoint: Ingest URL
    ///   - apiKey: API key (tl_* format)
    ///   - payload: Event payload
    ///   - timeoutSeconds: Request timeout. Defaults to `flushTimeoutSeconds`;
    ///     the macOS termination path shortens it so the last send cannot
    ///     outlive the quit budget that is waiting on it.
    /// - Returns: The HTTP status code and response body
    /// - Throws: Network errors or timeout
    static func sendPayload(
        endpoint: String,
        apiKey: String,
        payload: TracklessEventPayload,
        timeoutSeconds: TimeInterval = flushTimeoutSeconds
    ) async throws -> SendResult {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.timeoutInterval = timeoutSeconds

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        return SendResult(status: httpResponse.statusCode, body: data)
    }
}
