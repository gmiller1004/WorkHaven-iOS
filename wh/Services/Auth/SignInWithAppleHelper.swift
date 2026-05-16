//
//  SignInWithAppleHelper.swift
//  WorkHaven
//

import AuthenticationServices
import CryptoKit
import Foundation

enum SignInWithAppleError: LocalizedError {
    case invalidCredential
    case missingIdentityToken
    
    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Sign in with Apple did not return a valid credential."
        case .missingIdentityToken:
            return "Sign in with Apple did not return an identity token."
        }
    }
}

/// Performs Sign in with Apple and returns the identity token + raw nonce for Supabase.
@MainActor
final class SignInWithAppleHelper: NSObject {
    
    static let shared = SignInWithAppleHelper()
    
    private var currentNonce: String?
    private var continuation: CheckedContinuation<(idToken: String, nonce: String), Error>?
    
    private override init() {
        super.init()
    }
    
    static func makeNonce() -> String {
        randomNonceString()
    }
    
    static func hashedNonce(_ nonce: String) -> String {
        sha256(nonce)
    }
    
    func performSignIn() async throws -> (idToken: String, nonce: String) {
        let nonce = Self.makeNonce()
        currentNonce = nonce
        
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.hashedNonce(nonce)
        
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }
    
    private static func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        result.reserveCapacity(length)
        
        for _ in 0..<length {
            if let random = charset.randomElement() {
                result.append(random)
            }
        }
        return result
    }
    
    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

extension SignInWithAppleHelper: ASAuthorizationControllerDelegate {
    
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let continuation else { return }
            self.continuation = nil
            
            guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = appleCredential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                continuation.resume(throwing: SignInWithAppleError.invalidCredential)
                return
            }
            
            continuation.resume(returning: (idToken: idToken, nonce: nonce))
        }
    }
    
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }
}

extension SignInWithAppleHelper: ASAuthorizationControllerPresentationContextProviding {
    
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}
