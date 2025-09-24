//
//  SpotDiscoveryService.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import CoreLocation
import MapKit
import CoreData
import OSLog
import SwiftUI

/**
 * SpotDiscoveryService discovers and enriches nearby work spots using MKLocalSearch
 * and the xAI Grok API. Searches for coffee shops, libraries, parks, and co-working
 * spaces, then enriches them with AI-generated ratings and tips. Includes intelligent
 * deduplication and spot updating for stale data.
 */
@MainActor
class SpotDiscoveryService: ObservableObject {
    
    // MARK: - Properties
    
    private let persistenceController = PersistenceController.shared
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotDiscovery")
    
    /// Categories to search for work-friendly locations
    private let searchCategories = [
        "coffee shop",
        "library", 
        "park",
        "co-working space"
    ]
    
    /// Default radius for discovery (20 miles in meters)
    private let defaultRadius: Double = 32186.88 // 20 miles in meters
    
    /// Maximum number of results per category
    private let maxResultsPerCategory = 15
    
    /// Minimum number of results per category
    private let minResultsPerCategory = 10
    
    /// Cache for existing spots to avoid redundant Core Data queries
    private var existingSpotsCache: [Spot] = []
    
    // MARK: - Published Properties
    
    @Published var isDiscovering = false
    @Published var discoveryProgress: String = ""
    @Published var discoveredSpotsCount = 0
    @Published var errorMessage: String?
    
    // MARK: - Main Discovery Function
    
    /**
     * Discovers work spots near a given location with enhanced deduplication and updating
     * - Parameter location: The center point for discovery
     * - Parameter radius: Search radius in meters (default: 20 miles)
     * - Returns: Array of discovered Spot entities
     */
    func discoverSpots(near location: CLLocation, radius: Double? = nil) async -> [Spot] {
        let searchRadius = radius ?? defaultRadius
        
        logger.info("Starting spot discovery near \(location.coordinate.latitude), \(location.coordinate.longitude) with radius \(searchRadius)m")
        await updateDiscoveryState(isDiscovering: true, progress: "Checking existing spots...")
        
        do {
            // Cache existing spots to avoid redundant queries
            existingSpotsCache = await checkExistingSpots(near: location, radius: searchRadius)
            
            if !existingSpotsCache.isEmpty {
                logger.info("Found \(self.existingSpotsCache.count) existing spots within radius")
                await updateDiscoveryState(progress: "Checking for new and stale spots...")
            }
            
            // Proceed with discovery
            let discoveredSpots = try await performSpotDiscovery(near: location, radius: searchRadius)
            
            await updateDiscoveryState(isDiscovering: false, progress: "Discovery complete")
            logger.info("Successfully discovered \(discoveredSpots.count) total spots")
            
            // Log CloudKit sync event
            logger.info("CloudKit sync triggered for \(discoveredSpots.count) spots")
            
            return discoveredSpots
            
        } catch {
            logger.error("Spot discovery failed: \(error.localizedDescription)")
            await updateDiscoveryState(isDiscovering: false, progress: "Discovery failed")
            errorMessage = "Discovery failed: \(error.localizedDescription)"
            return []
        }
    }
    
    // MARK: - Core Data Check
    
    /**
     * Checks for existing spots within the specified radius with optimized Core Data querying
     * Uses bounding box for efficient lat/long queries within 20 miles
     * Returns all spots regardless of lastSeeded date for comprehensive checking
     */
    private func checkExistingSpots(near location: CLLocation, radius: Double) async -> [Spot] {
        let context = persistenceController.container.viewContext
        let request: NSFetchRequest<Spot> = Spot.fetchRequest()
        
        // Create a bounding box for efficient querying (20 miles)
        let latRange = radius / 111000.0 // Rough conversion to degrees
        let lngRange = radius / (111000.0 * cos(location.coordinate.latitude * .pi / 180))
        
        let minLat = location.coordinate.latitude - latRange
        let maxLat = location.coordinate.latitude + latRange
        let minLng = location.coordinate.longitude - lngRange
        let maxLng = location.coordinate.longitude + lngRange
        
        request.predicate = NSPredicate(
            format: "latitude >= %f AND latitude <= %f AND longitude >= %f AND longitude <= %f",
            minLat, maxLat, minLng, maxLng
        )
        
        do {
            let spots = try context.fetch(request)
            // Filter by actual distance to get precise results
            let nearbySpots = spots.filter { spot in
                let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
                return location.distance(from: spotLocation) <= radius
            }
            logger.info("Found \(nearbySpots.count) existing spots within radius")
            return nearbySpots
        } catch {
            logger.error("Failed to fetch existing spots: \(error.localizedDescription)")
            errorMessage = "Failed to check existing spots: \(error.localizedDescription)"
            return []
        }
    }
    
    /**
     * Checks if a spot matches existing spots by name+address or proximity
     * - Parameter mapItem: The MKMapItem to check for matches
     * - Returns: Matching existing spot if found, nil otherwise
     */
    private func findMatchingSpot(mapItem: MKMapItem) -> Spot? {
        let name = mapItem.name ?? "Unknown Location"
        let address = mapItem.placemark.title ?? "Unknown Address"
        let coordinate = mapItem.placemark.coordinate
        
        // Create composite key for exact matching
        let compositeKey = "\(name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        
        for existingSpot in existingSpotsCache {
            // Check composite key match
            let existingCompositeKey = "\(existingSpot.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(existingSpot.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            
            if compositeKey == existingCompositeKey {
                logger.info("Found exact match: \(name) at \(address)")
                return existingSpot
            }
            
            // Check proximity match (within 100 meters)
            let existingLocation = CLLocation(latitude: existingSpot.latitude, longitude: existingSpot.longitude)
            let newLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = existingLocation.distance(from: newLocation)
            
            if distance < 100.0 {
                logger.info("Found proximity match: \(name) at \(address) (distance: \(distance)m)")
                return existingSpot
            }
        }
        
        return nil
    }
    
    // MARK: - MKLocalSearch Implementation
    
    /**
     * Performs the actual spot discovery using MKLocalSearch
     * Intelligently handles new spots, stale spots, and duplicates
     */
    private func performSpotDiscovery(near location: CLLocation, radius: Double) async throws -> [Spot] {
        var allMapItems: [MKMapItem] = []
        var newSpotsCount = 0
        var staleSpotsCount = 0
        
        // Search each category
        for (index, category) in searchCategories.enumerated() {
            await updateDiscoveryState(progress: "Searching \(category)s... (\(index + 1)/\(searchCategories.count))")
            
            let mapItems = try await searchCategory(category, near: location, radius: radius)
            
            // Process each map item
            for mapItem in mapItems {
                if let matchingSpot = findMatchingSpot(mapItem: mapItem) {
                    // Check if spot is stale (lastSeeded > 7 days ago)
                    let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                    if matchingSpot.lastSeeded < sevenDaysAgo {
                        logger.info("Found stale spot: \(mapItem.name ?? "Unknown") - will update")
                        allMapItems.append(mapItem)
                        staleSpotsCount += 1
                    } else {
                        logger.info("Found fresh spot: \(mapItem.name ?? "Unknown") - skipping")
                    }
                } else {
                    // New spot
                    allMapItems.append(mapItem)
                    newSpotsCount += 1
                }
            }
            
            // Small delay to avoid rate limiting
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        logger.info("Found \(allMapItems.count) spots to process (new: \(newSpotsCount), stale: \(staleSpotsCount))")
        
        // If no new or stale spots found, return existing spots
        if allMapItems.isEmpty {
            logger.info("No new or stale spots to process")
            await updateDiscoveryState(progress: "No new spots added")
            errorMessage = "No new spots added - all locations are up to date"
            return existingSpotsCache
        }
        
        // Enrich with Grok API and create/update Spot entities
        await updateDiscoveryState(progress: "Enriching locations with AI...")
        let enrichedSpots = try await enrichAndCreateSpots(from: allMapItems)
        
        // Combine existing and new/updated spots
        let allSpots = existingSpotsCache + enrichedSpots
        logger.info("Total spots after discovery: \(allSpots.count) (existing: \(self.existingSpotsCache.count), new/updated: \(enrichedSpots.count))")
        
        return allSpots
    }
    
    /**
     * Searches for a specific category of locations
     */
    private func searchCategory(_ category: String, near location: CLLocation, radius: Double) async throws -> [MKMapItem] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = category
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2
            )
            request.resultTypes = [.pointOfInterest]
            
            let search = MKLocalSearch(request: request)
            search.start { response, error in
                if let error = error {
                    self.logger.error("MKLocalSearch failed for \(category): \(error.localizedDescription)")
                    self.errorMessage = "Search failed for \(category): \(error.localizedDescription)"
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let response = response else {
                    self.logger.warning("No response from MKLocalSearch for \(category)")
                    continuation.resume(returning: [])
                    return
                }
                
                // Limit results per category
                let limitedResults = Array(response.mapItems.prefix(self.maxResultsPerCategory))
                let finalResults = limitedResults.count >= self.minResultsPerCategory ? 
                    limitedResults : limitedResults
                
                self.logger.info("Found \(finalResults.count) \(category)s")
                continuation.resume(returning: finalResults)
            }
        }
    }
    
    // MARK: - Grok API Integration
    
    /**
     * Enriches map items with AI-generated data and creates/updates Spot entities
     * Only calls Grok API for new or stale spots
     */
    private func enrichAndCreateSpots(from mapItems: [MKMapItem]) async throws -> [Spot] {
        guard let apiKey = getGrokAPIKey(), !apiKey.isEmpty else {
            logger.warning("GROK_API_KEY not found in build configuration")
            return try await createSpotsWithDefaults(from: mapItems)
        }
        
        var enrichedSpots: [Spot] = []
        let batchSize = 5 // Process in small batches to avoid overwhelming the API
        
        for (index, mapItem) in mapItems.enumerated() {
            let name = mapItem.name ?? "Unknown Location"
            let _ = mapItem.placemark.title ?? "Unknown Address"
            
            await updateDiscoveryState(progress: "Enriching location \(index + 1)/\(mapItems.count)...")
            
            do {
                let spot = try await enrichSingleSpot(mapItem: mapItem, apiKey: apiKey)
                enrichedSpots.append(spot)
                
                // Batch processing delay
                if (index + 1) % batchSize == 0 {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay between batches
                }
                
            } catch {
                logger.error("Failed to enrich spot \(name): \(error.localizedDescription)")
                errorMessage = "Failed to enrich spot: \(error.localizedDescription)"
                // Create spot with defaults if API fails
                let defaultSpot = try await createSpotWithDefaults(mapItem: mapItem)
                enrichedSpots.append(defaultSpot)
            }
        }
        
        // Deduplicate and save to Core Data
        let deduplicatedSpots = deduplicateSpots(enrichedSpots)
        await saveSpotsToCoreData(deduplicatedSpots)
        
        await updateDiscoveredCount(deduplicatedSpots.count)
        return deduplicatedSpots
    }
    
    /**
     * Enriches a single spot using the Grok API
     */
    private func enrichSingleSpot(mapItem: MKMapItem, apiKey: String) async throws -> Spot {
        let name = mapItem.name ?? "Unknown Location"
        let address = mapItem.placemark.title ?? "Unknown Address"
        
        let prompt = """
        For \(name) at \(address), estimate WiFi rating (1-5 stars), noise level (Low/Medium/High), plugs (Yes/No), and a short tip based on typical similar venues. Respond in JSON: {"wifi": number, "noise": string, "plugs": bool, "tip": string}.
        """
        
        let requestBody = GrokRequest(
            model: "grok-4-fast-non-reasoning",
            messages: [
                GrokMessage(role: "user", content: prompt)
            ],
            maxTokens: 150,
            temperature: 0.3
        )
        
        let enrichedData = try await callGrokAPI(requestBody: requestBody, apiKey: apiKey)
        
        return createSpotFromMapItem(
            mapItem: mapItem,
            enrichedData: enrichedData
        )
    }
    
    /**
     * Makes API call to Grok
     */
    private func callGrokAPI(requestBody: GrokRequest, apiKey: String) async throws -> GrokResponse {
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            throw SpotDiscoveryError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw SpotDiscoveryError.encodingError(error)
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotDiscoveryError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw SpotDiscoveryError.apiError(httpResponse.statusCode, errorMessage)
            }
            
            do {
                let grokResponse = try JSONDecoder().decode(GrokResponse.self, from: data)
                return grokResponse
            } catch {
                throw SpotDiscoveryError.decodingError(error)
            }
            
        } catch let error as SpotDiscoveryError {
            throw error
        } catch {
            throw SpotDiscoveryError.networkError(error)
        }
    }
    
    // MARK: - Spot Creation and Updating
    
    /**
     * Creates a Spot entity from map item and enriched data
     */
    private func createSpotFromMapItem(mapItem: MKMapItem, enrichedData: GrokResponse) -> Spot {
        let context = persistenceController.container.viewContext
        let spot = Spot(context: context)
        
        spot.name = mapItem.name ?? "Unknown Location"
        spot.address = mapItem.placemark.title ?? "Unknown Address"
        spot.latitude = mapItem.placemark.coordinate.latitude
        spot.longitude = mapItem.placemark.coordinate.longitude
        spot.lastModified = Date()
        spot.lastSeeded = Date()
        spot.cloudKitRecordID = UUID().uuidString
        spot.markAsModified()
        
        // Parse enriched data
        if let content = enrichedData.choices.first?.message.content,
           let data = content.data(using: .utf8) {
            do {
                let spotData = try JSONDecoder().decode(SpotData.self, from: data)
                spot.wifiRating = Int16(spotData.wifi)
                spot.noiseRating = spotData.noise
                spot.outlets = spotData.plugs
                spot.tips = spotData.tip
            } catch {
                logger.warning("Failed to parse enriched data, using defaults: \(error.localizedDescription)")
                setDefaultValues(for: spot)
            }
        } else {
            setDefaultValues(for: spot)
        }
        
        return spot
    }
    
    /**
     * Creates spots with default values when API fails
     */
    private func createSpotsWithDefaults(from mapItems: [MKMapItem]) async throws -> [Spot] {
        var spots: [Spot] = []
        
        for mapItem in mapItems {
            let spot = try await createSpotWithDefaults(mapItem: mapItem)
            spots.append(spot)
        }
        
        let deduplicatedSpots = deduplicateSpots(spots)
        await saveSpotsToCoreData(deduplicatedSpots)
        
        return deduplicatedSpots
    }
    
    /**
     * Creates a single spot with default values
     */
    private func createSpotWithDefaults(mapItem: MKMapItem) async throws -> Spot {
        let context = persistenceController.container.viewContext
        let spot = Spot(context: context)
        
        spot.name = mapItem.name ?? "Unknown Location"
        spot.address = mapItem.placemark.title ?? "Unknown Address"
        spot.latitude = mapItem.placemark.coordinate.latitude
        spot.longitude = mapItem.placemark.coordinate.longitude
        spot.lastModified = Date()
        spot.lastSeeded = Date()
        spot.cloudKitRecordID = UUID().uuidString
        spot.markAsModified()
        
        setDefaultValues(for: spot)
        
        return spot
    }
    
    /**
     * Sets default values for a spot
     */
    private func setDefaultValues(for spot: Spot) {
        spot.wifiRating = 3
        spot.noiseRating = "Medium"
        spot.outlets = false
        spot.tips = "Auto-discovered"
    }
    
    // MARK: - Utility Functions
    
    /**
     * Gets the Grok API key from environment variables
     * 
     * Prioritizes ProcessInfo.environment["GROK_API_KEY"] from Secrets.xcconfig
     * configuration. This approach keeps API keys secure and out of version control.
     */
    private func getGrokAPIKey() -> String? {
        // Primary: Get from environment variable (from Secrets.xcconfig)
        if let apiKey = ProcessInfo.processInfo.environment["GROK_API_KEY"], !apiKey.isEmpty {
            return apiKey
        }
        
        // Fallback: Get from Info.plist (from build configuration)
        if let apiKey = Bundle.main.object(forInfoDictionaryKey: "GROK_API_KEY") as? String, !apiKey.isEmpty {
            return apiKey
        }
        
        // For development: Use placeholder (replace with actual key for testing)
        #if DEBUG
        return "YOUR_GROK_API_KEY_HERE"
        #else
        return nil
        #endif
    }
    
    /**
     * Deduplicates spots and updates existing stale spots
     * Updates existing spots if lastSeeded > 7 days, otherwise skips
     */
    private func deduplicateSpots(_ spots: [Spot]) -> [Spot] {
        var seenKeys: Set<String> = []
        var deduplicated: [Spot] = []
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        
        for spot in spots {
            // Create composite key for exact matching
            let compositeKey = "\(spot.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(spot.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            
            // Check for exact duplicate in current batch
            if seenKeys.contains(compositeKey) {
                logger.info("Skipping exact duplicate in batch: \(spot.name) at \(spot.address)")
                continue
            }
            
            // Check if we should update an existing spot
            var shouldUpdate = false
            for existingSpot in existingSpotsCache {
                let existingCompositeKey = "\(existingSpot.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(existingSpot.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
                
                if compositeKey == existingCompositeKey && existingSpot.lastSeeded < sevenDaysAgo {
                    // Update existing stale spot
                    logger.info("Updating stale spot: \(spot.name) at \(spot.address)")
                    existingSpot.wifiRating = spot.wifiRating
                    existingSpot.noiseRating = spot.noiseRating
                    existingSpot.outlets = spot.outlets
                    existingSpot.tips = spot.tips
                    existingSpot.lastSeeded = Date()
                    existingSpot.lastModified = Date()
                    existingSpot.markAsModified()
                    shouldUpdate = true
                    break
                }
            }
            
            if shouldUpdate {
                continue // Skip adding to deduplicated list since we updated existing
            }
            
            // Check for proximity duplicate (within 100 meters)
            var isProximityDuplicate = false
            for existingSpot in deduplicated {
                let existingLocation = CLLocation(latitude: existingSpot.latitude, longitude: existingSpot.longitude)
                let newLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
                let distance = existingLocation.distance(from: newLocation)
                
                if distance < 100.0 {
                    logger.info("Skipping proximity duplicate: \(spot.name) at \(spot.address) (distance: \(distance)m from \(existingSpot.name))")
                    isProximityDuplicate = true
                    break
                }
            }
            
            if !isProximityDuplicate {
                seenKeys.insert(compositeKey)
                deduplicated.append(spot)
            }
        }
        
        logger.info("Deduplicated \(spots.count) spots to \(deduplicated.count) (updated existing stale spots)")
        return deduplicated
    }
    
    /**
     * Saves spots to Core Data
     */
    private func saveSpotsToCoreData(_ spots: [Spot]) async {
        await persistenceController.saveAsync()
        logger.info("Saved \(spots.count) spots to Core Data")
    }
    
    /**
     * Updates discovery state
     */
    @MainActor
    private func updateDiscoveryState(isDiscovering: Bool? = nil, progress: String? = nil) {
        if let isDiscovering = isDiscovering {
            self.isDiscovering = isDiscovering
        }
        if let progress = progress {
            self.discoveryProgress = progress
        }
    }
    
    /**
     * Updates discovered spots count
     */
    @MainActor
    private func updateDiscoveredCount(_ count: Int) {
        self.discoveredSpotsCount = count
    }
}

// MARK: - Data Models

/**
 * Grok API request model
 */
private struct GrokRequest: Codable {
    let model: String
    let messages: [GrokMessage]
    let maxTokens: Int
    let temperature: Double
}

/**
 * Grok API message model
 */
private struct GrokMessage: Codable {
    let role: String
    let content: String
}

/**
 * Grok API response model
 */
private struct GrokResponse: Codable {
    let choices: [GrokChoice]
}

/**
 * Grok API choice model
 */
private struct GrokChoice: Codable {
    let message: GrokMessage
}

/**
 * Spot enrichment data model
 */
private struct SpotData: Codable {
    let wifi: Int
    let noise: String
    let plugs: Bool
    let tip: String
}

// MARK: - Error Handling

/**
 * Spot discovery specific errors
 */
enum SpotDiscoveryError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(Int, String)
    case networkError(Error)
    case encodingError(Error)
    case decodingError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid API response"
        case .apiError(let code, let message):
            return "API Error \(code): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .encodingError(let error):
            return "Encoding error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        }
    }
}