import CryptoKit
import Foundation

/// One synced row type. The raw values are stored in `records.kind` and are
/// part of the wire contract — renaming one orphans existing rows.
enum SyncKind: String, CaseIterable, Codable, Sendable {
    case circle
    case person
    case brand
    case location
    case visit
    case participant
    case rating
    case dish
    case dishEntry
    case photo
    case comparison
    case want
    case importSession
    case importLink

    /// Insertion order that satisfies every relationship in the model: a record
    /// is only applied after the records it points at already exist.
    static let applyOrder: [SyncKind] = [
        .circle, .brand, .person, .location, .dish, .visit,
        .participant, .rating, .dishEntry, .photo,
        .comparison, .want, .importSession, .importLink
    ]

    /// Deletion runs the other way so a parent is never removed while a child
    /// still references it.
    static var deleteOrder: [SyncKind] { applyOrder.reversed() }
}

struct SyncKey: Hashable, Sendable {
    let kind: SyncKind
    let id: UUID
}

/// A local record ready to be sealed and pushed.
struct LocalSyncRecord: Sendable {
    let key: SyncKey
    let payload: Data
    let fingerprint: String
}

/// A remote record after decryption.
struct DecodedSyncRecord: Sendable {
    let key: SyncKey
    let payload: Data?
    let fingerprint: String?
    let deleted: Bool
    let updatedMS: Int64
    let deviceID: UUID?
}

enum SyncPayloadCodec {
    /// Deterministic encoding. Two devices holding equal values must produce
    /// byte-identical payloads, otherwise every sync would see phantom changes.
    /// Sorted keys give stable ordering; milliseconds-since-1970 matches the
    /// existing backup format so archive records round-trip unchanged.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// Content fingerprint used to decide whether anything actually changed.
    /// It is computed over the plaintext, never the ciphertext, because AES-GCM
    /// uses a fresh nonce per seal and identical values encrypt differently
    /// every time.
    static func fingerprint(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    static func record(_ kind: SyncKind, _ id: UUID, _ value: some Encodable) throws -> LocalSyncRecord {
        let payload = try encode(value)
        return LocalSyncRecord(
            key: SyncKey(kind: kind, id: id),
            payload: payload,
            fingerprint: fingerprint(payload)
        )
    }
}
