//
//  SettingsView.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import SwiftUI
import CoreData
import CloudKit
import OSLog

/**
 * SettingsView provides user controls for spot discovery preferences and debug options.
 * Features include auto-discovery toggle, manual regeneration, and data management tools.
 * Uses ThemeManager for consistent coffee shop aesthetic and includes accessibility support.
 */
struct SettingsView: View {
    
    // MARK: - Properties
    
    @AppStorage("AutoDiscoverSpots") private var autoDiscoverSpots: Bool = true
    @AppStorage("usesImperialUnits") private var usesImperialUnits: Bool = true
    @AppStorage("NearbyAlertsEnabled") private var nearbyAlertsEnabled: Bool = false
    @AppStorage("CommunityUpdatesEnabled") private var communityUpdatesEnabled: Bool = false
    @StateObject private var locationService = LocationService.shared
    @StateObject private var spotViewModel = SpotViewModel()
    @StateObject private var notificationManager = NotificationManager.shared
    
    @State private var showingResetAlert = false
    @State private var isResettingData = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    // Privacy compliance states
    @State private var showDeleteConfirmation = false
    @State private var showDeleteSuccess = false
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SettingsView")
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                ThemeManager.SwiftUIColors.latte
                    .ignoresSafeArea()
                
                if isResettingData {
                    // Coffee steam spinner during data reset
                    VStack(spacing: ThemeManager.Spacing.md) {
                        CoffeeSteamSpinner()
                        Text("Resetting all data...")
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    }
                } else {
                    // Settings content
                    settingsContent
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .alert("Delete all spots?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {
                    // Do nothing
                }
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Button("Delete", role: .destructive) {
                    Task {
                        await resetAllData()
                    }
                }
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            } message: {
                Text("This will permanently delete all spots and ratings from your device and iCloud. This action cannot be undone.")
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {
                    errorMessage = ""
                }
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            } message: {
                Text(errorMessage)
            }
            .alert("Delete My Data", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    showDeleteConfirmation = false
                }
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Button("Delete", role: .destructive) {
                    Task {
                        await deleteUserData()
                    }
                }
                .foregroundColor(.red)
            } message: {
                Text("This will permanently delete all your favorites, ratings, tips, and photos across devices. This action cannot be reversed. Continue?")
            }
            .alert("Data Deleted", isPresented: $showDeleteSuccess) {
                Button("OK", role: .cancel) {
                    showDeleteSuccess = false
                }
                .foregroundColor(ThemeManager.SwiftUIColors.coral)
            } message: {
                Text("Your data has been permanently deleted. Thank you for using WorkHaven.")
            }
            .onAppear {
                initializeDistanceUnits()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    // MARK: - Settings Content
    
    private var settingsContent: some View {
        ScrollView {
            VStack(spacing: ThemeManager.Spacing.lg) {
                // Auto-Discover Section
                autoDiscoverSection
                
                // Distance Units Section
                distanceUnitsSection
                
                // Notifications Section
                notificationsSection
                
                // Manual Actions Section
                manualActionsSection
                
                // Privacy Section
                privacySection
                
                #if targetEnvironment(simulator)
                // Debug Section
                debugSection
                #endif
                
                // App Info Section
                appInfoSection
            }
            .padding(ThemeManager.Spacing.md)
        }
    }
    
    // MARK: - Auto-Discover Section
    
    private var autoDiscoverSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("Spot Discovery")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            VStack(spacing: ThemeManager.Spacing.sm) {
                // Auto-Discover Toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto-Discover Spots")
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        
                        Text("Find nearby spots using Apple Maps and AI (requires location/internet)")
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $autoDiscoverSpots)
                        .tint(ThemeManager.SwiftUIColors.mocha)
                        .accessibilityLabel("Toggle auto-discover spots")
                        .onChange(of: autoDiscoverSpots) { newValue in
                            handleAutoDiscoverToggle(newValue)
                        }
                }
                .padding(ThemeManager.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                        .fill(Color.white)
                        .shadow(
                            color: ThemeManager.SwiftUIColors.mocha.opacity(0.1),
                            radius: 2,
                            x: 0,
                            y: 1
                        )
                )
                
                // Location Permission Status
                locationPermissionStatus
            }
        }
    }
    
    // MARK: - Distance Units Section
    
    private var distanceUnitsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("Distance Units")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            VStack(spacing: ThemeManager.Spacing.sm) {
                // Distance Units Picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Select your preferred distance unit")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    
                    Text("Choose between Imperial (miles) or Metric (kilometers)")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                }
                
                Picker("Distance Units", selection: $usesImperialUnits) {
                    Text("Imperial (miles)").tag(true)
                    Text("Metric (kilometers)").tag(false)
                }
                .pickerStyle(.segmented)
                .tint(ThemeManager.SwiftUIColors.mocha)
                .accessibilityLabel("Distance units picker, currently \(usesImperialUnits ? "Imperial miles" : "Metric kilometers")")
            }
            .padding(ThemeManager.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                    .fill(Color.white)
                    .shadow(
                        color: ThemeManager.SwiftUIColors.mocha.opacity(0.1),
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            )
        }
    }
    
    // MARK: - Notifications Section
    
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("Notifications")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            VStack(spacing: ThemeManager.Spacing.sm) {
                // Nearby Spot Alerts Toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nearby Spot Alerts")
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        
                        Text("Get alerts when near high-rated spots (requires always location)")
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $nearbyAlertsEnabled)
                        .tint(ThemeManager.SwiftUIColors.mocha)
                        .accessibilityLabel("Nearby Spot Alerts toggle")
                        .onChange(of: nearbyAlertsEnabled) { newValue in
                            handleNearbyAlertsToggle(newValue)
                        }
                }
                .padding(ThemeManager.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                        .fill(Color.white)
                        .shadow(
                            color: ThemeManager.SwiftUIColors.mocha.opacity(0.1),
                            radius: 2,
                            x: 0,
                            y: 1
                        )
                )
                
                // Community Updates Toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Community Updates")
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        
                        Text("Get updates on your favorited spots (new ratings, photos, tips)")
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $communityUpdatesEnabled)
                        .tint(ThemeManager.SwiftUIColors.mocha)
                        .accessibilityLabel("Community Updates toggle")
                        .onChange(of: communityUpdatesEnabled) { newValue in
                            handleCommunityUpdatesToggle(newValue)
                        }
                }
                .padding(ThemeManager.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                        .fill(Color.white)
                        .shadow(
                            color: ThemeManager.SwiftUIColors.mocha.opacity(0.1),
                            radius: 2,
                            x: 0,
                            y: 1
                        )
                )
                
                // Notification Permission Status
                notificationPermissionStatus
            }
        }
    }
    
    // MARK: - Location Permission Status
    
    private var locationPermissionStatus: some View {
        HStack {
            Image(systemName: locationService.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(locationService.isAuthorized ? .green : .orange)
            
            Text(locationService.isAuthorized ? "Location access granted" : "Location access required")
                .font(ThemeManager.SwiftUIFonts.caption)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
            
            Spacer()
        }
        .padding(.horizontal, ThemeManager.Spacing.md)
    }
    
    // MARK: - Notification Permission Status
    
    private var notificationPermissionStatus: some View {
        HStack {
            Image(systemName: notificationManager.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(notificationManager.isAuthorized ? .green : .orange)
            
            Text(notificationManager.isAuthorized ? "Notification permissions granted" : "Notification permissions required")
                .font(ThemeManager.SwiftUIFonts.caption)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
            
            Spacer()
        }
        .padding(.horizontal, ThemeManager.Spacing.md)
    }
    
    // MARK: - Manual Actions Section
    
    private var manualActionsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("Manual Actions")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            VStack(spacing: ThemeManager.Spacing.sm) {
                // Regenerate Now Button
                Button(action: {
                    Task {
                        await regenerateSpots()
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Regenerate Now")
                    }
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .frame(maxWidth: .infinity)
                    .padding(ThemeManager.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                            .fill(ThemeManager.SwiftUIColors.coral)
                    )
                }
                .accessibilityLabel("Regenerate spots now")
                .disabled(spotViewModel.isSeeding)
            }
        }
    }
    
    // MARK: - Privacy Section
    
    private var privacySection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("Privacy")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            VStack(spacing: ThemeManager.Spacing.sm) {
                // Delete My Data Button
                Button(action: {
                    showDeleteConfirmation = true
                }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Delete My Data")
                    }
                    .font(.custom("Avenir Next Medium", size: 16))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(ThemeManager.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                            .fill(Color(hex: "#FFF8E7"))
                    )
                }
                .accessibilityLabel("Delete My Data button, destructive action")
                .accessibilityHint("Tap to permanently delete all your personal data including favorites, ratings, tips, and photos")
            }
        }
    }
    
    #if targetEnvironment(simulator)
    // MARK: - Debug Section
    
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("Debug Tools")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            VStack(spacing: ThemeManager.Spacing.sm) {
                // Reset All Data Button
                Button(action: {
                    showingResetAlert = true
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Reset All Data")
                    }
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(ThemeManager.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                            .fill(.red)
                    )
                }
                .accessibilityLabel("Reset all data")
                .disabled(isResettingData)
            }
        }
    }
    #endif
    
    // MARK: - App Info Section
    
    private var appInfoSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("App Information")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            VStack(spacing: ThemeManager.Spacing.sm) {
                HStack {
                    Text("Version")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    
                    Spacer()
                    
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                }
                
                HStack {
                    Text("Build")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    
                    Spacer()
                    
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                }
            }
            .padding(ThemeManager.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                    .fill(Color.white)
                    .shadow(
                        color: ThemeManager.SwiftUIColors.mocha.opacity(0.1),
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            )
        }
    }
    
    // MARK: - Methods
    
    /**
     * Deletes all user-specific data for privacy compliance
     */
    private func deleteUserData() async {
        let context = PersistenceController.shared.container.viewContext
        
        do {
            // Delete UserRating entities
            let userRatingRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "UserRating")
            let userRatingDeleteRequest = NSBatchDeleteRequest(fetchRequest: userRatingRequest)
            try context.execute(userRatingDeleteRequest)
            
            // Delete UserTip entities
            let userTipRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "UserTip")
            let userTipDeleteRequest = NSBatchDeleteRequest(fetchRequest: userTipRequest)
            try context.execute(userTipDeleteRequest)
            
            // Delete UserFavorite entities
            let userFavoriteRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "UserFavorite")
            let userFavoriteDeleteRequest = NSBatchDeleteRequest(fetchRequest: userFavoriteRequest)
            try context.execute(userFavoriteDeleteRequest)
            
            // Delete Photo entities
            let photoRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Photo")
            let photoDeleteRequest = NSBatchDeleteRequest(fetchRequest: photoRequest)
            try context.execute(photoDeleteRequest)
            
            // Save context to trigger CloudKit sync
            try context.save()
            
            logger.info("Successfully deleted all user data for privacy compliance")
            
            // Show success alert
            await MainActor.run {
                showDeleteSuccess = true
                showDeleteConfirmation = false
            }
            
        } catch {
            logger.error("Failed to delete user data: \(error.localizedDescription)")
            await MainActor.run {
                errorMessage = "Failed to delete data: \(error.localizedDescription)"
                showingError = true
                showDeleteConfirmation = false
            }
        }
    }
    
    /**
     * Initializes distance units based on user's locale
     */
    private func initializeDistanceUnits() {
        // Only set default if this is the first launch (UserDefaults hasn't been set)
        if UserDefaults.standard.object(forKey: "usesImperialUnits") == nil {
            let regionCode = Locale.current.region?.identifier ?? ""
            let usesMetric = Locale.current.usesMetricSystem
            
            // Set Imperial for US, GB, LR; Metric for others
            let shouldUseImperial = regionCode == "US" || regionCode == "GB" || regionCode == "LR" || !usesMetric
            
            usesImperialUnits = shouldUseImperial
            logger.info("Initialized distance units: \(shouldUseImperial ? "Imperial" : "Metric") for region: \(regionCode)")
        }
    }
    
    /**
     * Handles auto-discover toggle changes
     */
    private func handleAutoDiscoverToggle(_ enabled: Bool) {
        if enabled {
            Task {
                let granted = await locationService.requestLocationPermission()
                if !granted {
                    logger.warning("Location permission denied, disabling auto-discover")
                    autoDiscoverSpots = false
                    errorMessage = "Location permission is required for auto-discovery"
                    showingError = true
                }
            }
        }
    }
    
    /**
     * Handles nearby alerts toggle changes
     */
    private func handleNearbyAlertsToggle(_ enabled: Bool) {
        if enabled {
            // Request notification permissions first
            notificationManager.requestAuthorization { granted in
                Task { @MainActor in
                    if granted {
                        // Schedule notifications for favorited spots
                        await self.scheduleNotificationsForFavoritedSpots()
                        self.logger.info("Nearby alerts enabled and scheduled")
                    } else {
                        self.logger.warning("Notification permission denied, disabling nearby alerts")
                        self.nearbyAlertsEnabled = false
                        self.errorMessage = "Notification permissions are required for nearby alerts"
                        self.showingError = true
                    }
                }
            }
        } else {
            // Cancel all nearby alerts when disabled
            cancelAllNearbyAlerts()
            logger.info("Nearby alerts disabled")
        }
    }
    
    /**
     * Handles community updates toggle changes
     */
    private func handleCommunityUpdatesToggle(_ enabled: Bool) {
        if enabled {
            // Request notification permissions first
            notificationManager.requestAuthorization { granted in
                Task { @MainActor in
                    if granted {
                        // Subscribe to CloudKit updates for favorited spots
                        await self.subscribeToCommunityUpdatesForFavoritedSpots()
                        self.logger.info("Community updates enabled and subscribed")
                    } else {
                        self.logger.warning("Notification permission denied, disabling community updates")
                        self.communityUpdatesEnabled = false
                        self.errorMessage = "Notification permissions are required for community updates"
                        self.showingError = true
                    }
                }
            }
        } else {
            // Unsubscribe from all community updates when disabled
            unsubscribeFromAllCommunityUpdates()
            logger.info("Community updates disabled")
        }
    }
    
    /**
     * Regenerates spots using current location
     */
    private func regenerateSpots() async {
        guard let location = locationService.currentLocation else {
            errorMessage = "Current location not available. Please enable location services."
            showingError = true
            return
        }
        
        await spotViewModel.refreshSpots(near: location)
        
        if let error = spotViewModel.errorMessage {
            errorMessage = error
            showingError = true
        }
    }
    
    /**
     * Resets all data from Core Data and CloudKit
     */
    private func resetAllData() async {
        isResettingData = true
        
        do {
            // Reset Core Data
            try await resetCoreData()
            
            // Reset CloudKit (simplified for demo)
            await resetCloudKit()
            
            logger.info("Successfully reset all data")
            
        } catch {
            logger.error("Failed to reset data: \(error.localizedDescription)")
            errorMessage = "Failed to reset data: \(error.localizedDescription)"
            showingError = true
        }
        
        isResettingData = false
    }
    
    /**
     * Resets Core Data using NSBatchDeleteRequest
     */
    private func resetCoreData() async throws {
        let context = PersistenceController.shared.container.viewContext
        
        // Delete UserRating entities first (due to relationship)
        let userRatingRequest = NSBatchDeleteRequest(fetchRequest: UserRating.fetchRequest())
        try context.execute(userRatingRequest)
        
        // Delete Spot entities
        let spotRequest = NSBatchDeleteRequest(fetchRequest: Spot.fetchRequest())
        try context.execute(spotRequest)
        
        // Save context
        try context.save()
        
        logger.info("Core Data reset completed")
    }
    
    /**
     * Resets CloudKit data (simplified implementation)
     */
    private func resetCloudKit() async {
        // Note: This is a simplified implementation for demo purposes
        // In a production app, you would implement proper CloudKit deletion
        logger.info("CloudKit reset completed (simplified implementation)")
    }
    
    /**
     * Schedules notifications for all favorited spots
     */
    private func scheduleNotificationsForFavoritedSpots() async {
        let context = PersistenceController.shared.container.viewContext
        
        do {
            let request = NSFetchRequest<Spot>(entityName: "Spot")
            request.predicate = NSPredicate(format: "favorites.@count > 0")
            let favoritedSpots = try context.fetch(request)
            
            for spot in favoritedSpots {
                // Schedule nearby alert for each favorited spot
                notificationManager.scheduleNearbyAlert(for: spot)
                logger.debug("Scheduled nearby alert for favorited spot: \(spot.name)")
            }
            
            logger.info("Scheduled notifications for \(favoritedSpots.count) favorited spots")
            
        } catch {
            logger.error("Failed to fetch favorited spots: \(error.localizedDescription)")
        }
    }
    
    /**
     * Cancels all nearby alerts
     */
    private func cancelAllNearbyAlerts() {
        let context = PersistenceController.shared.container.viewContext
        
        do {
            let request = NSFetchRequest<Spot>(entityName: "Spot")
            let allSpots = try context.fetch(request)
            
            for spot in allSpots {
                notificationManager.cancelNearbyAlert(for: spot)
            }
            
            logger.info("Cancelled nearby alerts for all spots")
            
        } catch {
            logger.error("Failed to fetch spots for cancellation: \(error.localizedDescription)")
        }
    }
    
    /**
     * Subscribes to community updates for all favorited spots
     */
    private func subscribeToCommunityUpdatesForFavoritedSpots() async {
        let context = PersistenceController.shared.container.viewContext
        
        do {
            let request = NSFetchRequest<Spot>(entityName: "Spot")
            request.predicate = NSPredicate(format: "favorites.@count > 0")
            let favoritedSpots = try context.fetch(request)
            
            for spot in favoritedSpots {
                // Subscribe to CloudKit updates for each favorited spot
                notificationManager.subscribeToCommunityUpdates(for: spot)
                logger.debug("Subscribed to community updates for favorited spot: \(spot.name)")
            }
            
            logger.info("Subscribed to community updates for \(favoritedSpots.count) favorited spots")
            
        } catch {
            logger.error("Failed to fetch favorited spots for subscription: \(error.localizedDescription)")
        }
    }
    
    /**
     * Unsubscribes from all community updates
     */
    private func unsubscribeFromAllCommunityUpdates() {
        let context = PersistenceController.shared.container.viewContext
        
        do {
            let request = NSFetchRequest<Spot>(entityName: "Spot")
            let allSpots = try context.fetch(request)
            
            for spot in allSpots {
                notificationManager.unsubscribeFromCommunityUpdates(for: spot)
            }
            
            logger.info("Unsubscribed from community updates for all spots")
            
        } catch {
            logger.error("Failed to fetch spots for unsubscription: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}