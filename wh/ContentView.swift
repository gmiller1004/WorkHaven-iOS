//
//  ContentView.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import SwiftUI
import CoreData
import CoreLocation
import OSLog
import UserNotifications

/**
 * ContentView provides the main TabView navigation for WorkHaven.
 * Features tab-based navigation between spots discovery and settings.
 * Uses ThemeManager for consistent styling and includes accessibility support.
 * Manages location services and spot loading with intelligent fallback handling.
 */
struct ContentView: View {
    
    // MARK: - Properties
    
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var locationService = LocationService.shared
    @StateObject private var spotViewModel = SpotViewModel()
    
    // Fallback location (San Francisco) if current location is unavailable
    private let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
    
    // Logger for debugging
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "ContentView")
    
    // Track if initial load has been performed to avoid redundant calls
    @State private var hasPerformedInitialLoad = false
    @Environment(\.scenePhase) private var scenePhase
    
    // Alert state for location errors
    @State private var showingLocationError = false
    
    // Onboarding state for permissions
    @State private var hasRequestedPermissions = UserDefaults.standard.bool(forKey: "HasRequestedPermissions")
    @State private var showingOnboarding = false
    @State private var isRequestingPermissions = false
    
    // iPad detection
    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    
    // MARK: - Body
    
    var body: some View {
        TabView {
            // MARK: - List Tab
            SpotListView(spotViewModel: spotViewModel)
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("List", systemImage: "list.bullet")
                }
                .accessibilityLabel("List tab")
                .tag(0)
            
            // MARK: - Map Tab
            MapView(spotViewModel: spotViewModel)
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("Map", systemImage: "map")
                }
                .accessibilityLabel("Map tab")
                .tag(1)
            
            // MARK: - Favorites Tab
            FavoritesListView()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("Favorites", systemImage: "heart.fill")
                }
                .accessibilityLabel("Favorites tab")
                .tag(2)

            // MARK: - Settings Tab
            SettingsView()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityLabel("Settings tab")
                .tag(3)
        }
        .accentColor(ThemeManager.SwiftUIColors.coral)
        .onAppear {
            if isIPad {
                // Apply iPad-specific styling for swipeable tabs
                UITabBar.appearance().itemPositioning = .centered
                UITabBar.appearance().itemSpacing = 20
            }
            
            if !hasRequestedPermissions {
                showingOnboarding = true
            } else {
                // Wait for location before loading spots to avoid San Francisco fallback
                if locationService.currentLocation != nil {
                    loadSpotsIfNeeded()
                } else {
                    logger.info("Waiting for location before loading spots")
                }
            }
        }
        .onChange(of: locationService.currentLocation) { newLocation in
            if let location = newLocation {
                logger.info("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
                Task {
                    await spotViewModel.handleLocationUpdate(location)
                }
            }
        }
        .onChange(of: locationService.errorMessage) { errorMessage in
            // Show alert if location service has an error
            if errorMessage != nil {
                showingLocationError = true
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await syncFavoritesAndCheckActivity()
            }
        }
        .task {
            await syncFavoritesAndCheckActivity()
        }
        .alert("Location Error", isPresented: $showingLocationError) {
            Button("OK", role: .cancel) {
                locationService.clearError()
            }
            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
        } message: {
            Text(locationService.errorMessage ?? "Location services are unavailable")
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
        }
        .background(ThemeManager.SwiftUIColors.latte)
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(
                isRequestingPermissions: $isRequestingPermissions,
                onPermissionsGranted: {
                    hasRequestedPermissions = true
                    UserDefaults.standard.set(true, forKey: "HasRequestedPermissions")
                    showingOnboarding = false
                    // Don't load spots immediately - wait for location update
                    logger.info("Permissions granted, waiting for location update")
                }
            )
        }
    }
    
    // MARK: - Methods
    
    /**
     * Initializes the app and loads spots with the shared SpotViewModel
     */
    private func loadSpotsIfNeeded() {
        guard !hasPerformedInitialLoad else { return }
        
        // Use current location or fallback
        let location = locationService.currentLocation ?? fallbackLocation
        
        logger.info("ContentView initializing spot loading")
        hasPerformedInitialLoad = true
        
        Task {
            await spotViewModel.loadSpots(near: location)
        }
    }

    private func syncFavoritesAndCheckActivity() async {
        guard AppConfig.isSupabaseConfigured else { return }
        await SupabaseAuthService.shared.ensureAnonymousSession()
        do {
            try await SupabaseFavoritesService.shared.syncFavoritesToCoreData()
        } catch {
            logger.warning("Favorites sync failed: \(error.localizedDescription)")
        }
        await FavoriteActivityMonitor.shared.checkForUpdates()
    }
}

// MARK: - OnboardingView

/**
 * OnboardingView introduces WorkHaven and requests permissions with clear context.
 */
struct OnboardingView: View {
    
    @Binding var isRequestingPermissions: Bool
    let onPermissionsGranted: () -> Void
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "OnboardingView")
    
    private static let privacyPolicyURL = URL(string: "https://nextsizzle.com/appfamily/workhaven/privacy")!
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {
                    headerSection
                    valuePropositionSection
                    featuresSection
                    permissionsSection
                    privacySection
                }
                .padding(.horizontal, ThemeManager.Spacing.lg)
                .padding(.top, ThemeManager.Spacing.xl)
                .padding(.bottom, ThemeManager.Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            
            continueButtonBar
        }
        .background(ThemeManager.SwiftUIColors.latte)
        .dismissKeyboardOnTap()
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                .accessibilityHidden(true)
            
            Text("Welcome to WorkHaven")
                .font(ThemeManager.SwiftUIFonts.title)
                .fontWeight(.bold)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            
            Text("Your guide to work-friendly cafés, libraries, parks, and co-working spaces—rated for WiFi, noise, outlets, and real-world tips from people who work there.")
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .multilineTextAlignment(.center)
        }
    }
    
    private var valuePropositionSection: some View {
        OnboardingSectionCard(title: "Why WorkHaven?") {
            Text("Remote work shouldn’t mean guessing whether a café has reliable WiFi or a quiet corner. WorkHaven surfaces spots near you with practical ratings so you can pick a place and get to work—not wander around hoping for an open outlet.")
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var featuresSection: some View {
        OnboardingSectionCard(title: "What you’ll get") {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                OnboardingFeatureRow(
                    icon: "wifi",
                    text: "WiFi, noise, and outlet ratings for every spot"
                )
                OnboardingFeatureRow(
                    icon: "map",
                    text: "A map and list sorted by distance and quality"
                )
                OnboardingFeatureRow(
                    icon: "lightbulb.fill",
                    text: "Community tips from people who’ve actually worked there"
                )
                OnboardingFeatureRow(
                    icon: "person.2.fill",
                    text: "Browse freely—sign in with Apple only when you want to add a review, photo, or tip"
                )
            }
        }
    }
    
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("A better experience with permissions")
                .font(ThemeManager.SwiftUIFonts.headline)
                .fontWeight(.semibold)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            PermissionRowView(
                icon: "location.fill",
                title: "Location (recommended)",
                description: "We use your location only to find spots around you, sort by distance, and center the map. WorkHaven does not track you in the background for this—location is used while you use the app to discover and navigate to places."
            )
            
            PermissionRowView(
                icon: "bell.fill",
                title: "Notifications (optional)",
                description: "Optional alerts when great new spots appear nearby or when the community shares updates on places you care about. You can turn these off anytime in Settings."
            )
        }
    }
    
    private var privacySection: some View {
        OnboardingSectionCard(title: "Your privacy") {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                Text("WorkHaven is built to respect your data:")
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                OnboardingFeatureRow(
                    icon: "lock.fill",
                    text: "Browse spots and community content without creating an account"
                )
                OnboardingFeatureRow(
                    icon: "apple.logo",
                    text: "Sign in with Apple only when you choose to post a rating, photo, or tip"
                )
                OnboardingFeatureRow(
                    icon: "hand.raised.fill",
                    text: "We don’t sell your location or personal information"
                )
                
                Link("Read our Privacy Policy", destination: Self.privacyPolicyURL)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                    .padding(.top, ThemeManager.Spacing.xs)
            }
        }
    }
    
    private var continueButtonBar: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(ThemeManager.SwiftUIColors.mocha.opacity(0.15))
            
            Button(action: requestPermissions) {
                HStack {
                    if isRequestingPermissions {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: ThemeManager.SwiftUIColors.latte))
                            .scaleEffect(0.8)
                    }
                    Text(isRequestingPermissions ? "Requesting Permissions..." : "Continue")
                        .font(ThemeManager.SwiftUIFonts.button)
                        .fontWeight(.semibold)
                }
                .foregroundColor(ThemeManager.SwiftUIColors.latte)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(ThemeManager.SwiftUIColors.mocha)
                .cornerRadius(ThemeManager.CornerRadius.medium)
            }
            .disabled(isRequestingPermissions)
            .accessibilityLabel("Continue to request location and notification permissions")
            .padding(.horizontal, ThemeManager.Spacing.lg)
            .padding(.vertical, ThemeManager.Spacing.md)
        }
        .background(ThemeManager.SwiftUIColors.latte)
    }
    
    // MARK: - Methods
    
    /**
     * Requests both location and notification permissions
     */
    private func requestPermissions() {
        isRequestingPermissions = true
        
        Task {
            do {
                // Request location permission
                let locationGranted = await LocationService.shared.requestWhenInUsePermission()
                logger.info("Location permission granted: \(locationGranted)")
                
                // Request notification permission
                let notificationSettings = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                logger.info("Notification permission granted: \(notificationSettings)")
                
                await MainActor.run {
                    isRequestingPermissions = false
                    onPermissionsGranted()
                }
            } catch {
                logger.error("Failed to request permissions: \(error.localizedDescription)")
                await MainActor.run {
                    isRequestingPermissions = false
                    onPermissionsGranted() // Continue even if permissions fail
                }
            }
        }
    }
}

// MARK: - Onboarding helpers

private struct OnboardingSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text(title)
                .font(ThemeManager.SwiftUIFonts.headline)
                .fontWeight(.semibold)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            content
        }
        .padding(ThemeManager.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(ThemeManager.CornerRadius.medium)
        .shadow(
            color: ThemeManager.SwiftUIColors.mocha.opacity(0.08),
            radius: 4,
            x: 0,
            y: 2
        )
    }
}

private struct OnboardingFeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                .frame(width: 22, alignment: .center)
                .accessibilityHidden(true)
            
            Text(text)
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - PermissionRowView

struct PermissionRowView: View {
    
    // MARK: - Properties
    
    let icon: String
    let title: String
    let description: String
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                .frame(width: 30)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
                Text(title)
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Text(description)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding(ThemeManager.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(ThemeManager.CornerRadius.small)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.small)
                .stroke(ThemeManager.SwiftUIColors.coral.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}