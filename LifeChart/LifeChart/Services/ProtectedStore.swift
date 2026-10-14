import Foundation

/// Small, sensitive values (crisis plan, My Why) kept in a file that iOS
/// encrypts until the phone is first unlocked, instead of in UserDefaults.
enum ProtectedStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("protected.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func get(_ key: String) -> String {
        load()[key] ?? ""
    }

    static func set(_ key: String, _ value: String) {
        var values = load()
        values[key] = value
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
