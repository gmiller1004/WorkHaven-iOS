//
//  SupabaseAuthService.swift
//  WorkHaven
//

import Foundation
import Supabase
import OSLog

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
    
    var canWriteCommunityContent: Bool {
        isCommunityWriter
    }
    
    private func applySession(_ session: Session) {
        userID = session.user.id
        isCommunityWriter = !session.user.isAnonymous
    }
}
