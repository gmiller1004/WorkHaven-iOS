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
import MapKit
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
    
    /// Current map region for MapView state management
    @Published var currentMapRegion: MKCoordinateRegion?
    
    /// Indicates if empty state should be shown (no spots found)
    @Published var showEmptyState: Bool = false
    
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
        
        // Remove duplicates before loading spots
        await spotDiscoveryService.removeDuplicateSpots()
        
        // Debug: Check total spots in database
        debugSpotCount()
        
        // Clear any previous errors and reset empty state
        errorMessage = nil
        isSeeding = true
        showEmptyState = false
        
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
                // Refresh ratings for existing spots
                await refreshRatings(for: existingSpots)
                
                // Refresh Core Data context to ensure latest data
                let viewContext = PersistenceController.shared.container.viewContext
                viewContext.refreshAllObjects()
                
                await MainActor.run {
                    self.spots = self.sortSpots(existingSpots, from: near)
                    self.isSeeding = false
                    self.showEmptyState = self.spots.isEmpty
                    
                    // Update map region to center on the location used for loading spots
                    if let location = near {
                        self.currentMapRegion = MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                        )
                        logger.info("Updated map region to center on \(location.coordinate.latitude), \(location.coordinate.longitude)")
                    }
                }
            }
            
        } catch {
            logger.error("Failed to load spots: \(error.localizedDescription)")
            await MainActor.run {
                self.errorMessage = "Failed to load spots: \(error.localizedDescription)"
                self.isSeeding = false
                self.showEmptyState = self.spots.isEmpty
            }
        }
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
     * Clears spots when location changes to prevent mixing spots from different locations
     */
    func clearSpotsForLocationChange() {
        spots = []
        cachedSpots = []
        lastCacheUpdate = nil
        logger.info("Cleared spots for location change")
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
     * Searches for spots at a specific map location with zoom-based "Search Here" functionality
     * Calculates radius from map span, queries Core Data for spots within radius, and if fewer than threshold spots found,
     * triggers spot discovery to find new spots in the area
     * - Parameter center: The center coordinate to search around
     * - Parameter span: The map's coordinate span to calculate radius from
     * - Parameter threshold: Minimum number of spots to find before triggering discovery (default: 5)
     */
    func searchHere(at center: CLLocationCoordinate2D, span: MKCoordinateSpan, threshold: Int = 5) async {
        // Calculate radius from map span (latitudeDelta * 111000 / 2 meters)
        // 111000 meters = approximate meters per degree of latitude
        let calculatedRadius = span.latitudeDelta * 111000.0 / 2.0
        
        // Apply min/max constraints: min 1 mile (1609.34m), max 20 miles (32186.88m)
        let minRadius: Double = 1609.34  // 1 mile
        let maxRadius: Double = 32186.88 // 20 miles
        let radius = max(minRadius, min(maxRadius, calculatedRadius))
        
        logger.info("Searching for spots at \(center.latitude), \(center.longitude) with calculated radius \(radius)m (span: \(span.latitudeDelta))")
        
        // Clear any previous errors
        errorMessage = nil
        isSeeding = true
        discoveryProgress = "Searching for spots..."
        
        do {
            // Convert coordinate to CLLocation for distance calculations
            let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
            
            // Query Core Data for spots within radius
            let existingSpots = try await fetchExistingSpotsWithRadius(near: centerLocation, radius: radius)
            
            logger.info("Found \(existingSpots.count) existing spots within radius")
            
            // If we have fewer than threshold spots, discover new ones
            if existingSpots.count < threshold {
                logger.info("Fewer than \(threshold) spots found, discovering new spots in area")
                discoveryProgress = "Discovering new spots..."
                
                // Discover new spots at the specified location
                let discoveredSpots = await spotDiscoveryService.discoverSpots(near: centerLocation, radius: radius)
                
                // Deduplicate discovered spots against existing ones
                let deduplicatedSpots = deduplicateSpots(discoveredSpots, against: existingSpots)
                
                logger.info("Discovered \(discoveredSpots.count) spots, \(deduplicatedSpots.count) new after deduplication")
                
                // Combine existing and newly discovered spots
                let allSpots = existingSpots + deduplicatedSpots
                
                // Sort by distance from center then by overall rating
                let sortedSpots = sortSpots(allSpots, from: centerLocation)
                
                // Refresh Core Data context to ensure latest data
                let viewContext = PersistenceController.shared.container.viewContext
                viewContext.refreshAllObjects()
                
                await MainActor.run {
                    self.spots = sortedSpots
                    self.isSeeding = false
                    self.discoveryProgress = ""
                    self.showEmptyState = self.spots.isEmpty
                    
                    // If we still have fewer than threshold spots and no new spots were added
                    if allSpots.count < threshold && deduplicatedSpots.isEmpty {
                        self.errorMessage = "No additional work spots have been found, try zooming out or changing locations."
                    }
                }
                
                // Schedule notifications for high-rated spots if nearby alerts are enabled
                await scheduleNotificationsForHighRatedSpots(sortedSpots)
                
                logger.info("Successfully discovered and loaded \(sortedSpots.count) spots")
            } else {
                logger.info("Sufficient spots found, using existing spots")
                
                // Sort existing spots by distance from center then by overall rating
                let sortedSpots = sortSpots(existingSpots, from: centerLocation)
                
                // Refresh Core Data context to ensure latest data
                let viewContext = PersistenceController.shared.container.viewContext
                viewContext.refreshAllObjects()
                
                await MainActor.run {
                    self.spots = sortedSpots
                    self.isSeeding = false
                    self.discoveryProgress = ""
                    self.showEmptyState = self.spots.isEmpty
                }
                
                logger.info("Using \(sortedSpots.count) existing spots")
            }
            
            // Update the map region to center on the search location with the provided span
            await MainActor.run {
                self.currentMapRegion = MKCoordinateRegion(
                    center: center,
                    span: span
                )
            }
            
        } catch {
            logger.error("Failed to search for spots: \(error.localizedDescription)")
            await MainActor.run {
                self.errorMessage = "Failed to search for spots: \(error.localizedDescription)"
                self.isSeeding = false
                self.discoveryProgress = ""
                self.showEmptyState = self.spots.isEmpty
            }
        }
    }
    
    /**
     * Clears the cache to force fresh Core Data queries
     */
    func clearCache() {
        cachedSpots = []
        lastCacheUpdate = nil
        logger.info("Cleared spot cache")
    }
    
    /**
     * Debug method to check total spots in database
     */
    func debugSpotCount() {
        let context = persistenceController.container.viewContext
        let request: NSFetchRequest<Spot> = Spot.fetchRequest()
        
        do {
            let totalSpots = try context.fetch(request)
            logger.info("DEBUG: Total spots in database: \(totalSpots.count)")
            
            if !totalSpots.isEmpty {
                let recentSpots = totalSpots.filter { spot in
                    spot.lastSeeded > Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                }
                logger.info("DEBUG: Spots seeded in last 24 hours: \(recentSpots.count)")
                
                // Log a few sample spots
                for (index, spot) in totalSpots.prefix(3).enumerated() {
                    logger.info("DEBUG: Spot \(index + 1): \(spot.name ?? "Unknown") - Last seeded: \(spot.lastSeeded.description)")
                }
            }
        } catch {
            logger.error("DEBUG: Failed to fetch total spot count: \(error.localizedDescription)")
        }
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
            
            // Debug: Log some details about fetched spots
            if !nearbySpots.isEmpty {
                logger.info("Sample spot: \(nearbySpots.first?.name ?? "Unknown") - Last seeded: \(nearbySpots.first?.lastSeeded.description ?? "Unknown")")
            } else {
                logger.info("No existing spots found in Core Data")
            }
            
            return nearbySpots
            
        } catch {
            logger.error("Failed to fetch existing spots: \(error.localizedDescription)")
            throw error
        }
    }
    
    /**
     * Fetches existing spots from Core Data within a specific radius
     * - Parameter near: The center point for spot querying
     * - Parameter radius: The search radius in meters
     * - Returns: Array of spots within the radius
     */
    private func fetchExistingSpotsWithRadius(near: CLLocation, radius: Double) async throws -> [Spot] {
        let context = persistenceController.container.viewContext
        let request: NSFetchRequest<Spot> = Spot.fetchRequest()
        
        // Create a bounding box for efficient querying within the specified radius
        let latRange = radius / 111000.0 // Rough conversion to degrees
        let lngRange = radius / (111000.0 * cos(near.coordinate.latitude * .pi / 180))
        
        let minLat = near.coordinate.latitude - latRange
        let maxLat = near.coordinate.latitude + latRange
        let minLng = near.coordinate.longitude - lngRange
        let maxLng = near.coordinate.longitude + lngRange
        
        request.predicate = NSPredicate(
            format: "latitude >= %f AND latitude <= %f AND longitude >= %f AND longitude <= %f",
            minLat, maxLat, minLng, maxLng
        )
        
        do {
            let fetchedSpots = try context.fetch(request)
            
            // Filter by actual distance to get precise results within the radius
            let nearbySpots = fetchedSpots.filter { spot in
                let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
                return near.distance(from: spotLocation) <= radius
            }
            
            logger.info("Fetched \(nearbySpots.count) existing spots from Core Data within \(radius)m radius")
            
            return nearbySpots
            
        } catch {
            logger.error("Failed to fetch existing spots with radius: \(error.localizedDescription)")
            throw error
        }
    }
    
    /**
     * Deduplicates discovered spots against existing spots by address and proximity
     * - Parameter discoveredSpots: Newly discovered spots to deduplicate
     * - Parameter existingSpots: Existing spots to check against
     * - Returns: Array of spots that are not duplicates
     */
    private func deduplicateSpots(_ discoveredSpots: [Spot], against existingSpots: [Spot]) -> [Spot] {
        var uniqueSpots: [Spot] = []
        
        for discoveredSpot in discoveredSpots {
            var isDuplicate = false
            
            for existingSpot in existingSpots {
                // Check by address similarity
                let discoveredAddress = (discoveredSpot.address ?? "").lowercased()
                let existingAddress = (existingSpot.address ?? "").lowercased()
                
                if discoveredAddress == existingAddress {
                    isDuplicate = true
                    break
                }
                
                // Check by proximity (< 100m)
                let discoveredLocation = CLLocation(latitude: discoveredSpot.latitude, longitude: discoveredSpot.longitude)
                let existingLocation = CLLocation(latitude: existingSpot.latitude, longitude: existingSpot.longitude)
                
                if discoveredLocation.distance(from: existingLocation) < 100 {
                    isDuplicate = true
                    break
                }
            }
            
            if !isDuplicate {
                uniqueSpots.append(discoveredSpot)
            }
        }
        
        logger.info("Deduplicated \(discoveredSpots.count) spots, \(uniqueSpots.count) unique spots remain")
        return uniqueSpots
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
        
        // Start monitoring discovery progress
        let progressTask = Task { @MainActor in
            while spotDiscoveryService.isDiscovering {
                discoveryProgress = spotDiscoveryService.discoveryProgress
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            }
        }
        
        // Start discovery
        let discoveredSpots = await spotDiscoveryService.discoverSpots(near: near, radius: searchRadius)
        
        // Cancel progress monitoring
        progressTask.cancel()
        
        // Sort spots by distance and rating
        let sortedSpots = sortSpots(discoveredSpots, from: near)
        
        // Refresh Core Data context to ensure latest data
        let viewContext = PersistenceController.shared.container.viewContext
        viewContext.refreshAllObjects()
        
        // Update spots and ensure UI refresh
        await MainActor.run {
            self.spots = sortedSpots
            self.isSeeding = false
            self.discoveryProgress = ""
            self.showEmptyState = self.spots.isEmpty
            
            // Update map region to center on the discovery location
            self.currentMapRegion = MKCoordinateRegion(
                center: near.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            logger.info("Updated map region to center on discovery location \(near.coordinate.latitude), \(near.coordinate.longitude)")
        }
        
        // Schedule notifications for high-rated spots if nearby alerts are enabled
        await scheduleNotificationsForHighRatedSpots(sortedSpots)
        
        logger.info("Successfully loaded \(sortedSpots.count) spots")
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
     * Formula: min(5, 50% aggregate rating + 50% user rating average)
     * - Parameter spot: The spot to calculate rating for
     * - Returns: Overall rating (0.0 to 5.0), capped at 5 stars
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
        
        // Combine with 50/50 weighting and cap at 5 stars
        let combinedRating = (aggregateRating * 0.5) + (userRatingAverage * 0.5)
        return min(5.0, combinedRating)
    }
    
    /**
     * Calculates the aggregate rating based on WiFi, noise, and outlets
     * Formula: min(5, (wifiNormalized + noiseInverted + outlets) / 3), rounded to 0.5
     * - Parameter spot: The spot to calculate rating for
     * - Returns: Aggregate rating (0.0 to 5.0), capped at 5 stars, rounded to 0.5
     */
    private func calculateAggregateRating(for spot: Spot) -> Double {
        // WiFi rating (normalized to 0-5 scale)
        let wifiNormalized = Double(spot.wifiRating)
        
        // Noise rating (Low=5, Medium=3, High=1)
        let noiseInverted: Double
        switch spot.noiseRating.lowercased() {
        case "low":
            noiseInverted = 5.0
        case "medium":
            noiseInverted = 3.0
        case "high":
            noiseInverted = 1.0
        default:
            noiseInverted = 3.0 // Default to medium
        }
        
        // Outlets rating (Yes=5, No=1)
        let outlets = spot.outlets ? 5.0 : 1.0
        
        // Calculate average and cap at 5
        let average = (wifiNormalized + noiseInverted + outlets) / 3.0
        let capped = min(5.0, average)
        
        // Round to nearest 0.5
        return round(capped * 2.0) / 2.0
    }
    
    /**
     * Calculates the average user rating for a spot
     * - Parameter spot: The spot to calculate rating for
     * - Returns: Average user rating (0.0 to 5.0), capped at 5 stars, rounded to 0.5, or 0 if no ratings
     */
    private func calculateUserRatingAverage(for spot: Spot) -> Double {
        guard let userRatings = spot.userRatings, userRatings.count > 0 else {
            return 0.0
        }
        
        let totalRating = userRatings.reduce(into: 0.0) { sum, rating in
            // Cast NSSet.Element to UserRating
            guard let userRating = rating as? UserRating else { return }
            
            // Calculate individual user rating using same formula as aggregate
            let wifiNormalized = Double(userRating.wifi)
            
            let noiseInverted: Double
            switch userRating.noise.lowercased() {
            case "low":
                noiseInverted = 5.0
            case "medium":
                noiseInverted = 3.0
            case "high":
                noiseInverted = 1.0
            default:
                noiseInverted = 3.0
            }
            
            let outlets = userRating.plugs ? 5.0 : 1.0
            
            // Calculate average and cap at 5
            let average = (wifiNormalized + noiseInverted + outlets) / 3.0
            let capped = min(5.0, average)
            
            sum += capped
        }
        
        let average = totalRating / Double(userRatings.count)
        let capped = min(5.0, average)
        
        // Round to nearest 0.5
        return round(capped * 2.0) / 2.0
    }
    
    /**
     * Refreshes ratings for a collection of spots by recalculating overall ratings
     * Since overallRating is calculated dynamically, this method ensures the calculation
     * is performed with the latest formula and logs the results for debugging
     * - Parameter spots: Array of spots to refresh ratings for
     */
    private func refreshRatings(for spots: [Spot]) async {
        logger.info("Refreshing ratings for \(spots.count) spots")
        
        for spot in spots {
            // Recalculate the overall rating using the updated formula
            let newOverallRating = calculateOverallRating(for: spot)
            let aggregateRating = calculateAggregateRating(for: spot)
            let userRatingAverage = calculateUserRatingAverage(for: spot)
            
            logger.debug("Rating for \(spot.name): Overall=\(String(format: "%.2f", newOverallRating)), Aggregate=\(String(format: "%.2f", aggregateRating)), UserAvg=\(String(format: "%.2f", userRatingAverage))")
        }
        
        logger.info("Rating refresh completed for \(spots.count) spots")
    }
    
    /**
     * Schedules nearby alerts for high-rated spots if nearby alerts are enabled
     * - Parameter spots: Array of spots to check for notification scheduling
     */
    private func scheduleNotificationsForHighRatedSpots(_ spots: [Spot]) async {
        // Check if nearby alerts are enabled
        let nearbyAlertsEnabled = UserDefaults.standard.bool(forKey: "NearbyAlertsEnabled")
        
        guard nearbyAlertsEnabled else {
            logger.debug("Nearby alerts are disabled, skipping notification scheduling")
            return
        }
        
        logger.info("Scheduling notifications for high-rated spots (threshold: >4.0)")
        
        var notificationsScheduled = 0
        
        for spot in spots {
            let overallRating = calculateOverallRating(for: spot)
            
            // Only schedule notifications for spots with rating > 4.0
            if overallRating > 4.0 {
                NotificationManager.shared.scheduleNearbyAlert(for: spot, radius: 1609.34, condition: 4.0)
                notificationsScheduled += 1
                logger.info("Scheduled notification for high-rated spot: \(spot.name) (rating: \(String(format: "%.1f", overallRating)))")
            }
        }
        
        logger.info("Scheduled \(notificationsScheduled) notifications for high-rated spots")
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
     * Formats distance for display with unit conversion based on user preference
     * - Parameter spot: The spot to calculate distance to
     * - Parameter userLocation: User's current location (optional)
     * - Returns: Formatted distance string with appropriate units
     */
    func formattedDistance(spot: Spot, from userLocation: CLLocation?) -> String {
        let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
        let locationToUse = userLocation ?? fallbackLocation
        
        let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
        let distanceInMeters = locationToUse.distance(from: spotLocation)
        
        return formatDistance(distanceInMeters)
    }
    
    /**
     * Formats distance for display with unit conversion based on user preference
     * - Parameter distance: Distance in meters
     * - Returns: Formatted distance string with appropriate units
     */
    func formatDistance(_ distance: Double) -> String {
        let usesImperialUnits = UserDefaults.standard.bool(forKey: "usesImperialUnits")
        
        if usesImperialUnits {
            // Convert to miles
            let miles = distance / 1609.34
            return String(format: "%.1f mi", miles)
        } else {
            // Convert to kilometers
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
     * Refreshes annotations by updating the current map region
     * Called when map region changes to prevent annotation flickering
     * - Parameter mapRegion: The new map region to set
     */
    func refreshAnnotations(mapRegion: MKCoordinateRegion) {
        currentMapRegion = mapRegion
        logger.debug("Refreshing annotations for map region: \(mapRegion.center.latitude), \(mapRegion.center.longitude)")
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
#endif// Test comment
