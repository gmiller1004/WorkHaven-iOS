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
    
    // MARK: - Body
    
    var body: some View {
        TabView {
            // MARK: - Spots Tab
            SpotListView(spotViewModel: spotViewModel)
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("Spots", systemImage: "mappin.circle")
                }
                .accessibilityLabel("Spots tab")
                .tag(0)
            
            // MARK: - Settings Tab
            SettingsView()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityLabel("Settings tab")
                .tag(1)
        }
        .accentColor(ThemeManager.SwiftUIColors.coral)
        .onAppear {
            loadSpotsIfNeeded()
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
    }
    
    // MARK: - Methods
    
    /**
     * Initializes the app and loads spots with the shared SpotViewModel
     */
    private func loadSpotsIfNeeded() {
        guard !hasPerformedInitialLoad else { return }
        
        logger.info("ContentView initializing spot loading")
        hasPerformedInitialLoad = true
        
        // Use current location or fallback
        let locationToUse = locationService.currentLocation ?? fallbackLocation
        
        Task {
            await spotViewModel.loadSpots(near: locationToUse)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}