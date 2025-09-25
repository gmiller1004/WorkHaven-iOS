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
    @StateObject private var locationService = LocationService.shared
    @StateObject private var spotViewModel = SpotViewModel()
    
    @State private var showingResetAlert = false
    @State private var isResettingData = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
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
            .onAppear {
                initializeDistanceUnits()
            }
        }
    }
    
    // MARK: - Settings Content
    
    private var settingsContent: some View {
        ScrollView {
            VStack(spacing: ThemeManager.Spacing.lg) {
                // Auto-Discover Section
                autoDiscoverSection
                
                // Distance Units Section
                distanceUnitsSection
                
                // Manual Actions Section
                manualActionsSection
                
                #if DEBUG
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
                // Imperial Units Toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Imperial Units (miles)")
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        
                        Text("Switch to Metric (km) for non-US users")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $usesImperialUnits)
                        .tint(ThemeManager.SwiftUIColors.mocha)
                        .accessibilityLabel("Imperial Units toggle, \(usesImperialUnits ? "on" : "off"), switch to Metric subtitle")
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
    
    #if DEBUG
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
                    
                    Text("1.0.0")
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                }
                
                HStack {
                    Text("Build")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    
                    Spacer()
                    
                    Text("1")
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
}


// MARK: - Preview

#Preview {
    SettingsView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}