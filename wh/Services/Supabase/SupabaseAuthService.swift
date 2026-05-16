//
//  SupabaseAuthService.swift
//  WorkHaven
//

import Foundation
import Supabase
import OSLog

enum SupabaseAuthError: LocalizedError {
    case communitySignInRequired
    
    var errorDescription: String? {
        switch self {
        case .communitySignInRequired:
            return "Sign in with Apple is required to post reviews, photos, and tips."
        }
    }
}

/// Silent anonymous sessions for reading; Sign in with Apple for community writes.
@MainActor
final class SupabaseAuthService: ObservableObject {
    
    static let shared = SupabaseAuthService()
    
    @Published private(set) var isCommunityWriter = false
    @Published private(set) var userID: UUID?
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SupabaseAuth")
    
    private init() {}
    
    /// Ensures an anonymous session exists so RLS-authenticated reads work.
    func ensureAnonymousSession() async {
        guard SupabaseClientProvider.shared.isConfigured else { return }
        
        do {
            let client = try SupabaseClientProvider.shared.requireClient()
            
            if let session = try? await client.auth.session {
                applySession(session)
                logger.info("Existing Supabase session found")
                return
            }
            
            let session = try await client.auth.signInAnonymously()
            applySession(session)
            logger.info("Signed in anonymously to Supabase")
        } catch {
            logger.error("Supabase anonymous sign-in failed: \(error.localizedDescription)")
        }
    }
    
    /// Presents Sign in with Apple and upgrades the session for community writes.
    func signInWithApple() async throws {
        let (idToken, nonce) = try await SignInWithAppleHelper.shared.performSignIn()
        try await signInWithApple(idToken: idToken, nonce: nonce)
    }
    
    /// Links Sign in with Apple to the current session (including anonymous).
    func signInWithApple(idToken: String, nonce: String) async throws {
        let client = try SupabaseClientProvider.shared.requireClient()
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: idToken,
                nonce: nonce
            )
        )
        applySession(session)
        logger.info("Signed in with Apple for community features")
    }
    
    /// Requires a non-anonymous session before posting UGC.
    func requireCommunityWriter() throws {
        guard SupabaseClientProvider.shared.isConfigured else { return }
        guard canWriteCommunityContent, let userID else {
            throw SupabaseAuthError.communitySignInRequired
        }
        _ = userID
    }
    
    var canWriteCommunityContent: Bool {
        isCommunityWriter
    }
    
    /// Returns to an anonymous read-only session after signing out of Apple.
    func signOutToAnonymous() async {
        guard SupabaseClientProvider.shared.isConfigured else { return }
        
        do {
            let client = try SupabaseClientProvider.shared.requireClient()
            try await client.auth.signOut()
            let session = try await client.auth.signInAnonymously()
            applySession(session)
            logger.info("Returned to anonymous Supabase session")
        } catch {
            logger.error("Supabase sign-out failed: \(error.localizedDescription)")
        }
    }
    
    private func applySession(_ session: Session) {
        userID = session.user.id
        isCommunityWriter = !session.user.isAnonymous
    }
}
