import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Sign in with Apple, used only to prove which member a device belongs to.
///
/// The app asks for no scopes beyond what Apple returns by default and stores
/// nothing from the credential except the resulting session token. The identity
/// exists so the sync service can authorise rows; it is not a profile, and the
/// dining records behind it are encrypted with a key the service never sees.
@MainActor
final class AppleSignIn: NSObject {
    struct Credential {
        let identityToken: String
        let rawNonce: String
    }

    private var continuation: CheckedContinuation<Credential, Error>?
    private var currentNonce: String?
    private var controller: ASAuthorizationController?
    private var requestIsActive = false

    func requestCredential() async throws -> Credential {
        guard !requestIsActive else { throw AppleSignInError.requestAlreadyInProgress }
        requestIsActive = true
        let nonce = Self.makeNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        // Apple embeds the hash; Supabase is handed the raw value and checks
        // that the two correspond, which is what defeats token replay.
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<Credential, Error>) {
        let pending = continuation
        continuation = nil
        currentNonce = nil
        controller = nil
        requestIsActive = false
        switch result {
        case let .success(credential): pending?.resume(returning: credential)
        case let .failure(error): pending?.resume(throwing: error)
        }
    }

    // MARK: - Nonce

    private static func makeNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // Unreserved URL characters only, so the value survives every transport
        // between here and the token endpoint unchanged.
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._~")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppleSignIn: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                finish(.failure(AppleSignInError.missingIdentityToken))
                return
            }
            finish(.success(Credential(identityToken: token, rawNonce: nonce)))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                finish(.failure(AppleSignInError.cancelled))
            } else {
                finish(.failure(error))
            }
        }
    }
}

extension AppleSignIn: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { Self.activePresentationAnchor() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { Self.activePresentationAnchor() }
        }
    }

    @MainActor
    private static func activePresentationAnchor() -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}

enum AppleSignInError: LocalizedError {
    case cancelled
    case missingIdentityToken
    case requestAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Sign in was cancelled."
        case .missingIdentityToken:
            "Apple did not return an identity token, so the circle could not be linked to this device."
        case .requestAlreadyInProgress:
            "Sign in with Apple is already in progress."
        }
    }
}
