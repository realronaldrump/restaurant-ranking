import CryptoKit
import Foundation
import Security

/// Per-circle symmetric encryption.
///
/// Every domain record and every photo blob is sealed on device before it
/// leaves. The key is generated when a circle is created, travels to other
/// members inside the invitation text, and is stored in the Keychain. It is
/// never sent to the sync server, so the server holds ciphertext it cannot
/// read even though it is also protected by row level security.
enum CircleCrypto {
    private static let contextPrefix = "com.davis.bigbeautifulranking.sync.v1"

    /// AES-GCM sealed box in `.combined` form (12-byte nonce ‖ ciphertext ‖ 16-byte tag).
    static func seal(
        _ plaintext: Data,
        with key: SymmetricKey,
        authenticating identity: Data = Data()
    ) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: identity)
        guard let combined = sealed.combined else { throw CircleCryptoError.sealFailed }
        return combined
    }

    static func open(
        _ ciphertext: Data,
        with key: SymmetricKey,
        authenticating identity: Data = Data()
    ) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key, authenticating: identity)
        } catch {
            throw CircleCryptoError.openFailed
        }
    }

    static func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func recordIdentity(circleID: UUID, kind: SyncKind, id: UUID) -> Data {
        Data("\(contextPrefix)|record|\(circleID.uuidString.lowercased())|\(kind.rawValue)|\(id.uuidString.lowercased())".utf8)
    }

    static func photoIdentity(circleID: UUID, photoID: UUID, variant: String) -> Data {
        Data("\(contextPrefix)|photo|\(circleID.uuidString.lowercased())|\(photoID.uuidString.lowercased())|\(variant)".utf8)
    }

    static func circleNameIdentity(circleID: UUID) -> Data {
        Data("\(contextPrefix)|circle-name|\(circleID.uuidString.lowercased())".utf8)
    }

    static func encode(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    static func decodeKey(_ encoded: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: encoded), data.count == 32 else {
            throw CircleCryptoError.malformedKey
        }
        return SymmetricKey(data: data)
    }

    /// High-entropy, human-transferable invitation code.
    static func makeInviteCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

enum CircleCryptoError: LocalizedError {
    case sealFailed
    case openFailed
    case malformedKey
    case missingKey

    var errorDescription: String? {
        switch self {
        case .sealFailed:
            "The record could not be encrypted before syncing."
        case .openFailed:
            "A synced record could not be decrypted. This device may be missing the circle key."
        case .malformedKey:
            "The circle key is not in the expected format."
        case .missingKey:
            "This device does not hold the key for that circle. Re-open the invitation to restore it."
        }
    }
}

// MARK: - Invitation payload

/// What one member hands another out of band.
///
/// The circle key rides inside this payload rather than through the server, so
/// the operator of the database never sees it. That is the whole reason the
/// invitation must be delivered over a channel the two people already trust —
/// Messages, AirDrop, or a spoken/scanned code — and why it is single use.
struct CircleInvitation: Codable, Equatable, Identifiable {
    static let scheme = "https"
    static let host = "realronaldrump.github.io"
    static let path = "/restaurant-ranking/join"

    var circleID: UUID
    var personID: UUID
    var circleName: String
    var code: String
    var key: String

    var id: UUID { circleID }

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = Self.path
        guard let payload = try? JSONEncoder().encode(self) else { return nil }
        // URL fragments never reach the web server, its access logs, or an
        // intermediary. The invitation code and E2EE key therefore stay in the
        // associated handoff between the sender and the installed app.
        components.fragment = payload.base64URLEncodedString()
        return components.url
    }

    init(circleID: UUID, personID: UUID, circleName: String, code: String, key: String) {
        self.circleID = circleID
        self.personID = personID
        self.circleName = circleName
        self.code = code
        self.key = key
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              url.path == Self.path || url.path == Self.path + "/",
              let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              let data = Data(base64URLEncoded: fragment),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              !decoded.code.isEmpty,
              (try? CircleCrypto.decodeKey(decoded.key)) != nil
        else { return nil }
        self = decoded
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Keychain

/// Circle keys and the Supabase refresh token.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps background sync
/// working after a reboot-and-unlock while refusing to travel in an encrypted
/// device backup to another phone. A replacement device re-joins with the
/// invitation instead, which is the same trust step as the original join.
enum CircleKeychain {
    private static let service = "com.davis.bigbeautifulranking.sync"

    static func storeKey(_ key: SymmetricKey, for circleID: UUID) throws {
        try store(CircleCrypto.encode(key), account: "circle-key-\(circleID.uuidString)")
    }

    static func key(for circleID: UUID) -> SymmetricKey? {
        guard let encoded = read(account: "circle-key-\(circleID.uuidString)") else { return nil }
        return try? CircleCrypto.decodeKey(encoded)
    }

    static func removeKey(for circleID: UUID) {
        remove(account: "circle-key-\(circleID.uuidString)")
    }

    static func storeRefreshToken(_ token: String) throws {
        try store(token, account: "supabase-refresh-token")
    }

    static var refreshToken: String? {
        read(account: "supabase-refresh-token")
    }

    static func removeRefreshToken() {
        remove(account: "supabase-refresh-token")
    }

    // MARK: Primitives

    private static func store(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw CircleCryptoError.malformedKey }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CircleKeychainError.unhandled(status) }
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum CircleKeychainError: LocalizedError {
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unhandled(status):
            "The circle key could not be stored securely on this device (code \(status))."
        }
    }
}
