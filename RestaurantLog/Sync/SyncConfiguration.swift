import Foundation

/// Where the sync service lives and whether this build talks to it at all.
///
/// Both values are public-by-design: the anon key is a client identifier, not a
/// secret. Every row it can reach is gated by row level security, and the
/// payloads behind that gate are encrypted with a key the server never holds.
struct SyncConfiguration {
    let baseURL: URL
    let anonKey: String

    static let infoURLKey = "SupabaseURL"
    static let infoAnonKey = "SupabaseAnonKey"

    /// Reads Info.plist. Returns nil when the keys are absent, unexpanded, or
    /// still hold the placeholder — which is how simulator, test, and
    /// unconfigured builds run entirely on device with syncing switched off.
    static func fromBundle(_ bundle: Bundle = .main) -> SyncConfiguration? {
        guard
            let rawURL = bundle.object(forInfoDictionaryKey: infoURLKey) as? String,
            let anonKey = bundle.object(forInfoDictionaryKey: infoAnonKey) as? String,
            !rawURL.contains("$("), !anonKey.contains("$("),
            !rawURL.contains("YOUR_PROJECT"), !anonKey.contains("YOUR_ANON_KEY"),
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https",
            // An undefined SUPABASE_HOST expands to nothing, leaving "https://".
            let host = url.host, !host.isEmpty,
            !anonKey.isEmpty
        else { return nil }
        return SyncConfiguration(baseURL: url, anonKey: anonKey)
    }

    var restURL: URL { baseURL.appendingPathComponent("rest/v1") }
    var authURL: URL { baseURL.appendingPathComponent("auth/v1") }
    var storageURL: URL { baseURL.appendingPathComponent("storage/v1") }
}

/// Identifies this installation so a device can recognise its own writes coming
/// back from the server and skip re-applying them.
enum SyncDevice {
    private static let key = "syncDeviceID"

    static var identifier: UUID {
        if let stored = UserDefaults.standard.string(forKey: key),
           let existing = UUID(uuidString: stored) {
            return existing
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: key)
        return fresh
    }
}
