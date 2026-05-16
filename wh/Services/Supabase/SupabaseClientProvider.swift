//
//  SupabaseClientProvider.swift
//  WorkHaven
//

import Foundation
import Supabase
import OSLog

/// Shared Supabase client for community data and auth.
@MainActor
final class SupabaseClientProvider {
    
    static let shared = SupabaseClientProvider()
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "Supabase")
    
    private(set) var client: SupabaseClient?
    
    private init() {
        configureIfPossible()
    }
    
    var isConfigured: Bool {
        client != nil
    }
    
    func configureIfPossible() {
        guard let url = AppConfig.supabaseURL,
              let anonKey = AppConfig.supabaseAnonKey else {
            logger.warning("Supabase is not configured (missing SUPABASE_URL or SUPABASE_ANON_KEY)")
            client = nil
            return
        }
        
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
        logger.info("Supabase client configured")
    }
    
    func requireClient() throws -> SupabaseClient {
        guard let client else {
            throw SupabaseCommunityError.notConfigured
        }
        return client
    }
}
