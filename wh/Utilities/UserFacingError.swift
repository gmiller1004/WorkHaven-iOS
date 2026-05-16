//
//  UserFacingError.swift
//  WorkHaven
//

import AuthenticationServices
import Foundation

/// Maps system and network errors to short copy suitable for alerts and sheets.
enum UserFacingError {
    
    /// Returns nil when the error should be ignored (e.g. user canceled sign-in).
    static func message(for error: Error, context: Context = .general) -> String? {
        if let authError = error as? ASAuthorizationError {
            return message(forAuthorizationCode: authError.code.rawValue)
        }
        
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain {
            return message(forAuthorizationCode: nsError.code)
        }
        
        switch context {
        case .signInWithApple:
            return "We couldn’t sign you in. Please try again."
        case .saveRating:
            return "Your rating couldn’t be saved. Please try again."
        case .savePhoto:
            return "Your photo couldn’t be uploaded. Please try again."
        case .saveTip:
            return "Your tip couldn’t be posted. Please try again."
        case .general:
            return "Something went wrong. Please try again."
        }
    }
    
    enum Context {
        case signInWithApple
        case saveRating
        case savePhoto
        case saveTip
        case general
    }
    
    private static func message(forAuthorizationCode code: Int) -> String? {
        switch code {
        case ASAuthorizationError.canceled.rawValue:
            return nil
        case ASAuthorizationError.unknown.rawValue:
            return "Sign in didn’t finish. Check that you’re signed into your Apple ID in Settings, then try again."
        case ASAuthorizationError.invalidResponse.rawValue:
            return "Apple couldn’t verify your sign in. Please try again."
        case ASAuthorizationError.notHandled.rawValue:
            return "Sign in isn’t available right now. Please try again."
        case ASAuthorizationError.failed.rawValue:
            return "Sign in failed. Please try again."
        case ASAuthorizationError.notInteractive.rawValue:
            return "Complete sign in when prompted, then try again."
        default:
            return "Sign in failed. Please try again."
        }
    }
}
