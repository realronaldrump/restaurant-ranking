import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Per-circle symmetric encryption.
///
/// Every domain record and every photo blob is sealed on device before it
/// leaves. The key is generated when a circle is created and stored in the
/// Keychain. It reaches another member only inside a key envelope that is
/// unlocked by their join code, so the sync service holds ciphertext it cannot
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

    private static func envelopeIdentity(circleID: UUID) -> Data {
        Data("\(contextPrefix)|invite-envelope|\(circleID.uuidString.lowercased())".utf8)
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

    // MARK: - Join-code key envelopes

    /// Work factor for turning a 60-bit join code into a wrapping key. The
    /// service stores the envelope and the code's hash but never the code, so
    /// this is what stands between a database disclosure and the circle key.
    /// 200k iterations costs a phone well under a second and makes an offline
    /// search of the code space cost more than the data is worth.
    private static let envelopeIterations: UInt32 = 200_000

    struct KeyEnvelope: Equatable {
        /// Base64 AES-GCM sealed box holding the 32-byte circle key.
        var sealed: String
        /// Base64 random salt bound to this one invitation.
        var salt: String
    }

    /// Seals the circle key so only somebody holding the join code can open it.
    static func wrap(_ key: SymmetricKey, with code: CircleJoinCode, circleID: UUID) throws -> KeyEnvelope {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
            throw CircleCryptoError.sealFailed
        }
        let salt = Data(saltBytes)
        let wrappingKey = try wrappingKey(for: code, salt: salt)
        let sealed = try seal(
            key.withUnsafeBytes { Data($0) },
            with: wrappingKey,
            authenticating: envelopeIdentity(circleID: circleID)
        )
        return KeyEnvelope(sealed: sealed.base64EncodedString(), salt: salt.base64EncodedString())
    }

    /// Opens an envelope fetched from the service with the code the joiner typed.
    static func unwrap(_ envelope: KeyEnvelope, with code: CircleJoinCode, circleID: UUID) throws -> SymmetricKey {
        guard let sealed = Data(base64Encoded: envelope.sealed),
              let salt = Data(base64Encoded: envelope.salt) else {
            throw CircleCryptoError.malformedKey
        }
        let wrappingKey = try wrappingKey(for: code, salt: salt)
        let raw = try open(sealed, with: wrappingKey, authenticating: envelopeIdentity(circleID: circleID))
        guard raw.count == 32 else { throw CircleCryptoError.malformedKey }
        return SymmetricKey(data: raw)
    }

    private static func wrappingKey(for code: CircleJoinCode, salt: Data) throws -> SymmetricKey {
        let password = Array(code.normalized.utf8).map { CChar(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress,
                    passwordBuffer.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                    saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    envelopeIterations,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw CircleCryptoError.malformedKey }
        return SymmetricKey(data: Data(derived))
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
            "That join code did not unlock the circle. Ask for a new one."
        case .missingKey:
            "This device does not hold the key for that circle."
        }
    }
}

// MARK: - Join codes

/// The whole invitation: twelve characters somebody can read out loud, text, or
/// tap through as a link.
///
/// The code is the only secret. The service stores its SHA-256 hash next to a
/// key envelope that the code unlocks, so the operator of the database can
/// neither redeem an invitation nor read the circle it belongs to.
struct CircleJoinCode: Codable, Equatable, Hashable, Sendable {
    /// Crockford base32: no I, L, O, or U, so a code cannot be misread as a
    /// different one and cannot accidentally spell a word.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let length = 12

    /// Twelve alphabet characters, no separators.
    let normalized: String

    /// `XXXX-XXXX-XXXX`, which is how the code is always shown and shared.
    var formatted: String {
        stride(from: 0, to: normalized.count, by: 4).map { offset in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            let end = normalized.index(start, offsetBy: 4, limitedBy: normalized.endIndex) ?? normalized.endIndex
            return String(normalized[start ..< end])
        }.joined(separator: "-")
    }

    static func random() -> CircleJoinCode {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
        // Force-unwrap is safe: every character came out of the alphabet.
        return CircleJoinCode(String(characters))!
    }

    /// Accepts what a person actually types or pastes: spaces, dashes, lower
    /// case, and the letters Crockford maps onto digits.
    init?(_ raw: String) {
        var characters: [Character] = []
        for character in raw.uppercased() {
            switch character {
            case "-", " ", "\u{2013}", "\u{2014}", "\n", "\t", "\r": continue
            case "O": characters.append("0")
            case "I", "L": characters.append("1")
            case "U": characters.append("V")
            default:
                guard Self.alphabet.contains(character) else { return nil }
                characters.append(character)
            }
        }
        guard characters.count == Self.length else { return nil }
        normalized = String(characters)
    }

    /// What the service stores. Hashing here rather than in SQL keeps the code
    /// itself out of Postgres logs and statement caches.
    var hash: String {
        SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Invitation links

/// A tappable form of a join code. The link carries nothing else: no circle
/// identifier, no member identity, and no key.
struct CircleInvitation: Codable, Equatable, Hashable, Identifiable {
    static let scheme = "https"
    static let host = "realronaldrump.github.io"
    static let path = "/restaurant-ranking/join"
    /// Registered in Info.plist so an invitation still opens the app on a
    /// device where universal links are disabled or the association file is
    /// temporarily unreachable.
    static let appScheme = "bigbeautifullog"

    var code: CircleJoinCode
    /// Shown while confirming, purely so the invitation is recognisable.
    var circleName: String?

    var id: String { code.normalized }

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = Self.path
        // A fragment never reaches the web server, its access logs, or any
        // intermediary, so the code stays between the two people.
        components.fragment = code.formatted
        return components.url
    }

    init(code: CircleJoinCode, circleName: String? = nil) {
        self.code = code
        self.circleName = circleName
    }

    /// Reads an invitation out of any form the system might hand over: the
    /// hosted universal link, the app's own scheme, a query parameter, or the
    /// code sitting in the final path component.
    init?(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = url.scheme?.lowercased()
        let isWebInvitation = scheme == Self.scheme
            && url.host?.lowercased() == Self.host
            && url.path.hasPrefix(Self.path)
        let isAppInvitation = scheme == Self.appScheme
        guard isWebInvitation || isAppInvitation else { return nil }

        let candidates: [String?] = [
            components?.fragment,
            components?.queryItems?.first(where: { $0.name.lowercased() == "code" })?.value,
            url.lastPathComponent,
            url.host
        ]
        guard let code = candidates.compactMap({ $0 }).compactMap(CircleJoinCode.init).first else {
            return nil
        }
        self.init(code: code)
    }
}

// MARK: - Keychain

/// Circle keys and the Supabase refresh token.
///
/// Circle keys are stored as synchronizable items so they follow the person's
/// iCloud Keychain to a replacement iPhone. Without that, signing in on a new
/// device would download a log it could never decrypt, and the only recovery
/// would be asking another member for a fresh invitation. The service still
/// never sees a key: iCloud Keychain is end-to-end encrypted to the account.
///
/// The Supabase refresh token stays on this device only. It is re-obtainable
/// by signing in again, so there is nothing to gain from spreading it.
enum CircleKeychain {
    private static let service = "com.davis.bigbeautifulranking.sync"

    static func storeKey(_ key: SymmetricKey, for circleID: UUID) throws {
        try store(
            CircleCrypto.encode(key),
            account: "circle-key-\(circleID.uuidString)",
            synchronizable: true
        )
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

    /// Keeps a cold-open invitation recoverable while Core Data and the signed
    /// in account are still bootstrapping. The code unlocks a circle key, so it
    /// belongs in the Keychain rather than in UserDefaults or app logs.
    static func storePendingInvitation(_ invitation: CircleInvitation) throws {
        let encoded = try JSONEncoder().encode(invitation).base64EncodedString()
        try store(encoded, account: "pending-circle-invitation")
    }

    static var pendingInvitation: CircleInvitation? {
        guard let encoded = read(account: "pending-circle-invitation"),
              let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(CircleInvitation.self, from: data)
    }

    static func removePendingInvitation() {
        remove(account: "pending-circle-invitation")
    }

    // MARK: Primitives

    private static func store(_ value: String, account: String, synchronizable: Bool = false) throws {
        guard let data = value.data(using: .utf8) else { throw CircleCryptoError.malformedKey }
        // Match either storage class when clearing, so a value written by an
        // earlier build is replaced rather than shadowed.
        var existing = baseQuery(account: account)
        existing[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(existing as CFDictionary)

        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrSynchronizable as String] = synchronizable
        attributes[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CircleKeychainError.unhandled(status) }
    }

    private static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func remove(account: String) {
        var query = baseQuery(account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
