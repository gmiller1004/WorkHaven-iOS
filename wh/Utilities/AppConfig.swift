//
//  AppConfig.swift
//  WorkHaven
//

import Foundation

/// Build-time configuration from Info.plist / Secrets.xcconfig.
enum AppConfig {
    
    static var supabaseURL: URL? {
        url(forInfoKey: "SUPABASE_URL")
    }
    
    static var supabaseAnonKey: String? {
        string(forInfoKey: "SUPABASE_ANON_KEY")
    }
    
    static var isSupabaseConfigured: Bool {
        supabaseURL != nil && supabaseAnonKey != nil
    }
    
    private static func url(forInfoKey key: String) -> URL? {
        guard let raw = string(forInfoKey: key) else { return nil }
        return URL(string: raw)
    }
    
    private static func string(forInfoKey key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
            return value
        }
        return nil
    }
}
