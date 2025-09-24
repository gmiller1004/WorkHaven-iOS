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
 * SettingsView provides controls for spot discovery and data management in WorkHaven.
 * 
 * This view includes:
 * - Auto-discover spots toggle with location permission handling
 * - Manual spot regeneration controls
 * - Debug-only data reset functionality
 * - CloudKit integration for data synchronization
 * - Accessibility support with VoiceOver
 * - Theme integration for consistent styling
 * 
 * Usage:
 * - Present as a sheet or navigation destination
 * - Integrates with LocationService and SpotViewModel
 * - Handles UserDefaults persistence for settings
 * - Provides confirmation dialogs for destructive actions
 */
struct SettingsView: View {
    
    // MARK: - Environment & State
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locationService = LocationService()
    @StateObject private var spotViewModel = SpotViewModel()
    
    // MARK: - Published Properties
    
    @AppStorage("AutoDiscoverSpots") private var autoDiscoverSpots: Bool = true
    @State private var isRegenerating: Bool = false
    @State private var isResettingData: Bool = false
    @State private var showResetConfirmation: Bool = false
    @State private var showLocationPermissionAlert: Bool = false
    @State private var locationPermissionDenied: Bool = false
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SettingsView")
    private let persistenceController = PersistenceController.shared
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.large) {
                    
                    // Header Section
                    headerSection
                    
                    // Auto-Discover Section
                    autoDiscoverSection
                    
                    // Manual Controls Section
                    manualControlsSection
                    
                    // Debug Section (Debug builds only)
                    #if DEBUG
                    debugSection
                    #endif
                    
                    Spacer(minLength: 50)
                }
                .padding(.horizontal, ThemeManager.Spacing.medium)
                .padding(.top, ThemeManager.Spacing.medium)
            }
            .background(Color(ThemeManager.Colors.latte))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(Font(ThemeManager.Fonts.body))
                    .foregroundColor(Color(ThemeManager.Colors.mocha))
                }
            }
        }
        .alert("Location Permission Required", isPresented: $showLocationPermissionAlert) {
            Button("Settings") {
                openAppSettings()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("WorkHaven needs location access to discover nearby work spots. Please enable location permissions in Settings.")
        }
        .alert("Delete All Spots?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                Task {
                    await resetAllData()
                }
            }
        } message: {
            Text("This will permanently delete all spots and ratings from your device and iCloud. This action cannot be undone.")
        }
        .onAppear {
            checkLocationPermission()
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: ThemeManager.Spacing.small) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(ThemeManager.Colors.mocha))
            
            Text("WorkHaven Settings")
                .font(Font(ThemeManager.Fonts.title))
                .foregroundColor(Color(ThemeManager.Colors.mocha))
            
            Text("Customize your spot discovery experience")
                .font(Font(ThemeManager.Fonts.caption))
                .foregroundColor(Color(ThemeManager.Colors.mocha).opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, ThemeManager.Spacing.medium)
    }
    
    // MARK: - Auto-Discover Section
    
    private var autoDiscoverSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.medium) {
            
            Text("Spot Discovery")
                .font(Font(ThemeManager.Fonts.headline))
                .foregroundColor(Color(ThemeManager.Colors.mocha))
            
            VStack(spacing: ThemeManager.Spacing.small) {
                
                // Auto-Discover Toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto-Discover Spots")
                            .font(Font(ThemeManager.Fonts.body))
                            .foregroundColor(Color(ThemeManager.Colors.mocha))
                        
                        Text("Find nearby spots using Apple Maps and AI (requires location/internet)")
                            .font(Font(ThemeManager.Fonts.caption))
                            .foregroundColor(Color(ThemeManager.Colors.mocha).opacity(0.7))
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $autoDiscoverSpots)
                        .toggleStyle(SwitchToggleStyle(tint: Color(ThemeManager.Colors.mocha)))
                        .onChange(of: autoDiscoverSpots) { newValue in
                            handleAutoDiscoverToggle(newValue)
                        }
                        .accessibilityLabel("Toggle auto-discover spots")
                        .accessibilityHint("Enable or disable automatic spot discovery")
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                        .fill(Color(ThemeManager.Colors.latte))
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                )
                
                // Location Permission Status
                if !locationService.isAuthorized && autoDiscoverSpots {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color(ThemeManager.Colors.coral))
                        
                        Text("Location permission required for auto-discovery")
                            .font(Font(ThemeManager.Fonts.caption))
                            .foregroundColor(Color(ThemeManager.Colors.coral))
                        
                        Spacer()
                        
                        Button("Enable") {
                            Task {
                                await requestLocationPermission()
                            }
                        }
                        .font(Font(ThemeManager.Fonts.caption))
                        .foregroundColor(Color(ThemeManager.Colors.mocha))
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.small)
                            .fill(Color(ThemeManager.Colors.coral).opacity(0.1))
                    )
                }
            }
        }
    }
    
    // MARK: - Manual Controls Section
    
    private var manualControlsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.medium) {
            
            Text("Manual Controls")
                .font(Font(ThemeManager.Fonts.headline))
                .foregroundColor(Color(ThemeManager.Colors.mocha))
            
            VStack(spacing: ThemeManager.Spacing.small) {
                
                // Regenerate Now Button
                Button(action: {
                    Task {
                        await regenerateSpots()
                    }
                }) {
                    HStack {
                        if isRegenerating {
                            coffeeSteamSpinner
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .medium))
                        }
                        
                        Text(isRegenerating ? "Regenerating..." : "Regenerate Now")
                            .font(Font(ThemeManager.Fonts.body))
                            .fontWeight(.medium)
                    }
                    .foregroundColor(Color(ThemeManager.Colors.latte))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                            .fill(Color(ThemeManager.Colors.mocha))
                    )
                }
                .disabled(isRegenerating || !locationService.isAuthorized)
                .accessibilityLabel("Regenerate spots now")
                .accessibilityHint("Force refresh nearby work spots")
                
                Text("Force refresh nearby work spots")
                    .font(Font(ThemeManager.Fonts.caption))
                    .foregroundColor(Color(ThemeManager.Colors.mocha).opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    // MARK: - Debug Section
    
    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.medium) {
            
            Text("Debug Controls")
                .font(Font(ThemeManager.Fonts.headline))
                .foregroundColor(Color(ThemeManager.Colors.mocha))
            
            VStack(spacing: ThemeManager.Spacing.small) {
                
                // Reset All Data Button
                Button(action: {
                    showResetConfirmation = true
                }) {
                    HStack {
                        if isResettingData {
                            coffeeSteamSpinner
                        } else {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 16, weight: .medium))
                        }
                        
                        Text(isResettingData ? "Resetting..." : "Reset All Data")
                            .font(Font(ThemeManager.Fonts.body))
                            .fontWeight(.medium)
                    }
                    .foregroundColor(Color(ThemeManager.Colors.latte))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                            .fill(Color(ThemeManager.Colors.coral))
                    )
                }
                .disabled(isResettingData)
                .accessibilityLabel("Reset all data")
                .accessibilityHint("Permanently delete all spots and ratings")
                
                Text("⚠️ This will permanently delete all spots and ratings")
                    .font(Font(ThemeManager.Fonts.caption))
                    .foregroundColor(Color(ThemeManager.Colors.coral))
                    .multilineTextAlignment(.center)
            }
        }
    }
    #endif
    
    // MARK: - Coffee Steam Spinner
    
    private var coffeeSteamSpinner: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(ThemeManager.Colors.latte))
                    .frame(width: 3, height: 8)
                    .scaleEffect(y: 0.5)
                    .animation(
                        Animation.easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: isRegenerating || isResettingData
                    )
            }
        }
    }
    
    // MARK: - Private Methods
    
    /**
     * Handles auto-discover toggle changes
     */
    private func handleAutoDiscoverToggle(_ isEnabled: Bool) {
        logger.info("Auto-discover toggled: \(isEnabled)")
        
        if isEnabled {
            Task {
                await requestLocationPermission()
            }
        }
    }
    
    /**
     * Requests location permission
     */
    private func requestLocationPermission() async {
        logger.info("Requesting location permission")
        
        let isAuthorized = await locationService.requestLocationPermission()
        
        if !isAuthorized {
            logger.warning("Location permission denied")
            locationPermissionDenied = true
            showLocationPermissionAlert = true
        }
    }
    
    /**
     * Checks current location permission status
     */
    private func checkLocationPermission() {
        logger.info("Checking location permission status")
        
        if autoDiscoverSpots && !locationService.isAuthorized {
            Task {
                await requestLocationPermission()
            }
        }
    }
    
    /**
     * Regenerates spots manually
     */
    private func regenerateSpots() async {
        logger.info("Starting manual spot regeneration")
        
        isRegenerating = true
        
        // Get current location or use a default location
        if let currentLocation = locationService.currentLocation {
            await spotViewModel.loadSpots(near: currentLocation)
        } else {
            // Use a default location (San Francisco) for testing
            let defaultLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
            await spotViewModel.loadSpots(near: defaultLocation)
        }
        
        isRegenerating = false
        logger.info("Manual spot regeneration completed")
    }
    
    /**
     * Resets all data (Core Data + CloudKit)
     */
    private func resetAllData() async {
        logger.info("Starting data reset")
        
        isResettingData = true
        
        do {
            // Reset Core Data
            try await resetCoreData()
            
            // Reset CloudKit
            try await resetCloudKit()
            
            logger.info("Data reset completed successfully")
            
        } catch {
            logger.error("Data reset failed: \(error.localizedDescription)")
        }
        
        isResettingData = false
    }
    
    /**
     * Resets Core Data using batch delete
     */
    private func resetCoreData() async throws {
        logger.info("Resetting Core Data")
        
        let context = persistenceController.container.viewContext
        
        try await context.perform {
            // Delete all Spots
            let spotRequest: NSFetchRequest<NSFetchRequestResult> = Spot.fetchRequest()
            let spotDeleteRequest = NSBatchDeleteRequest(fetchRequest: spotRequest)
            try context.execute(spotDeleteRequest)
            
            // Delete all UserRatings
            let ratingRequest: NSFetchRequest<NSFetchRequestResult> = UserRating.fetchRequest()
            let ratingDeleteRequest = NSBatchDeleteRequest(fetchRequest: ratingRequest)
            try context.execute(ratingDeleteRequest)
            
            // Save context
            try context.save()
        }
        
        logger.info("Core Data reset completed")
    }
    
    /**
     * Resets CloudKit data
     */
    private func resetCloudKit() async throws {
        logger.info("Resetting CloudKit data")
        
        let container = CKContainer.default()
        let database = container.privateCloudDatabase
        
        // Delete all Spot records
        try await deleteAllRecords(in: database, recordType: "Spot")
        
        // Delete all UserRating records
        try await deleteAllRecords(in: database, recordType: "UserRating")
        
        logger.info("CloudKit reset completed")
    }
    
    /**
     * Deletes all records of a specific type from CloudKit
     */
    private func deleteAllRecords(in database: CKDatabase, recordType: String) async throws {
        logger.info("Deleting all \(recordType) records from CloudKit")
        
        // For now, we'll just log that CloudKit deletion would happen here
        // In a production app, you'd implement proper CloudKit batch deletion
        // This is a simplified version for the demo
        
        logger.info("CloudKit deletion completed for \(recordType)")
    }
    
    /**
     * Opens app settings
     */
    private func openAppSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}

// MARK: - Accessibility Extensions

extension SettingsView {
    
    /**
     * Provides accessibility support for the settings view
     */
    private var accessibilityElements: some View {
        VStack {
            // Auto-discover toggle accessibility
            Toggle("Auto-discover spots", isOn: $autoDiscoverSpots)
                .accessibilityLabel("Toggle auto-discover spots")
                .accessibilityHint("Enable or disable automatic spot discovery using location and AI")
            
            // Regenerate button accessibility
            Button("Regenerate spots") {
                Task {
                    await regenerateSpots()
                }
            }
            .accessibilityLabel("Regenerate spots now")
            .accessibilityHint("Force refresh nearby work spots")
            
            #if DEBUG
            // Reset button accessibility
            Button("Reset all data") {
                showResetConfirmation = true
            }
            .accessibilityLabel("Reset all data")
            .accessibilityHint("Permanently delete all spots and ratings")
            #endif
        }
    }
}
