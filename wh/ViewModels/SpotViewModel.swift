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
import OSLog

/**
 * SpotViewModel manages spot data, seeding, and display logic for WorkHaven.
 * 
 * This view model provides:
 * - Spot data management with Core Data integration
 * - Automatic spot discovery and seeding based on location and time
 * - Intelligent sorting by distance and overall rating
 * - Error handling with user-friendly messages
 * - Theme integration for consistent UI styling
 * 
 * Usage:
 * - Initialize with @StateObject in SwiftUI views
 * - Call loadSpots(near:) to load and seed spots for a location
 * - Monitor @Published properties for UI updates
 * - Handle errors via errorMessage property
 */
@MainActor
class SpotViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    /// Array of spots currently loaded and displayed
    @Published var spots: [Spot] = []
    
    /// Whether spot discovery/seeding is currently in progress
    @Published var isSeeding: Bool = false
    
    /// Error message to display to user, nil if no error
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    
    private let persistenceController = PersistenceController.shared
    private let spotDiscoveryService = SpotDiscoveryService()
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotViewModel")
    
    /// Maximum distance for spot queries (20 miles in meters)
    private let maxDistance: Double = 32186.88 // 20 miles in meters
    
    /// Maximum age for seeded spots before re-seeding (7 days)
    private let maxSeededAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds
    
    // MARK: - Public Methods
    
    /**
     * Loads spots near the specified location
     * 
     * - Parameter location: The location to search around
     * 
     * This method:
     * 1. Queries Core Data for existing spots within 20 miles
     * 2. Checks if spots need re-seeding (none found or lastSeeded > 7 days)
     * 3. Calls SpotDiscoveryService if re-seeding is needed
     * 4. Sorts spots by distance and overall rating
     * 5. Updates the spots array
     */
    func loadSpots(near location: CLLocation) async {
        logger.info("Loading spots near location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        
        // Clear any previous errors
        errorMessage = nil
        
        do {
            // First, try to load existing spots from Core Data
            let existingSpots = try await querySpots(near: location)
            
            // Check if we need to seed new spots
            let needsSeeding = shouldSeedSpots(existingSpots: existingSpots)
            
            if needsSeeding {
                logger.info("Seeding new spots - existing: \(existingSpots.count), needs seeding: \(needsSeeding)")
                await seedSpots(near: location)
            } else {
                logger.info("Using existing spots: \(existingSpots.count)")
                spots = sortSpots(existingSpots, from: location)
            }
            
        } catch {
            logger.error("Failed to load spots: \(error.localizedDescription)")
            errorMessage = "Failed to load spots: \(error.localizedDescription)"
            spots = []
        }
    }
    
    /**
     * Refreshes spots for the current location
     * 
     * - Parameter location: The location to refresh spots for
     */
    func refreshSpots(near location: CLLocation) async {
        logger.info("Refreshing spots near location")
        await loadSpots(near: location)
    }
    
    /**
     * Clears all spots and error messages
     */
    func clearSpots() {
        logger.info("Clearing all spots")
        spots = []
        errorMessage = nil
    }
    
    /**
     * Gets the overall rating for a spot
     * 
     * - Parameter spot: The spot to calculate rating for
     * - Returns: Overall rating from 0.0 to 5.0
     */
    func getOverallRating(for spot: Spot) -> Double {
        return calculateOverallRating(for: spot)
    }
    
    // MARK: - Private Methods
    
    /**
     * Queries Core Data for spots within the specified distance
     */
    private func querySpots(near location: CLLocation) async throws -> [Spot] {
        return try await withCheckedThrowingContinuation { continuation in
            let context = persistenceController.container.viewContext
            
            context.perform {
                do {
                    let request: NSFetchRequest<Spot> = Spot.fetchRequest()
                    
                    // Create a predicate to filter spots within the maximum distance
                    // We'll fetch all spots and filter by distance in memory for accuracy
                    let spots = try context.fetch(request)
                    
                    // Filter spots within the maximum distance
                    let nearbySpots = spots.filter { spot in
                        let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
                        return location.distance(from: spotLocation) <= self.maxDistance
                    }
                    
                    continuation.resume(returning: nearbySpots)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     * Determines if spots need to be seeded based on existing data
     */
    private func shouldSeedSpots(existingSpots: [Spot]) -> Bool {
        // Seed if no spots found
        if existingSpots.isEmpty {
            logger.info("No existing spots found, seeding required")
            return true
        }
        
        // Check if any spot was seeded recently (within 7 days)
        let now = Date()
        let hasRecentSpots = existingSpots.contains { spot in
            let timeSinceSeeded = now.timeIntervalSince(spot.lastSeeded)
            return timeSinceSeeded <= maxSeededAge
        }
        
        if !hasRecentSpots {
            logger.info("No recently seeded spots found, re-seeding required")
            return true
        }
        
        logger.info("Recent spots found, no seeding required")
        return false
    }
    
    /**
     * Seeds new spots using SpotDiscoveryService
     */
    private func seedSpots(near location: CLLocation) async {
        isSeeding = true
        errorMessage = nil
        
        logger.info("Starting spot discovery and seeding")
        let discoveredSpots = await spotDiscoveryService.discoverSpots(near: location)
        
        if discoveredSpots.isEmpty {
            logger.warning("No spots discovered, trying existing spots as fallback")
            errorMessage = "No new spots found, showing existing spots"
            
            // Try to load existing spots as fallback
            do {
                let existingSpots = try await querySpots(near: location)
                spots = sortSpots(existingSpots, from: location)
                logger.info("Loaded \(existingSpots.count) existing spots as fallback")
            } catch {
                logger.error("Failed to load existing spots as fallback: \(error.localizedDescription)")
                errorMessage = "Failed to load spots: \(error.localizedDescription)"
                spots = []
            }
        } else {
            logger.info("Successfully discovered \(discoveredSpots.count) spots")
            spots = sortSpots(discoveredSpots, from: location)
        }
        
        isSeeding = false
    }
    
    /**
     * Sorts spots by distance and overall rating
     */
    private func sortSpots(_ spots: [Spot], from location: CLLocation) -> [Spot] {
        return spots.sorted { spot1, spot2 in
            let location1 = CLLocation(latitude: spot1.latitude, longitude: spot1.longitude)
            let location2 = CLLocation(latitude: spot2.latitude, longitude: spot2.longitude)
            
            let distance1 = location.distance(from: location1)
            let distance2 = location.distance(from: location2)
            
            let rating1 = calculateOverallRating(for: spot1)
            let rating2 = calculateOverallRating(for: spot2)
            
            // Primary sort: distance (closer is better)
            if abs(distance1 - distance2) > 100 { // 100 meter threshold
                return distance1 < distance2
            }
            
            // Secondary sort: overall rating (higher is better)
            return rating1 > rating2
        }
    }
    
    /**
     * Calculates the overall rating for a spot
     * 
     * Formula: 50% aggregate rating + 50% user rating average
     * - Aggregate: (wifiRating/5 + noiseInverted + outlets) / 3
     * - Noise: Low=5, Medium=3, High=1
     * - Outlets: Yes=5, No=1
     * - User ratings: Average of all user ratings for the spot
     */
    private func calculateOverallRating(for spot: Spot) -> Double {
        // Calculate aggregate rating (50% weight)
        let wifiScore = Double(spot.wifiRating) / 5.0
        
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
        let noiseInverted = noiseScore / 5.0
        
        let outletsScore = spot.outlets ? 5.0 : 1.0
        let outletsNormalized = outletsScore / 5.0
        
        let aggregateRating = (wifiScore + noiseInverted + outletsNormalized) / 3.0
        
        // Calculate user rating average (50% weight)
        let userRatingAverage = calculateUserRatingAverage(for: spot)
        
        // Combine with 50/50 weighting
        let overallRating = (aggregateRating * 0.5) + (userRatingAverage * 0.5)
        
        // Ensure rating is between 0.0 and 5.0
        return max(0.0, min(5.0, overallRating))
    }
    
    /**
     * Calculates the average user rating for a spot
     */
    private func calculateUserRatingAverage(for spot: Spot) -> Double {
        guard let userRatings = spot.userRatings as? Set<UserRating>,
              !userRatings.isEmpty else {
            // No user ratings, return neutral score
            return 2.5
        }
        
        let totalRating = userRatings.reduce(0.0) { total, rating in
            let wifiScore = Double(rating.wifi) / 5.0
            
            let noiseScore: Double
            switch rating.noise.lowercased() {
            case "low":
                noiseScore = 5.0
            case "medium":
                noiseScore = 3.0
            case "high":
                noiseScore = 1.0
            default:
                noiseScore = 3.0
            }
            let noiseInverted = noiseScore / 5.0
            
            let plugsScore = rating.plugs ? 5.0 : 1.0
            let plugsNormalized = plugsScore / 5.0
            
            let userRating = (wifiScore + noiseInverted + plugsNormalized) / 3.0
            return total + userRating
        }
        
        return totalRating / Double(userRatings.count)
    }
}

// MARK: - Convenience Extensions

extension SpotViewModel {
    
    /**
     * Gets spots within a specific radius
     * 
     * - Parameter radius: Radius in meters
     * - Parameter from: Reference location
     * - Returns: Array of spots within the radius
     */
    func getSpotsWithin(radius: Double, from location: CLLocation) -> [Spot] {
        return spots.filter { spot in
            let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
            return location.distance(from: spotLocation) <= radius
        }
    }
    
    /**
     * Gets spots with a minimum rating
     * 
     * - Parameter minRating: Minimum rating (0.0 to 5.0)
     * - Returns: Array of spots meeting the minimum rating
     */
    func getSpotsWithRating(atLeast minRating: Double) -> [Spot] {
        return spots.filter { spot in
            calculateOverallRating(for: spot) >= minRating
        }
    }
    
    /**
     * Gets the closest spot to a location
     * 
     * - Parameter location: Reference location
     * - Returns: Closest spot, nil if no spots available
     */
    func getClosestSpot(to location: CLLocation) -> Spot? {
        return spots.min { spot1, spot2 in
            let location1 = CLLocation(latitude: spot1.latitude, longitude: spot1.longitude)
            let location2 = CLLocation(latitude: spot2.latitude, longitude: spot2.longitude)
            return location.distance(from: location1) < location.distance(from: location2)
        }
    }
    
    /**
     * Gets spots by category (based on name/address patterns)
     * 
     * - Parameter category: Category to filter by
     * - Returns: Array of spots matching the category
     */
    func getSpotsByCategory(_ category: String) -> [Spot] {
        let categoryLower = category.lowercased()
        return spots.filter { spot in
            spot.name.lowercased().contains(categoryLower) ||
            spot.address.lowercased().contains(categoryLower)
        }
    }
}

// MARK: - Theme Integration

extension SpotViewModel {
    
    /**
     * Gets theme colors for UI styling
     */
    var themeColors: (mocha: String, latte: String) {
        return (mocha: "#8B5E3C", latte: "#FFF8E7")
    }
    
    /**
     * Creates a styled error message for display
     */
    func getStyledErrorMessage() -> String? {
        guard let error = errorMessage else { return nil }
        return "⚠️ \(error)"
    }
}
