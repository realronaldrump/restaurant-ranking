import Foundation
import XCTest
@testable import RestaurantLog

final class SupabaseClientTests: XCTestCase {
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let circleID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let personID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func tearDown() {
        SupabaseURLProtocol.reset()
        super.tearDown()
    }

    func testCircleEnrollmentUsesOneTransactionalRPC() async throws {
        SupabaseURLProtocol.respond { _ in (200, Data("null".utf8)) }
        let client = makeClient()

        try await client.createCircle(id: circleID, nameCipher: "sealed", personID: personID)

        let request = try XCTUnwrap(SupabaseURLProtocol.requests.first)
        XCTAssertEqual(SupabaseURLProtocol.requests.count, 1)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/create_circle")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["target_circle"], circleID.uuidString)
        XCTAssertEqual(json["target_person"], personID.uuidString)
        XCTAssertEqual(json["encrypted_name"], "sealed")
    }

    func testJoinCodeCreationUploadsOnlyTheHashAndTheSealedEnvelope() async throws {
        SupabaseURLProtocol.respond { _ in (200, Data("null".utf8)) }
        let client = makeClient()
        let code = CircleJoinCode.random()
        let envelope = CircleCrypto.KeyEnvelope(sealed: "sealed-key", salt: "salt")

        try await client.createJoinCode(circleID: circleID, codeHash: code.hash, envelope: envelope)

        let request = try XCTUnwrap(SupabaseURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/create_join_code")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["target_circle"], circleID.uuidString)
        XCTAssertEqual(json["code_digest"], code.hash)
        XCTAssertEqual(json["key_envelope"], "sealed-key")
        XCTAssertEqual(json["key_salt"], "salt")
        // The code itself must never reach the service in any field.
        let raw = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(raw.contains(code.normalized))
        XCTAssertFalse(raw.contains(code.formatted))
    }

    func testRedeemingAJoinCodeReturnsTheCircleAndItsSealedKey() async throws {
        let response = """
        [{"circle_id":"\(circleID.uuidString)","key_envelope":"sealed-key","key_salt":"salt"}]
        """
        SupabaseURLProtocol.respond { _ in (200, Data(response.utf8)) }
        let client = makeClient()

        let redeemed = try await client.redeemJoinCode(codeHash: "digest", personID: personID)

        XCTAssertEqual(redeemed.circleID, circleID)
        XCTAssertEqual(redeemed.envelope.sealed, "sealed-key")
        XCTAssertEqual(redeemed.envelope.salt, "salt")
        let request = try XCTUnwrap(SupabaseURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/redeem_join_code")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(json["code_digest"], "digest")
        XCTAssertEqual(json["target_person"], personID.uuidString)
    }

    /// Membership must never look successful when the service returned nothing,
    /// or the app would store a key for a circle it cannot read.
    func testRedeemingRejectsAnEmptyResponse() async throws {
        SupabaseURLProtocol.respond { _ in (200, Data("[]".utf8)) }
        let client = makeClient()

        do {
            _ = try await client.redeemJoinCode(codeHash: "digest", personID: personID)
            XCTFail("Expected an empty redemption to fail")
        } catch {
            XCTAssertEqual(error as? SyncTransportError, .malformedResponse)
        }
    }

    func testServiceDeletionEmptiesStorageBeforeDeletingTheCircle() async throws {
        SupabaseURLProtocol.respond { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/rest/v1/rpc/begin_circle_deletion"):
                return (200, Data("null".utf8))
            case ("POST", "/storage/v1/object/list/circle-photos"):
                let listCount = SupabaseURLProtocol.requests.filter {
                    $0.url?.path == "/storage/v1/object/list/circle-photos"
                }.count
                return listCount == 1
                    ? (200, Data("[{\"name\":\"photo.full\"},{\"name\":\"photo.thumb\"}]".utf8))
                    : (200, Data("[]".utf8))
            case ("DELETE", "/storage/v1/object/circle-photos"):
                return (200, Data("[]".utf8))
            case ("POST", "/rest/v1/rpc/finish_circle_deletion"):
                return (200, Data("null".utf8))
            default:
                return (500, Data("unexpected request".utf8))
            }
        }
        let client = makeClient()

        try await client.deleteCircleData(circleID: circleID)

        let requests = SupabaseURLProtocol.requests
        XCTAssertEqual(requests.map(\.url?.path), [
            "/rest/v1/rpc/begin_circle_deletion",
            "/storage/v1/object/list/circle-photos",
            "/storage/v1/object/circle-photos",
            "/storage/v1/object/list/circle-photos",
            "/rest/v1/rpc/finish_circle_deletion"
        ])
        let deletion = try XCTUnwrap(requests.first { $0.httpMethod == "DELETE" })
        let body = try XCTUnwrap(deletion.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        XCTAssertEqual(json["prefixes"], [
            "\(circleID.uuidString)/photo.full",
            "\(circleID.uuidString)/photo.thumb"
        ])
    }

    /// Supabase Storage's legacy API reports a missing object as HTTP 400 even
    /// though the structured error is `not_found`. Deleting an already deleted
    /// photo is success, not a sync failure.
    func testDeletingAMissingPhotoIsIdempotentForLegacyStorageResponses() async throws {
        SupabaseURLProtocol.respond { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (400, Data(#"{"statusCode":"404","error":"not_found","message":"Object not found"}"#.utf8))
        }
        let client = makeClient()

        try await client.deletePhoto(circleID: circleID, objectKey: "photo.full")

        XCTAssertEqual(SupabaseURLProtocol.requests.count, 1)
    }

    func testDeletingAPhotoStillSurfacesUnrelatedBadRequests() async throws {
        SupabaseURLProtocol.respond { _ in
            (400, Data(#"{"statusCode":"400","error":"invalid_request","message":"Invalid object key"}"#.utf8))
        }
        let client = makeClient()

        do {
            try await client.deletePhoto(circleID: circleID, objectKey: "photo.full")
            XCTFail("Expected a malformed deletion request to fail")
        } catch let error as SyncTransportError {
            XCTAssertEqual(error, .requestFailed(400, "Invalid object key"))
        }
    }

    func testCurrentAccountMembershipQueryCannotReturnPeerRows() async throws {
        SupabaseURLProtocol.respond { _ in (200, Data("[]".utf8)) }
        let client = makeClient()

        _ = try await client.memberships()

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(SupabaseURLProtocol.requests.first?.url),
            resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "user_id" })?.value,
            "eq.\(userID.uuidString)"
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "select" })?.value,
            "circle_id,user_id,person_id,role,joined_at,last_seen_at,app_version"
        )
    }

    func testMembershipPresenceDecodesAppVersionAndLastActivity() async throws {
        let body = """
        [{"circle_id":"\(circleID.uuidString)","user_id":"\(userID.uuidString)","person_id":"\(personID.uuidString)","role":"owner","joined_at":"2026-07-29T18:00:00Z","last_seen_at":"2026-07-29T20:15:12.345Z","app_version":"3.0.2 (13)"}]
        """
        SupabaseURLProtocol.respond { _ in (200, Data(body.utf8)) }
        let client = makeClient()

        let memberships = try await client.members(circleID: circleID)
        let membership = try XCTUnwrap(memberships.first)

        XCTAssertEqual(membership.appVersion, "3.0.2 (13)")
        XCTAssertNotNil(membership.joinedAt)
        XCTAssertNotNil(membership.lastSeenAt)
    }

    func testTouchMembershipUsesAuthenticatedRPCAndVersionMetadata() async throws {
        SupabaseURLProtocol.respond { _ in (200, Data("null".utf8)) }
        let client = makeClient()

        try await client.touchMembership(circleID: circleID, appVersion: "3.0.2 (13)")

        let request = try XCTUnwrap(SupabaseURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/touch_circle_membership")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["target_circle"], circleID.uuidString)
        XCTAssertEqual(json["client_version"], "3.0.2 (13)")
    }

    func testPushingRecordsEncodesLivePayloadAndTombstoneStateTogether() async throws {
        SupabaseURLProtocol.respond { _ in (201, Data()) }
        let client = makeClient()
        let liveID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let tombstoneID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

        try await client.pushRecords([
            .init(circleID: circleID, kind: "visit", id: liveID, payload: "sealed", deleted: false, deviceID: userID),
            .init(circleID: circleID, kind: "visit", id: tombstoneID, payload: nil, deleted: true, deviceID: userID)
        ])

        let request = try XCTUnwrap(SupabaseURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/records")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)

        let live = try XCTUnwrap(rows.first { ($0["id"] as? String) == liveID.uuidString })
        XCTAssertEqual(live["payload"] as? String, "sealed")
        XCTAssertEqual(live["deleted"] as? Bool, false)

        let tombstone = try XCTUnwrap(rows.first { ($0["id"] as? String) == tombstoneID.uuidString })
        XCTAssertTrue(tombstone["payload"] is NSNull)
        XCTAssertEqual(tombstone["deleted"] as? Bool, true)

        XCTAssertEqual(Set(rows.flatMap(\.keys)), [
            "circle_id", "kind", "id", "payload", "deleted", "device_id"
        ])
    }

    func testOwnerRemovalUsesVerifiedRPCInsteadOfSilentRLSDelete() async throws {
        SupabaseURLProtocol.respond { _ in (200, Data("true".utf8)) }
        let client = makeClient()
        let removedUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        try await client.removeMember(circleID: circleID, userID: removedUserID)

        let request = try XCTUnwrap(SupabaseURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/remove_circle_member")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(json["target_circle"], circleID.uuidString)
        XCTAssertEqual(json["target_user"], removedUserID.uuidString)
    }

    func testLeavingUsesVerifiedRPCInsteadOfSilentRLSDelete() async throws {
        SupabaseURLProtocol.respond { _ in (200, Data("true".utf8)) }
        let client = makeClient()

        try await client.leaveCircle(circleID: circleID)

        let request = try XCTUnwrap(SupabaseURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/leave_circle")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(json["target_circle"], circleID.uuidString)
    }

    func testForbiddenResponseDoesNotRefreshAValidSession() async {
        SupabaseURLProtocol.respond { _ in
            (403, Data("{\"message\":\"row-level security policy denied access\"}".utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.memberships()
            XCTFail("Expected the RLS denial to be surfaced")
        } catch let error as SyncTransportError {
            XCTAssertEqual(error, .forbidden("row-level security policy denied access"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(SupabaseURLProtocol.requests.count, 1)
        XCTAssertEqual(SupabaseURLProtocol.requests.first?.url?.path, "/rest/v1/circle_members")
    }

    private func makeClient() -> SupabaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupabaseURLProtocol.self]
        return SupabaseClient(
            configuration: SyncConfiguration(
                baseURL: URL(string: "https://project.supabase.co")!,
                anonKey: "public-anon-key"
            ),
            session: URLSession(configuration: configuration),
            initialSession: .init(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: .now.addingTimeInterval(3_600),
                userID: userID
            )
        )
    }
}

@MainActor
final class SyncCoordinatorLifecycleTests: XCTestCase {
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let ownerCircleID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let memberCircleID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    override func tearDown() {
        SupabaseURLProtocol.reset()
        super.tearDown()
    }

    func testResetRetiresEveryOwnedAndJoinedCircleBeforeSucceeding() async throws {
        let memberships = """
        [
          {"circle_id":"\(ownerCircleID.uuidString)","user_id":"\(userID.uuidString)","person_id":"33333333-3333-3333-3333-333333333333","role":"owner","joined_at":"2026-08-01T15:00:00Z","last_seen_at":null,"app_version":"3.2 (20)"},
          {"circle_id":"\(memberCircleID.uuidString)","user_id":"\(userID.uuidString)","person_id":"55555555-5555-5555-5555-555555555555","role":"member","joined_at":"2026-08-01T15:01:00Z","last_seen_at":null,"app_version":"3.2 (20)"}
        ]
        """
        SupabaseURLProtocol.respond { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/rest/v1/circle_members"):
                return (200, Data(memberships.utf8))
            case ("POST", "/rest/v1/rpc/begin_circle_deletion"):
                return (200, Data("null".utf8))
            case ("POST", "/storage/v1/object/list/circle-photos"):
                return (200, Data("[]".utf8))
            case ("POST", "/rest/v1/rpc/finish_circle_deletion"):
                return (200, Data("null".utf8))
            case ("POST", "/rest/v1/rpc/leave_circle"):
                return (200, Data("null".utf8))
            default:
                return (500, Data("unexpected request".utf8))
            }
        }
        let configuration = SyncConfiguration(
            baseURL: URL(string: "https://project.supabase.co")!,
            anonKey: "public-anon-key"
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SupabaseURLProtocol.self]
        let client = SupabaseClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration),
            initialSession: .init(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: .now.addingTimeInterval(3_600),
                userID: userID
            )
        )
        let persistence = PersistenceController(inMemory: true)
        let coordinator = SyncCoordinator(
            container: persistence.container,
            configuration: configuration,
            client: client
        )
        await coordinator.restoreSession()

        let resetSucceeded = await coordinator.resetSyncedCircles()
        XCTAssertTrue(resetSucceeded)

        XCTAssertEqual(SupabaseURLProtocol.requests.map(\.url?.path), [
            "/rest/v1/circle_members",
            "/rest/v1/rpc/begin_circle_deletion",
            "/storage/v1/object/list/circle-photos",
            "/rest/v1/rpc/finish_circle_deletion",
            "/rest/v1/rpc/leave_circle"
        ])
        XCTAssertTrue(coordinator.isSignedIn)
        XCTAssertNil(coordinator.lastError)
    }
}

private final class SupabaseURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, data: Data)
    private static let state = State()

    static var requests: [URLRequest] { state.requests }

    static func respond(with handler: @escaping Handler) {
        state.reset(handler: handler)
    }

    static func reset() {
        state.reset(handler: nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let capturedRequest = Self.materializingBody(in: request)
        let response = Self.state.handle(capturedRequest)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func materializingBody(in request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        var captured = request
        captured.httpBodyStream = nil
        captured.httpBody = result
        return captured
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: Handler?
        private var storedRequests: [URLRequest] = []

        var requests: [URLRequest] {
            lock.withLock { storedRequests }
        }

        func reset(handler: Handler?) {
            lock.withLock {
                self.handler = handler
                storedRequests = []
            }
        }

        func handle(_ request: URLRequest) -> (status: Int, data: Data) {
            let currentHandler = lock.withLock {
                storedRequests.append(request)
                return handler
            }
            return currentHandler?(request) ?? (500, Data("missing handler".utf8))
        }
    }
}
