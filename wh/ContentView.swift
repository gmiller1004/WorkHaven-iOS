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
        NavigationView {
            TabView {
            // MARK: - List Tab
            SpotListView()
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
            
            // MARK: - Settings Tab
            SettingsView()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityLabel("Settings tab")
                .tag(2)
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
                        // Clear spots from previous location to prevent mixing
                        spotViewModel.clearSpotsForLocationChange()
                        // Load spots with the new location
                        Task {
                            await spotViewModel.loadSpots(near: location)
                        }
                    }
                }
                .onChange(of: locationService.errorMessage) { errorMessage in
                    // Show alert if location service has an error
                    if errorMessage != nil {
                        showingLocationError = true
                    }
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
}

// MARK: - OnboardingView

/**
 * OnboardingView provides a one-time permission request flow for new users.
 * Requests location and notification permissions with clear explanations.
 * Uses ThemeManager for consistent styling and includes accessibility support.
 */
struct OnboardingView: View {
    
    // MARK: - Properties
    
    @Binding var isRequestingPermissions: Bool
    let onPermissionsGranted: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    // Logger for debugging
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "OnboardingView")
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            VStack(spacing: ThemeManager.Spacing.lg) {
                // MARK: - Header
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
                    
                    Text("Discover the best work spots near you")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, ThemeManager.Spacing.xl)
                
                // MARK: - Permission Explanations
                VStack(spacing: ThemeManager.Spacing.lg) {
                    PermissionRowView(
                        icon: "location.fill",
                        title: "Location Access",
                        description: "Find work spots near your current location and get accurate distances"
                    )
                    
                    PermissionRowView(
                        icon: "bell.fill",
                        title: "Notifications",
                        description: "Get notified about new work spots and updates"
                    )
                }
                .padding(.horizontal, ThemeManager.Spacing.lg)
                
                Spacer()
                
                // MARK: - Action Buttons
                VStack(spacing: ThemeManager.Spacing.md) {
                    Button(action: requestPermissions) {
                        HStack {
                            if isRequestingPermissions {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: ThemeManager.SwiftUIColors.latte))
                                    .scaleEffect(0.8)
                            }
                            Text(isRequestingPermissions ? "Requesting Permissions..." : "Grant Permissions")
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
                    .accessibilityLabel("Grant location and notification permissions")
                    
                    Button("Skip for Now") {
                        onPermissionsGranted()
                    }
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .accessibilityLabel("Skip permission requests for now")
                }
                .padding(.horizontal, ThemeManager.Spacing.lg)
                .padding(.bottom, ThemeManager.Spacing.xl)
            }
            .background(ThemeManager.SwiftUIColors.latte)
            .navigationBarHidden(true)
        }
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

// MARK: - PermissionRowView

/**
 * PermissionRowView displays a single permission request with icon and description.
 * Uses ThemeManager for consistent styling and includes accessibility support.
 */
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
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .multilineTextAlignment(.leading)
            }
            
            Spacer()
        }
        .padding(ThemeManager.Spacing.md)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(ThemeManager.CornerRadius.small)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.small)
                .stroke(ThemeManager.SwiftUIColors.coral.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}