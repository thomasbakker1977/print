import Foundation
import Security

enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set your server address and token in More → Server."
        case .invalidURL: "The server address is not a valid URL."
        case let .http(code, message): "Server error \(code): \(message)"
        }
    }
}

/// Talks to the LifeChart backend running in the user's homelab.
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "serverURL") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "serverURL") }
    }

    var token: String {
        get { Keychain.read("apiToken") ?? "" }
        set { Keychain.write("apiToken", value: newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var isConfigured: Bool { !serverURL.isEmpty && !token.isEmpty }

    // MARK: - Endpoints

    func status() async throws -> ServerStatusDTO {
        try await send("GET", "/api/status")
    }

    func sync(_ request: SyncRequestDTO) async throws -> SyncResponseDTO {
        try await send("POST", "/api/sync", body: request)
    }

    func profile() async throws -> ProfileDTO {
        try await send("GET", "/api/profile")
    }

    func saveProfile(_ profile: ProfileDTO) async throws -> ProfileDTO {
        try await send("PUT", "/api/profile", body: profile)
    }

    func refreshGarmin() async throws -> GarminStatusDTO {
        try await send("POST", "/api/garmin/refresh")
    }

    func conversations() async throws -> [ConversationDTO] {
        try await send("GET", "/api/coach/conversations")
    }

    func conversation(_ id: String) async throws -> ConversationDetailDTO {
        try await send("GET", "/api/coach/conversations/\(id)")
    }

    func deleteConversation(_ id: String) async throws {
        let request = try makeRequest("DELETE", "/api/coach/conversations/\(id)")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
    }

    /// Streams the coach's reply as server-sent events.
    func chat(_ body: ChatRequestDTO) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest("POST", "/api/coach/chat", body: body)
                    request.timeoutInterval = 300
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        try check(response, data)
                    }
                    // The server always sends "event: x" followed by one "data: {...}" line.
                    var eventName = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            eventName = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            let payload = Data(line.dropFirst(6).utf8)
                            if let event = decodeEvent(eventName, payload) {
                                continuation.yield(event)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func decodeEvent(_ name: String, _ data: Data) -> ChatEvent? {
        struct Conversation: Decodable { var conversationId: String }
        struct Text: Decodable { var text: String }
        struct Message: Decodable { var message: String }
        struct Action: Decodable { var summary: String }
        switch name {
        case "conversation":
            return (try? decoder.decode(Conversation.self, from: data)).map { .conversation(id: $0.conversationId) }
        case "text":
            return (try? decoder.decode(Text.self, from: data)).map { .text($0.text) }
        case "suggestion":
            return (try? decoder.decode(Suggestion.self, from: data)).map { .suggestion($0) }
        case "action":
            return (try? decoder.decode(Action.self, from: data)).map { .action($0.summary) }
        case "error":
            return (try? decoder.decode(Message.self, from: data)).map { .failure($0.message) }
        case "done":
            return .done
        default:
            return nil
        }
    }

    // MARK: - Plumbing

    private func makeRequest(_ method: String, _ path: String) throws -> URLRequest {
        guard isConfigured else { throw APIError.notConfigured }
        var base = serverURL
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeRequest<Body: Encodable>(_ method: String, _ path: String, body: Body) throws -> URLRequest {
        var request = try makeRequest(method, path)
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        let request = try makeRequest(method, path)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decoder.decode(Response.self, from: data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String, _ path: String, body: Body
    ) async throws -> Response {
        let request = try makeRequest(method, path, body: body)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decoder.decode(Response.self, from: data)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            struct Detail: Decodable { var detail: String }
            let message = (try? decoder.decode(Detail.self, from: data))?.detail
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, message)
        }
    }
}

enum Keychain {
    private static let service = "LifeChart"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
