import Foundation

/// A direct REST client for PostgREST, GoTrue, and Storage.
///
/// The app deliberately ships no third-party SDK. The surface it needs is a
/// dozen HTTP calls against a fixed schema, and hand-writing them keeps the
/// privacy manifest honest, keeps the dependency graph at one package, and
/// leaves every request inspectable when something misbehaves.
actor SupabaseClient {
    struct Session: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userID: UUID

        var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
    }

    struct RemoteRecord: Decodable {
        let kind: String
        let id: UUID
        let payload: String?
        let deleted: Bool
        let updatedMS: Int64
        let deviceID: UUID?

        enum CodingKeys: String, CodingKey {
            case kind, id, payload, deleted
            case updatedMS = "updated_ms"
            case deviceID = "device_id"
        }
    }

    /// Last row from a pull page. The next request asks for rows strictly after
    /// this tuple so concurrent writes cannot shift an offset underneath us.
    struct PullCursor: Equatable, Sendable {
        let updatedMS: Int64
        let kind: String
        let id: UUID

        var postgrestFilter: String {
            let uuid = id.uuidString.lowercased()
            return "(updated_ms.gt.\(updatedMS),and(updated_ms.eq.\(updatedMS),kind.gt.\(kind)),and(updated_ms.eq.\(updatedMS),kind.eq.\(kind),id.gt.\(uuid)))"
        }
    }

    struct OutgoingRecord: Encodable {
        let circleID: UUID
        let kind: String
        let id: UUID
        let payload: String?
        let deleted: Bool
        let deviceID: UUID

        enum CodingKeys: String, CodingKey {
            case circleID = "circle_id"
            case kind, id, payload, deleted
            case deviceID = "device_id"
        }
    }

    struct MembershipRow: Decodable, Identifiable, Sendable {
        let circleID: UUID
        let userID: UUID
        let personID: UUID
        let role: String
        let joinedAtText: String
        let lastSeenAtText: String?
        let appVersion: String?

        var id: UUID { userID }
        var joinedAt: Date? { Self.decodeTimestamp(joinedAtText) }
        var lastSeenAt: Date? { lastSeenAtText.flatMap(Self.decodeTimestamp) }

        enum CodingKeys: String, CodingKey {
            case circleID = "circle_id"
            case userID = "user_id"
            case personID = "person_id"
            case role
            case joinedAtText = "joined_at"
            case lastSeenAtText = "last_seen_at"
            case appVersion = "app_version"
        }

        private static func decodeTimestamp(_ value: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            return ISO8601DateFormatter().date(from: value)
        }
    }

    /// PostgREST rejects payloads above a few megabytes and Supabase's pooler
    /// prefers modest bodies. A dining log's records are small, so this only
    /// ever matters on the first upload of an imported history.
    static let pushBatchSize = 200
    static let pullPageSize = 500

    private let configuration: SyncConfiguration
    private let session: URLSession
    private var current: Session?

    init(
        configuration: SyncConfiguration,
        session: URLSession = .shared,
        initialSession: Session? = nil
    ) {
        self.configuration = configuration
        self.session = session
        current = initialSession
    }

    var userID: UUID? { current?.userID }
    var isSignedIn: Bool { current != nil }

    // MARK: - Authentication

    /// Exchanges an Apple identity token for a Supabase session.
    func signInWithApple(idToken: String, nonce: String?) async throws -> Session {
        var body: [String: String] = ["provider": "apple", "id_token": idToken]
        if let nonce { body["nonce"] = nonce }

        var request = URLRequest(url: tokenURL(grantType: "id_token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)

        let session = try await decodeSession(from: request)
        try adopt(session)
        return session
    }

    func restore() async throws -> Session? {
        if let current, current.isFresh { return current }
        guard let refreshToken = CircleKeychain.refreshToken else { return nil }
        return try await refresh(using: refreshToken)
    }

    func signOut() {
        current = nil
        CircleKeychain.removeRefreshToken()
    }

    @discardableResult
    private func refresh(using refreshToken: String) async throws -> Session {
        var request = URLRequest(url: tokenURL(grantType: "refresh_token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(["refresh_token": refreshToken])

        do {
            let session = try await decodeSession(from: request)
            try adopt(session)
            return session
        } catch SyncTransportError.unauthorized {
            // The refresh token was revoked or expired past its window. Drop it
            // so the UI asks for a fresh sign-in instead of retrying forever.
            signOut()
            throw SyncTransportError.unauthorized
        }
    }

    private func adopt(_ session: Session) throws {
        current = session
        try CircleKeychain.storeRefreshToken(session.refreshToken)
    }

    private func decodeSession(from request: URLRequest) async throws -> Session {
        let data = try await perform(request, allowRetry: false)

        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Double
            let user: User

            struct User: Decodable { let id: UUID }

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case user
            }
        }

        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Session(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            userID: response.user.id
        )
    }

    private func authorizedToken() async throws -> String {
        if let current, current.isFresh { return current.accessToken }
        if let refreshToken = current?.refreshToken ?? CircleKeychain.refreshToken {
            return try await refresh(using: refreshToken).accessToken
        }
        throw SyncTransportError.unauthorized
    }

    // MARK: - Circles

    func memberships() async throws -> [MembershipRow] {
        guard let userID = current?.userID else { throw SyncTransportError.unauthorized }
        var request = try await authorizedRequest(
            path: "circle_members",
            queryItems: [
                URLQueryItem(name: "select", value: "circle_id,user_id,person_id,role,joined_at,last_seen_at,app_version"),
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString)")
            ]
        )
        request.httpMethod = "GET"
        let data = try await perform(request)
        return try JSONDecoder().decode([MembershipRow].self, from: data)
    }

    func members(circleID: UUID) async throws -> [MembershipRow] {
        var request = try await authorizedRequest(
            path: "circle_members",
            queryItems: [
                URLQueryItem(name: "select", value: "circle_id,user_id,person_id,role,joined_at,last_seen_at,app_version"),
                URLQueryItem(name: "circle_id", value: "eq.\(circleID.uuidString)")
            ]
        )
        request.httpMethod = "GET"
        let data = try await perform(request)
        return try JSONDecoder().decode([MembershipRow].self, from: data)
    }

    /// Records only operational presence metadata. Dining content remains in
    /// the separately encrypted record and photo streams.
    func touchMembership(circleID: UUID, appVersion: String) async throws {
        var request = try await authorizedRequest(path: "rpc/touch_circle_membership", queryItems: [])
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "target_circle": circleID.uuidString,
            "client_version": appVersion
        ])
        _ = try await perform(request)
    }

    /// The circle's sealed name. Only a member can read the row, and only a
    /// device holding the circle key can open the value.
    func circleNameCipher(circleID: UUID) async throws -> String? {
        var request = try await authorizedRequest(
            path: "circles",
            queryItems: [
                URLQueryItem(name: "select", value: "name_cipher"),
                URLQueryItem(name: "id", value: "eq.\(circleID.uuidString)")
            ]
        )
        request.httpMethod = "GET"
        let data = try await perform(request)
        struct Row: Decodable {
            let nameCipher: String?
            enum CodingKeys: String, CodingKey { case nameCipher = "name_cipher" }
        }
        return try JSONDecoder().decode([Row].self, from: data).first?.nameCipher
    }

    func createCircle(id: UUID, nameCipher: String, personID: UUID) async throws {
        var request = try await authorizedRequest(path: "rpc/create_circle", queryItems: [])
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "target_circle": id.uuidString,
            "encrypted_name": nameCipher,
            "target_person": personID.uuidString
        ])
        _ = try await perform(request)
    }

    /// Registers a join code. The service receives the code's hash and the
    /// sealed key envelope, never the code itself, so it cannot redeem the
    /// invitation or open the circle.
    func createJoinCode(
        circleID: UUID,
        codeHash: String,
        envelope: CircleCrypto.KeyEnvelope,
        validForDays: Int = 7
    ) async throws {
        try await callVoidRPC("create_join_code", body: [
            "target_circle": circleID.uuidString,
            "code_digest": codeHash,
            "key_envelope": envelope.sealed,
            "key_salt": envelope.salt,
            "valid_for": "\(validForDays) days"
        ])
    }

    struct RedeemedInvite: Decodable, Sendable {
        let circleID: UUID
        let sealedKey: String
        let salt: String

        enum CodingKeys: String, CodingKey {
            case circleID = "circle_id"
            case sealedKey = "key_envelope"
            case salt = "key_salt"
        }

        var envelope: CircleCrypto.KeyEnvelope {
            CircleCrypto.KeyEnvelope(sealed: sealedKey, salt: salt)
        }
    }

    /// Claims membership and collects the sealed circle key in one transaction.
    func redeemJoinCode(codeHash: String, personID: UUID) async throws -> RedeemedInvite {
        var request = try await authorizedRequest(path: "rpc/redeem_join_code", queryItems: [])
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code_digest": codeHash,
            "target_person": personID.uuidString
        ])
        let data = try await perform(request)
        guard let redeemed = try JSONDecoder().decode([RedeemedInvite].self, from: data).first else {
            throw SyncTransportError.malformedResponse
        }
        return redeemed
    }

    /// Cancels every outstanding invitation for a circle.
    func revokeJoinCodes(circleID: UUID) async throws {
        try await callVoidRPC("revoke_join_codes", body: ["target_circle": circleID.uuidString])
    }

    /// Repoints this account's membership at the member profile it actually
    /// uses, after two devices converge on one person record.
    func setMemberPerson(circleID: UUID, personID: UUID) async throws {
        try await callVoidRPC("set_circle_member_person", body: [
            "target_circle": circleID.uuidString,
            "target_person": personID.uuidString
        ])
    }

    func removeMember(circleID: UUID, userID: UUID) async throws {
        try await callVoidRPC("remove_circle_member", body: [
            "target_circle": circleID.uuidString,
            "target_user": userID.uuidString
        ])
    }

    func leaveCircle(circleID: UUID) async throws {
        try await callVoidRPC("leave_circle", body: ["target_circle": circleID.uuidString])
    }

    /// Permanently removes the encrypted database rows and every Storage object.
    /// The first RPC freezes member writes; retries then continue emptying the
    /// bucket until the final transactional circle delete can complete.
    func deleteCircleData(circleID: UUID) async throws {
        try await callVoidRPC("begin_circle_deletion", body: ["target_circle": circleID.uuidString])

        while true {
            let names = try await listPhotoObjectNames(circleID: circleID)
            guard !names.isEmpty else { break }
            try await deletePhotoObjects(names.map { "\(circleID.uuidString)/\($0)" })
        }

        try await callVoidRPC("finish_circle_deletion", body: ["target_circle": circleID.uuidString])
    }

    func deleteAccount() async throws {
        try await callVoidRPC("delete_sync_account", body: [:])
        signOut()
    }

    // MARK: - Records

    /// Pulls one page of everything in `circleID` changed at or after `since`.
    func pullRecords(circleID: UUID, since watermark: Int64, after cursor: PullCursor?) async throws -> [RemoteRecord] {
        var queryItems = [
            URLQueryItem(name: "select", value: "kind,id,payload,deleted,updated_ms,device_id"),
            URLQueryItem(name: "circle_id", value: "eq.\(circleID.uuidString)"),
            URLQueryItem(name: "updated_ms", value: "gte.\(watermark)"),
            URLQueryItem(name: "order", value: "updated_ms.asc,kind.asc,id.asc"),
            URLQueryItem(name: "limit", value: String(Self.pullPageSize))
        ]
        if let cursor {
            queryItems.append(URLQueryItem(name: "or", value: cursor.postgrestFilter))
        }
        var request = try await authorizedRequest(
            path: "records",
            queryItems: queryItems
        )
        request.httpMethod = "GET"
        let data = try await perform(request)
        return try JSONDecoder().decode([RemoteRecord].self, from: data)
    }

    func pushRecords(_ records: [OutgoingRecord]) async throws {
        guard !records.isEmpty else { return }
        for batch in records.chunked(into: Self.pushBatchSize) {
            var request = try await authorizedRequest(path: "records", queryItems: [])
            request.httpMethod = "POST"
            request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try encoder.encode(batch)
            _ = try await perform(request)
        }
    }

    // MARK: - Photo blobs

    func uploadPhoto(circleID: UUID, objectKey: String, sealed: Data) async throws {
        var request = try await storageRequest(objectKey: objectKey, circleID: circleID)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // Re-uploading the same object must not fail: a retry after a dropped
        // connection is normal, and the bytes are content-addressed by photo id.
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.httpBody = sealed
        _ = try await perform(request)
    }

    func downloadPhoto(circleID: UUID, objectKey: String) async throws -> Data? {
        var request = try await storageRequest(objectKey: objectKey, circleID: circleID)
        request.httpMethod = "GET"
        do {
            return try await perform(request)
        } catch SyncTransportError.notFound {
            return nil
        }
    }

    func deletePhoto(circleID: UUID, objectKey: String) async throws {
        var request = try await storageRequest(objectKey: objectKey, circleID: circleID)
        request.httpMethod = "DELETE"
        do {
            _ = try await perform(request)
        } catch SyncTransportError.notFound {
            // Deletion is idempotent. A peer or an earlier retry may already
            // have removed the object.
        }
    }

    private func storageRequest(objectKey: String, circleID: UUID) async throws -> URLRequest {
        let url = configuration.storageURL
            .appendingPathComponent("object")
            .appendingPathComponent("circle-photos")
            .appendingPathComponent(circleID.uuidString)
            .appendingPathComponent(objectKey)

        var request = URLRequest(url: url)
        let token = try await authorizedToken()
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func listPhotoObjectNames(circleID: UUID) async throws -> [String] {
        var request = URLRequest(
            url: configuration.storageURL
                .appendingPathComponent("object/list/circle-photos")
        )
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await authorizedToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prefix": circleID.uuidString,
            "limit": 1000,
            "offset": 0,
            "sortBy": ["column": "name", "order": "asc"]
        ])
        let data = try await perform(request)
        struct ObjectRow: Decodable { let name: String }
        return try JSONDecoder().decode([ObjectRow].self, from: data).map(\.name)
    }

    private func deletePhotoObjects(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        var request = URLRequest(
            url: configuration.storageURL
                .appendingPathComponent("object/circle-photos")
        )
        request.httpMethod = "DELETE"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await authorizedToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prefixes": paths])
        _ = try await perform(request)
    }

    private func callVoidRPC(_ name: String, body: [String: Any]) async throws {
        var request = try await authorizedRequest(path: "rpc/\(name)", queryItems: [])
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    // MARK: - Plumbing

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func authorizedRequest(path: String, queryItems: [URLQueryItem]) async throws -> URLRequest {
        let token = try await authorizedToken()
        var url = configuration.restURL.appendingPathComponent(path)
        if !queryItems.isEmpty { url = appending(queryItems: queryItems, to: url) }

        var request = URLRequest(url: url)
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func tokenURL(grantType: String) -> URL {
        appending(
            queryItems: [URLQueryItem(name: "grant_type", value: grantType)],
            to: configuration.authURL.appendingPathComponent("token")
        )
    }

    private func appending(queryItems: [URLQueryItem], to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? url
    }

    @discardableResult
    private func perform(_ request: URLRequest, allowRetry: Bool = true) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncTransportError.offline(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.malformedResponse }

        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 401:
            // One transparent retry: an access token can expire between the
            // freshness check and the server reading it.
            if allowRetry, let refreshToken = current?.refreshToken ?? CircleKeychain.refreshToken {
                let renewed = try await refresh(using: refreshToken)
                var retried = request
                retried.setValue("Bearer \(renewed.accessToken)", forHTTPHeaderField: "Authorization")
                return try await perform(retried, allowRetry: false)
            }
            throw SyncTransportError.unauthorized
        case 403:
            throw SyncTransportError.forbidden(Self.message(from: data))
        case 404:
            throw SyncTransportError.notFound
        case 409:
            throw SyncTransportError.conflict(Self.message(from: data))
        case 429, 500 ..< 600:
            throw SyncTransportError.serverUnavailable(http.statusCode, Self.message(from: data))
        default:
            throw SyncTransportError.requestFailed(http.statusCode, Self.message(from: data))
        }
    }

    private static func message(from data: Data) -> String {
        struct Failure: Decodable {
            let message: String?
            let error: String?
            let errorDescription: String?
            let hint: String?

            enum CodingKeys: String, CodingKey {
                case message, error, hint
                case errorDescription = "error_description"
            }
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            let text = failure.message ?? failure.errorDescription ?? failure.error ?? failure.hint
            if let text, !text.isEmpty { return text }
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}

enum SyncTransportError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case notFound
    case conflict(String)
    case offline(String)
    case serverUnavailable(Int, String)
    case requestFailed(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Sign in again to keep this circle in sync."
        case let .forbidden(detail):
            "This account no longer has access to that synced circle. Your on-device log is unchanged. \(detail)"
        case .notFound:
            "That record is no longer on the sync service."
        case let .conflict(detail):
            "The sync service rejected a conflicting change. \(detail)"
        case let .offline(detail):
            "The sync service could not be reached. Your log is saved on this iPhone. \(detail)"
        case let .serverUnavailable(code, detail):
            "The sync service is temporarily unavailable (\(code)). Changes stay on this iPhone and will retry. \(detail)"
        case let .requestFailed(code, detail):
            "The sync service returned an unexpected response (\(code)). \(detail)"
        case .malformedResponse:
            "The sync service returned a response the app could not read."
        }
    }

    /// Distinguishes "try again later" from "this needs the person to act".
    var isTransient: Bool {
        switch self {
        case .offline, .serverUnavailable: true
        case .unauthorized, .forbidden, .notFound, .conflict, .requestFailed, .malformedResponse: false
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [Array(self)] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
