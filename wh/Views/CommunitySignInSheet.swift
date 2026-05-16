//
//  CommunitySignInSheet.swift
//  WorkHaven
//

import AuthenticationServices
import SwiftUI

/// Prompts for Sign in with Apple before posting community content.
struct CommunitySignInSheet: View {
    
    let featureTitle: String
    let onSignedIn: () -> Void
    let onCancel: () -> Void
    
    @ObservedObject private var authService = SupabaseAuthService.shared
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var currentNonce: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: ThemeManager.Spacing.lg) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 48))
                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                
                Text("Sign in to contribute")
                    .font(ThemeManager.SwiftUIFonts.title)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Text("Sign in with Apple to \(featureTitle). Your reviews, photos, and tips are shared with the WorkHaven community.")
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ThemeManager.Spacing.md)
                
                if let errorMessage {
                    Text(errorMessage)
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                SignInWithAppleButton(.signIn) { request in
                    let nonce = SignInWithAppleHelper.makeNonce()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = SignInWithAppleHelper.hashedNonce(nonce)
                } onCompletion: { result in
                    handleSignInResult(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .padding(.horizontal, ThemeManager.Spacing.lg)
                .disabled(isSigningIn)
                
                if isSigningIn {
                    ProgressView()
                        .tint(ThemeManager.SwiftUIColors.coral)
                }
                
                Spacer()
            }
            .padding(.top, ThemeManager.Spacing.xl)
            .background(ThemeManager.SwiftUIColors.latte)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                }
            }
        }
    }
    
    private func handleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                errorMessage = "Sign in with Apple did not return a valid credential."
                return
            }
            
            Task {
                await completeSignIn(idToken: idToken, nonce: nonce)
            }
            
        case .failure(let error):
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue {
                return
            }
            errorMessage = error.localizedDescription
        }
    }
    
    private func completeSignIn(idToken: String, nonce: String) async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        
        do {
            try await authService.signInWithApple(idToken: idToken, nonce: nonce)
            onSignedIn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
