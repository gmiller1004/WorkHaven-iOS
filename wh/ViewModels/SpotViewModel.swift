//
//  SpotViewModel.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import CoreLocation
import CoreData
import SwiftUI
import OSLog

/**
 * SpotViewModel manages spot data, seeding, and display logic for WorkHaven.
 * Handles Core Data queries, spot discovery, intelligent sorting, and error management.
 * Provides a clean interface between the UI and the underlying data services.
 */
@MainActor
class SpotViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    /// Array of discovered spots, sorted by distance and rating
    @Published var spots: [Spot] = []
    
    /// Indicates if spot discovery is currently in progress
    @Published var isSeeding: Bool = false
    
    /// Discovery progress message for UI feedback
    @Published var discoveryProgress: String = ""
    
    /// Error message for user feedback
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    
    private let persistenceController: PersistenceController
    private let spotDiscoveryService: SpotDiscoveryService
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotViewModel")
    
    /// Maximum search radius in meters (20 miles)
    private let searchRadius: Double = 32186.88 // 20 miles in meters
    
    /// Number of days after which spots should be refreshed
    private let refreshThresholdDays: Int = 7
    
    /// Cache for existing spots to avoid redundant Core Data queries
    private var cachedSpots: [Spot] = []
    private var lastCacheUpdate: Date?
    
    // MARK: - Initialization
    
    /**
     * Initializes the SpotViewModel with required dependencies
     * - Parameter persistenceController: Core Data persistence controller
     * - Parameter spotDiscoveryService: Service for discovering new spots
     */
    init(persistenceController: PersistenceController = .shared,
         spotDiscoveryService: SpotDiscoveryService? = nil) {
        self.persistenceController = persistenceController
        self.spotDiscoveryService = spotDiscoveryService ?? SpotDiscoveryService()
    }
    
    // MARK: - Public Methods
    
    /**
     * Loads spots near the specified location with intelligent caching and discovery
     * - Parameter near: The center point for spot discovery, or nil to load all spots
     */
    func loadSpots(near: CLLocation?) async {
        logger.info("Loading spots near \(near?.coordinate.latitude ?? 0.0), \(near?.coordinate.longitude ?? 0.0)")
        
        // Clear any previous errors
        errorMessage = nil
        isSeeding = true
        
        do {
            let existingSpots = try await fetchExistingSpots(near: near)
            
            // Check if we need to refresh spots
            let needsRefresh = shouldRefreshSpots(existingSpots)
            
            if needsRefresh {
                logger.info("Spots need refresh or no spots found, discovering new spots")
                let discoveryLocation = near ?? CLLocation(latitude: 37.7749, longitude: -122.4194) // Fallback to SF
                await discoverNewSpots(near: discoveryLocation)
            } else {
                logger.info("Using existing spots (\(existingSpots.count) found)")
                spots = sortSpots(existingSpots, from: near)
            }
            
        } catch {
            logger.error("Failed to load spots: \(error.localizedDescription)")
            errorMessage = "Failed to load spots: \(error.localizedDescription)"
        }
        
        isSeeding = false
    }
    
    /**
     * Forces a refresh of spots by clearing cache and discovering new ones
     * - Parameter near: The center point for spot discovery, or nil to refresh all spots
     */
    func refreshSpots(near: CLLocation?) async {
        let location = near ?? CLLocation(latitude: 37.7749, longitude: -122.4194)
        logger.info("Force refreshing spots near \(location.coordinate.latitude), \(location.coordinate.longitude)")
        
        // Clear existing spots and cache
        spots = []
        cachedSpots = []
        lastCacheUpdate = nil
        errorMessage = nil
        
        await discoverNewSpots(near: location)
    }
    
    /**
     * Clears all spots from the view model
     */
    func clearSpots() {
        spots = []
        cachedSpots = []
        lastCacheUpdate = nil
        errorMessage = nil
        logger.info("Cleared all spots from view model")
    }
    
    /**
     * Clears the cache to force fresh Core Data queries
     */
    func clearCache() {
        cachedSpots = []
        lastCacheUpdate = nil
        logger.info("Cleared spot cache")
    }
    
    // MARK: - Private Methods
    
    /**
     * Fetches existing spots from Core Data with caching optimization
     * - Parameter near: The center point for the search, or nil to fetch all spots
     * - Returns: Array of existing spots
     */
    private func fetchExistingSpots(near: CLLocation?) async throws -> [Spot] {
        let context = persistenceController.container.viewContext
        let request: NSFetchRequest<Spot> = Spot.fetchRequest()
        
        if let location = near {
            // Create a bounding box for efficient querying within 20 miles
            let latRange = searchRadius / 111000.0 // Rough conversion to degrees
            let lngRange = searchRadius / (111000.0 * cos(location.coordinate.latitude * .pi / 180))
            
            let minLat = location.coordinate.latitude - latRange
            let maxLat = location.coordinate.latitude + latRange
            let minLng = location.coordinate.longitude - lngRange
            let maxLng = location.coordinate.longitude + lngRange
            
            request.predicate = NSPredicate(
                format: "latitude >= %f AND latitude <= %f AND longitude >= %f AND longitude <= %f",
                minLat, maxLat, minLng, maxLng
            )
        }
        // If near is nil, fetch all spots (no predicate)
        
        do {
            let fetchedSpots = try context.fetch(request)
            
            // If we have a location, filter by actual distance to get precise results
            let nearbySpots: [Spot]
            if let location = near {
                nearbySpots = fetchedSpots.filter { spot in
                    let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
                    return location.distance(from: spotLocation) <= searchRadius
                }
            } else {
                nearbySpots = fetchedSpots
            }
            
            // Update cache
            cachedSpots = nearbySpots
            lastCacheUpdate = Date()
            
            logger.info("Fetched \(nearbySpots.count) existing spots from Core Data within radius")
            return nearbySpots
            
        } catch {
            logger.error("Failed to fetch existing spots: \(error.localizedDescription)")
            throw error
        }
    }
    
    /**
     * Determines if spots need to be refreshed based on age and availability
     * - Parameter existingSpots: Array of existing spots
     * - Returns: True if spots need refresh, false otherwise
     */
    private func shouldRefreshSpots(_ existingSpots: [Spot]) -> Bool {
        // If no spots exist, we need to discover
        if existingSpots.isEmpty {
            logger.info("No existing spots found, need to discover")
            return true
        }
        
        // Check if any spots are older than the refresh threshold
        let refreshThreshold = Calendar.current.date(byAdding: .day, value: -refreshThresholdDays, to: Date()) ?? Date()
        
        // If *any* spot is older than the threshold, we consider it stale and need to refresh
        let needsRefresh = existingSpots.contains { spot in
            spot.lastSeeded < refreshThreshold
        }
        
        if needsRefresh {
            logger.info("At least one spot is older than \(self.refreshThresholdDays) days, need to refresh")
        } else {
            logger.info("All existing spots are fresh, no refresh needed")
        }
        
        return needsRefresh
    }
    
    /**
     * Discovers new spots using the SpotDiscoveryService
     * - Parameter near: The center point for spot discovery
     */
    private func discoverNewSpots(near: CLLocation) async {
        isSeeding = true
        errorMessage = nil
        discoveryProgress = "Starting discovery..."
        
        logger.info("Starting spot discovery process")
        
        // Start discovery and monitor progress
        let discoveryTask = Task {
            await spotDiscoveryService.discoverSpots(near: near, radius: searchRadius)
        }
        
        // Monitor discovery progress
        while !discoveryTask.isCancelled {
            discoveryProgress = spotDiscoveryService.discoveryProgress
            isSeeding = spotDiscoveryService.isDiscovering
            
            // If discovery is complete, break the loop
            if !spotDiscoveryService.isDiscovering {
                break
            }
            
            // Small delay to avoid excessive updates
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        let discoveredSpots = await discoveryTask.value
        
        // Sort spots by distance and rating
        let sortedSpots = sortSpots(discoveredSpots, from: near)
        
        spots = sortedSpots
        logger.info("Successfully loaded \(sortedSpots.count) spots")
        
        isSeeding = false
        discoveryProgress = ""
    }
    
    /**
     * Sorts spots by distance first, then by overall rating
     * - Parameter spots: Array of spots to sort
     * - Parameter userLocation: User's current location for distance calculation, or nil to sort by rating only
     * - Returns: Sorted array of spots
     */
    private func sortSpots(_ spots: [Spot], from userLocation: CLLocation?) -> [Spot] {
        guard let userLocation = userLocation else {
            // If user location is not available, sort only by overall rating
            return spots.sorted { calculateOverallRating(for: $0) > calculateOverallRating(for: $1) }
        }
        
        return spots.sorted { spot1, spot2 in
            let location1 = CLLocation(latitude: spot1.latitude, longitude: spot1.longitude)
            let location2 = CLLocation(latitude: spot2.latitude, longitude: spot2.longitude)
            
            let distance1 = userLocation.distance(from: location1)
            let distance2 = userLocation.distance(from: location2)
            
            // First sort by distance (closer spots first)
            if abs(distance1 - distance2) > 100 { // 100 meter threshold for "similar" distance
                return distance1 < distance2
            }
            
            // If distances are similar, sort by overall rating (higher rating first)
            let rating1 = calculateOverallRating(for: spot1)
            let rating2 = calculateOverallRating(for: spot2)
            
            return rating1 > rating2
        }
    }
    
    /**
     * Calculates the overall rating for a spot using the specified formula
     * - Parameter spot: The spot to calculate rating for
     * - Returns: Overall rating (0.0 to 5.0)
     */
    public func calculateOverallRating(for spot: Spot) -> Double {
        // Calculate aggregate rating (50% weight)
        let aggregateRating = calculateAggregateRating(for: spot)
        
        // Calculate user rating average (50% weight)
        let userRatingAverage = calculateUserRatingAverage(for: spot)
        
        // If no user ratings, fallback to aggregate rating
        if userRatingAverage == 0 {
            return aggregateRating
        }
        
        // Combine with 50/50 weighting
        return (aggregateRating * 0.5) + (userRatingAverage * 0.5)
    }
    
    /**
     * Calculates the aggregate rating based on WiFi, noise, and outlets
     * Formula: (wifiRating/5 + noiseInverted + outlets)/3
     * - Parameter spot: The spot to calculate rating for
     * - Returns: Aggregate rating (0.0 to 5.0)
     */
    private func calculateAggregateRating(for spot: Spot) -> Double {
        // WiFi rating (normalized to 0-5 scale)
        let wifiScore = Double(spot.wifiRating) / 5.0 * 5.0 // Scale to 0-5
        
        // Noise rating (Low=5, Medium=3, High=1, normalized to 0-5 scale)
        let noiseScore: Double
        switch spot.noiseRating.lowercased() {
        case "low":
            noiseScore = 5.0
        case "medium":
            noiseScore = 3.0
        case "high":
            noiseScore = 1.0
        default:
            noiseScore = 3.0 // Default to medium
        }
        
        // Outlets rating (Yes=5, No=1, normalized to 0-5 scale)
        let outletsScore = spot.outlets ? 5.0 : 1.0
        
        // Average of the three components, then normalize to 0-5 scale
        return (wifiScore + noiseScore + outletsScore) / 3.0
    }
    
    /**
     * Calculates the average user rating for a spot
     * - Parameter spot: The spot to calculate rating for
     * - Returns: Average user rating (0.0 to 5.0), or 0 if no ratings
     */
    private func calculateUserRatingAverage(for spot: Spot) -> Double {
        guard let userRatings = spot.userRatings, userRatings.count > 0 else {
            return 0.0
        }
        
        let totalRating = userRatings.reduce(into: 0.0) { sum, rating in
            // Cast NSSet.Element to UserRating
            guard let userRating = rating as? UserRating else { return }
            
            // Calculate individual user rating using same formula as aggregate
            let wifiScore = Double(userRating.wifi) / 5.0 * 5.0
            
            let noiseScore: Double
            switch userRating.noise.lowercased() {
            case "low":
                noiseScore = 5.0
            case "medium":
                noiseScore = 3.0
            case "high":
                noiseScore = 1.0
            default:
                noiseScore = 3.0
            }
            
            let outletsScore = userRating.plugs ? 5.0 : 1.0
            
            sum += (wifiScore + noiseScore + outletsScore) / 3.0
        }
        
        return totalRating / Double(userRatings.count)
    }
    
    // MARK: - Helper Methods
    
    /**
     * Gets the distance from user location to a specific spot
     * - Parameter spot: The spot to calculate distance to
     * - Parameter userLocation: User's current location
     * - Returns: Distance in meters
     */
    func distanceToSpot(_ spot: Spot, from userLocation: CLLocation) -> Double {
        let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
        return userLocation.distance(from: spotLocation)
    }
    
    /**
     * Formats distance for display
     * - Parameter distance: Distance in meters
     * - Returns: Formatted distance string
     */
    func formatDistance(_ distance: Double) -> String {
        if distance < 1000 {
            return String(format: "%.0f m", distance)
        } else {
            let kilometers = distance / 1000
            return String(format: "%.1f km", kilometers)
        }
    }
    
    /**
     * Gets the overall rating for a spot as a display string
     * - Parameter spot: The spot to get rating for
     * - Returns: Formatted rating string
     */
    func getOverallRatingString(for spot: Spot) -> String {
        let rating = calculateOverallRating(for: spot)
        return String(format: "%.1f", rating)
    }
    
    /**
     * Gets the number of user ratings for a spot
     * - Parameter spot: The spot to get rating count for
     * - Returns: Number of user ratings
     */
    func getUserRatingCount(for spot: Spot) -> Int {
        return spot.userRatings?.count ?? 0
    }
    
    // MARK: - Error Handling
    
    /**
     * Clears the current error message
     */
    func clearError() {
        errorMessage = nil
    }
    
    /**
     * Sets an error message with ThemeManager styling
     * - Parameter message: The error message to display
     */
    func setError(_ message: String) {
        errorMessage = message
        logger.error("SpotViewModel error: \(message)")
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension SpotViewModel {
    
    /**
     * Debug method to simulate spot loading
     * - Parameter count: Number of spots to simulate
     */
    func simulateSpots(count: Int = 5) {
        logger.debug("Simulating \(count) spots for testing")
        
        // This would create mock spots in a real implementation
        // For now, just log the simulation
        spots = []
        logger.debug("Simulated \(count) spots")
    }
    
    /**
     * Debug method to test rating calculations
     * - Parameter spot: Spot to test rating for
     */
    func debugRatingCalculation(for spot: Spot) {
        let aggregateRating = calculateAggregateRating(for: spot)
        let userRatingAverage = calculateUserRatingAverage(for: spot)
        let overallRating = calculateOverallRating(for: spot)
        
        logger.debug("""
        Rating calculation for \(spot.name):
        - Aggregate: \(String(format: "%.2f", aggregateRating))
        - User Average: \(String(format: "%.2f", userRatingAverage))
        - Overall: \(String(format: "%.2f", overallRating))
        - User Ratings Count: \(self.getUserRatingCount(for: spot))
        """)
    }
}
#endif