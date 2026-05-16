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
    
    /// Selected categories for filtering spots (all default selected)
    @Published var selectedCategories: Set<String> = ["coffee", "park", "library", "coworking"]
    
    /// Bumped when a spot's community data changes so list rows refresh.
    @Published private(set) var spotsListRevision = 0
    
    /// Core Data view context for UI operations
    var viewContext: NSManagedObjectContext {
        return persistenceController.container.viewContext
    }
    
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
    
    /// Last location used for a successful spot load (ignores minor GPS drift).
    private var lastLoadedLocation: CLLocation?
    
    /// Minimum movement before clearing spots and reloading (meters).
    private let significantLocationChangeMeters: CLLocationDistance = 500
    
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
    
    /// Forces list rows to re-read Core Data after a spot is updated in place.
    func notifyCommunitySpotUpdated() {
        persistenceController.container.viewContext.refreshAllObjects()
        spotsListRevision += 1
    }
    
    // MARK: - Public Methods
    
    /**
     * Loads spots near the specified location with intelligent caching and discovery
     * - Parameter near: The center point for spot discovery, or nil to load all spots
     */
    func loadSpots(near: CLLocation?) async {
        if isSeeding {
            logger.info("Spot load already in progress, skipping duplicate request")
            return
        }
        
        // Claim the load immediately so concurrent callers don't duplicate Supabase/discovery work.
        isSeeding = true
        errorMessage = nil
        showEmptyState = false
        
        logger.info("Loading spots near \(near?.coordinate.latitude ?? 0.0), \(near?.coordinate.longitude ?? 0.0)")
        
        // Remove duplicates before loading spots
        await spotDiscoveryService.removeDuplicateSpots()
        
        // Debug: Check total spots in database
        debugSpotCount()
        
        do {
            var existingSpots = try await fetchExistingSpots(near: near)
            var remoteCommunityCount = 0
            
            if AppConfig.isSupabaseConfigured, let location = near {
                let communityResult = await loadCommunitySpotsIfAvailable(near: location, existing: existingSpots)
                existingSpots = communityResult.spots
                remoteCommunityCount = communityResult.remoteCount
                
                if remoteCommunityCount > 0 {
                    await spotDiscoveryService.removeDuplicateSpots()
                    existingSpots = try await fetchExistingSpots(near: location)
                }
            }
            
            // Check if we need to refresh spots
            var needsRefresh = shouldRefreshSpots(existingSpots)
            if AppConfig.isSupabaseConfigured && remoteCommunityCount == 0 {
                logger.info("Community catalog is empty for this area — seeding Supabase via discovery")
                needsRefresh = true
            }
            
            if needsRefresh {
                logger.info("Spots need refresh or no spots found, discovering new spots")
                let discoveryLocation = near ?? CLLocation(latitude: 37.7749, longitude: -122.4194) // Fallback to SF
                await discoverNewSpots(near: discoveryLocation)
            } else {
                logger.info("Using existing spots (\(existingSpots.count) found)")
                existingSpots = uniqueSpotsForDisplay(existingSpots)
                // Refresh ratings for existing spots
                await refreshRatings(for: existingSpots)
                
                // Refresh Core Data context to ensure latest data
                let viewContext = PersistenceController.shared.container.viewContext
                viewContext.refreshAllObjects()
                
                await finishLoadingSpots(existingSpots, near: near)
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
     * Handles location updates; only reloads when the user has moved a meaningful distance.
     */
    func handleLocationUpdate(_ location: CLLocation) async {
        if let lastLoadedLocation {
            let movedMeters = location.distance(from: lastLoadedLocation)
            if movedMeters < significantLocationChangeMeters {
                logger.info(
                    "Location change insignificant (\(Int(movedMeters))m), keeping \(self.spots.count) loaded spots"
                )
                return
            }
            logger.info("Significant location change (\(Int(movedMeters))m), reloading spots")
        } else if isSeeding {
            return
        } else if !spots.isEmpty {
            noteSuccessfulLoad(at: location)
            return
        }
        
        if !spots.isEmpty {
            clearSpotsForLocationChange()
        }
        await loadSpots(near: location)
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
    
    private func noteSuccessfulLoad(at location: CLLocation?) {
        lastLoadedLocation = location
    }
    
    /**
     * Applies loaded spots to the UI and records the load location.
     */
    private func finishLoadingSpots(_ existingSpots: [Spot], near: CLLocation?) async {
        let displaySpots = uniqueSpotsForDisplay(existingSpots)
        
        await MainActor.run {
            let filteredSpots = filterSpotsByCategory(displaySpots)
            self.spots = self.sortSpots(filteredSpots, from: near)
            self.isSeeding = false
            self.showEmptyState = self.spots.isEmpty
            
            if let location = near {
                self.currentMapRegion = MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
                logger.info("Updated map region to center on \(location.coordinate.latitude), \(location.coordinate.longitude)")
            }
        }
        
        noteSuccessfulLoad(at: near)
        await scheduleNotificationsForHighRatedSpots(spots)
        logger.info("Successfully loaded \(self.spots.count) spots")
    }
    
    /// Collapses duplicate Core Data rows (same community id) before display or rating refresh.
    private func uniqueSpotsForDisplay(_ spots: [Spot]) -> [Spot] {
        var bySupabaseId: [String: Spot] = [:]
        var withoutCommunityId: [Spot] = []
        
        for spot in spots {
            guard let id = spot.supabaseId, !id.isEmpty else {
                withoutCommunityId.append(spot)
                continue
            }
            if let existing = bySupabaseId[id] {
                if spot.lastSeeded > existing.lastSeeded {
                    bySupabaseId[id] = spot
                }
            } else {
                bySupabaseId[id] = spot
            }
        }
        
        return Array(bySupabaseId.values) + withoutCommunityId
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
                
                // Filter spots by selected categories and sort by distance from center then by overall rating
                let filteredSpots = filterSpotsByCategory(allSpots)
                let sortedSpots = sortSpots(filteredSpots, from: centerLocation)
                
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
                
                // Filter spots by selected categories and sort existing spots by distance from center then by overall rating
                let filteredSpots = filterSpotsByCategory(existingSpots)
                let sortedSpots = sortSpots(filteredSpots, from: centerLocation)
                
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
                    logger.info("DEBUG: Spot \(index + 1): \(spot.name) - Last seeded: \(spot.lastSeeded.description)")
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
            
            normalizeOutletStates(for: nearbySpots)
            
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
                let discoveredAddress = discoveredSpot.address.lowercased()
                let existingAddress = existingSpot.address.lowercased()
                
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
     * Loads canonical community spots from Supabase into Core Data when available.
     */
    private struct CommunityLoadResult {
        let spots: [Spot]
        let remoteCount: Int
    }
    
    private func normalizeOutletStates(for spots: [Spot]) {
        let context = persistenceController.container.viewContext
        for spot in spots {
            spot.normalizeOutletUnknownState()
        }
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            logger.warning("Failed to save outlet normalization: \(error.localizedDescription)")
        }
    }
    
    private func loadCommunitySpotsIfAvailable(near location: CLLocation, existing: [Spot]) async -> CommunityLoadResult {
        do {
            let remoteSpots = try await SupabaseCommunityService.shared.fetchNearbySpots(
                near: location,
                radiusMeters: searchRadius
            )
            
            guard !remoteSpots.isEmpty else {
                return CommunityLoadResult(spots: existing, remoteCount: 0)
            }
            
            let synced = try SupabaseCommunityService.shared.syncToCoreData(remoteSpots: remoteSpots)
            logger.info("Synced \(synced.count) community spots from Supabase")
            return CommunityLoadResult(spots: synced, remoteCount: remoteSpots.count)
        } catch {
            logger.warning("Supabase community fetch failed, using local cache: \(error.localizedDescription)")
            return CommunityLoadResult(spots: existing, remoteCount: -1)
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
        
        // Filter spots by selected categories and sort by distance and rating
        let filteredSpots = filterSpotsByCategory(discoveredSpots)
        let sortedSpots = sortSpots(filteredSpots, from: near)
        
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
        
        noteSuccessfulLoad(at: near)
        
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
            return spots.sorted {
                (communityStarRating(for: $0) ?? -1) > (communityStarRating(for: $1) ?? -1)
            }
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
            let rating1 = communityStarRating(for: spot1) ?? -1
            let rating2 = communityStarRating(for: spot2) ?? -1
            
            return rating1 > rating2
        }
    }
    
    /// Community star average from user reviews only; nil when no rated reviews exist.
    public func communityStarRating(for spot: Spot) -> Double? {
        SpotRatingCalculator.communityStarRating(for: spot)
    }
    
    /// Legacy alias used by notifications and share flows.
    public func calculateOverallRating(for spot: Spot) -> Double {
        communityStarRating(for: spot) ?? 0
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
            let stars = communityStarRating(for: spot)
            logger.debug(
                "Rating for \(spot.name): community stars=\(stars.map { String(format: "%.2f", $0) } ?? "none")"
            )
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
            guard let overallRating = communityStarRating(for: spot) else { continue }
            
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
    
    /**
     * Filters spots by selected categories
     * - Parameter spots: Array of spots to filter
     * - Returns: Filtered array of spots matching selected categories
     */
    func filterSpotsByCategory(_ spots: [Spot]) -> [Spot] {
        return spots.filter { spot in
            // Include spots with type in selectedCategories or "unknown" if not set
            let spotType = spot.type.isEmpty ? "unknown" : spot.type
            return selectedCategories.contains(spotType)
        }
    }
    
    /**
     * Updates selected categories and refilters spots
     * - Parameter newCategories: Set of category strings to filter by
     */
    func updateCategories(_ newCategories: Set<String>) async {
        selectedCategories = newCategories
        logger.info("Updated selected categories: \(self.selectedCategories)")
        
        // Refetch all spots from Core Data and then filter by new categories
        await refilterSpotsWithCurrentCategories()
    }
    
    /**
     * Refetches all spots from Core Data and applies current category filter
     */
    private func refilterSpotsWithCurrentCategories() async {
        do {
            let viewContext = PersistenceController.shared.container.viewContext
            let request: NSFetchRequest<Spot> = Spot.fetchRequest()
            let allSpots = try viewContext.fetch(request)
            
            await MainActor.run {
                // Filter spots by selected categories
                let filteredSpots = filterSpotsByCategory(allSpots)
                self.spots = self.sortSpots(filteredSpots, from: nil)
                self.showEmptyState = self.spots.isEmpty
                logger.info("Refiltered spots: \(self.spots.count) spots after category filter")
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to refilter spots: \(error.localizedDescription)"
                logger.error("Failed to refilter spots: \(error)")
            }
        }
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
        let stars = communityStarRating(for: spot)
        logger.debug("""
        Rating calculation for \(spot.name):
        - Community stars: \(stars.map { String(format: "%.2f", $0) } ?? "none")
        - Rated reviews: \(spot.communityRatingCount)
        - WiFi known: \(spot.wifiKnown), noise known: \(spot.noiseKnown)
        """)
    }
    
}
#endif// Test comment
