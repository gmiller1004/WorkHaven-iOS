//
//  WorkHavenApp.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import SwiftUI
import OSLog
import CoreLocation
import CoreData

/**
 * WorkHavenApp is the main app entry point that handles:
 * - Core Data persistence with CloudKit sync
 * - Universal Links for spot sharing and deep linking
 * - Navigation state management for deep link handling
 * - App lifecycle and scene management
 */
@main
struct WorkHavenApp: App {
    let persistenceController = PersistenceController.shared
    @State private var navigationPath = NavigationPath()
    @State private var selectedSpot: Spot?
    @State private var showingSpotDetail = false
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "WorkHavenApp")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .onOpenURL { url in
                    handleUniversalLink(url)
                }
                .sheet(isPresented: $showingSpotDetail) {
                    if let spot = selectedSpot {
                        SpotDetailView(spot: spot, locationService: LocationService.shared)
                            .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    }
                }
        }
    }
    
    // MARK: - Universal Link Handling
    
    /**
     * Handles incoming Universal Links for spot sharing
     * - Parameter url: The incoming URL from Universal Links
     */
    private func handleUniversalLink(_ url: URL) {
        logger.info("Received Universal Link: \(url.absoluteString)")
        
        // Check if it's a WorkHaven spot link
        guard url.scheme == "workhaven" && url.host == "spot" else {
            logger.warning("Invalid Universal Link scheme or host: \(url.absoluteString)")
            return
        }
        
        // Extract spot ID from path components
        guard let spotID = url.pathComponents.last, !spotID.isEmpty else {
            logger.warning("No spot ID found in Universal Link: \(url.absoluteString)")
            return
        }
        
        logger.info("Processing spot ID: \(spotID)")
        
        // Find the spot using SpotViewModel
        Task { @MainActor in
            let spotViewModel = SpotViewModel()
            
            // Load spots first to ensure we have data
            if let currentLocation = LocationService.shared.currentLocation {
                await spotViewModel.loadSpots(near: currentLocation)
            } else {
                // Use a fallback location if current location is not available
                let fallbackLocation = CLLocation(latitude: 40.7000, longitude: -74.0100)
                await spotViewModel.loadSpots(near: fallbackLocation)
            }
            
            // Find the spot by CloudKit record ID
            if let spot = spotViewModel.spot(with: spotID) {
                logger.info("Found spot: \(spot.name) for ID: \(spotID)")
                selectedSpot = spot
                showingSpotDetail = true
            } else {
                logger.warning("Spot not found for ID: \(spotID)")
                // Could show an alert here to inform user that spot was not found
            }
        }
    }
}

// MARK: - SpotViewModel Extension

/**
 * Extension to SpotViewModel to support spot lookup by CloudKit record ID
 */
extension SpotViewModel {
    
    /**
     * Finds a spot by its CloudKit record ID
     * - Parameter spotID: The CloudKit record ID to search for
     * - Returns: The matching Spot if found, nil otherwise
     */
    func spot(with spotID: String) -> Spot? {
        let request: NSFetchRequest<Spot> = Spot.fetchRequest()
        request.predicate = NSPredicate(format: "cloudKitRecordID == %@", spotID)
        request.fetchLimit = 1
        
        do {
            let results = try viewContext.fetch(request)
            return results.first
        } catch {
            let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotViewModel")
            logger.error("Failed to fetch spot with ID \(spotID): \(error.localizedDescription)")
            return nil
        }
    }
}
