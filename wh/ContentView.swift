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
            SpotListView()
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
                if hasPerformedInitialLoad {
                    // Reload spots if location changed after initial load
                    logger.info("Location changed, reloading spots")
                    Task {
                        await spotViewModel.loadSpots(near: location)
                    }
                } else {
                    // Trigger initial load if location became available
                    logger.info("Location became available, triggering initial load")
                    hasPerformedInitialLoad = true // Set flag immediately to prevent race condition
                    Task {
                        await spotViewModel.loadSpots(near: location)
                    }
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
     * Loads spots using current location or fallback location
     * Uses Task to avoid redundant calls and ensures proper async handling
     */
    private func loadSpotsIfNeeded() {
        // Prevent redundant calls
        guard !hasPerformedInitialLoad else {
            logger.debug("Initial load already performed, skipping")
            return
        }
        
        // If we already have location, use it immediately
        if let location = locationService.currentLocation {
            logger.info("Loading spots with current location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            Task {
                await spotViewModel.loadSpots(near: location)
                hasPerformedInitialLoad = true
            }
        } else {
            logger.info("No user location available, waiting for location or using fallback")
            // Wait a bit for location to be available, then proceed with fallback
            Task {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                
                // Check if initial load was already performed by onChange handler
                guard !hasPerformedInitialLoad else {
                    logger.debug("Initial load already performed by onChange handler, skipping")
                    return
                }
                
                let location = locationService.currentLocation ?? fallbackLocation
                logger.info("Loading spots with location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
                await spotViewModel.loadSpots(near: location)
                hasPerformedInitialLoad = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}