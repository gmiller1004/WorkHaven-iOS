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

/**
 * ContentView provides the main TabView navigation for WorkHaven.
 * Features tab-based navigation between spots discovery and settings.
 * Uses ThemeManager for consistent styling and includes accessibility support.
 */
struct ContentView: View {
    
    // MARK: - Properties
    
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var locationService = LocationService.shared
    @StateObject private var spotViewModel = SpotViewModel()
    
    // Fallback location (San Francisco) if current location is unavailable
    private let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
    
    // MARK: - Body
    
    var body: some View {
        TabView {
            // Spots Tab
            SpotListView()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Image(systemName: "mappin.circle")
                    Text("Spots")
                }
                .accessibilityLabel("Spots tab")
                .tag(0)
            
            // Settings Tab
            SettingsView()
                .environment(\.managedObjectContext, viewContext)
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
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
                Task {
                    await spotViewModel.loadSpots(near: location)
                }
            }
        }
    }
    
    // MARK: - Methods
    
    /**
     * Loads spots using current location or fallback location
     */
    private func loadSpotsIfNeeded() {
        let location = locationService.currentLocation ?? fallbackLocation
        
        Task {
            await spotViewModel.loadSpots(near: location)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}