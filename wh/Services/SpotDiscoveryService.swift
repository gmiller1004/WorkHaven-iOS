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
 * spaces, then enriches them with AI-generated ratings and tips.
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
    
    // MARK: - Published Properties
    
    @Published var isDiscovering = false
    @Published var discoveryProgress: String = ""
    @Published var discoveredSpotsCount = 0
    @Published var errorMessage: String?
    
    // MARK: - Main Discovery Function
    
    /**
     * Discovers work spots near a given location with enhanced duplicate prevention
     * - Parameter location: The center point for discovery
     * - Parameter radius: Search radius in meters (default: 20 miles)
     * - Returns: Array of discovered Spot entities
     */
    func discoverSpots(near location: CLLocation, radius: Double? = nil) async -> [Spot] {
        let searchRadius = radius ?? defaultRadius
        
        logger.info("Starting spot discovery near \(location.coordinate.latitude), \(location.coordinate.longitude) with radius \(searchRadius)m")
        await updateDiscoveryState(isDiscovering: true, progress: "Checking existing spots...")
        
        do {
            // First, check if we already have spots in this area
            let existingSpots = await checkExistingSpots(near: location, radius: searchRadius)
            
            if !existingSpots.isEmpty {
                logger.info("Found \(existingSpots.count) existing spots within radius")
                await updateDiscoveryState(progress: "Checking for new spots...")
                
                // Proceed with discovery but filter duplicates against existing spots
                let discoveredSpots = try await performSpotDiscovery(near: location, radius: searchRadius)
                
                await updateDiscoveryState(isDiscovering: false, progress: "Discovery complete")
                logger.info("Successfully discovered \(discoveredSpots.count) total spots (existing + new)")
                
                return discoveredSpots
            }
            
            // No existing spots found, proceed with discovery
            await updateDiscoveryState(progress: "Searching for new locations...")
            let discoveredSpots = try await performSpotDiscovery(near: location, radius: searchRadius)
            
            await updateDiscoveryState(isDiscovering: false, progress: "Discovery complete")
            logger.info("Successfully discovered \(discoveredSpots.count) new spots")
            
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
     * Uses composite predicate for name+address matching and proximity checking
     * Only returns spots with lastSeeded > 7 days ago to allow for refresh
     */
    private func checkExistingSpots(near location: CLLocation, radius: Double) async -> [Spot] {
        let context = persistenceController.container.viewContext
        let request: NSFetchRequest<Spot> = Spot.fetchRequest()
        
        // Create a bounding box for efficient querying
        let latRange = radius / 111000.0 // Rough conversion to degrees
        let lngRange = radius / (111000.0 * cos(location.coordinate.latitude * .pi / 180))
        
        let minLat = location.coordinate.latitude - latRange
        let maxLat = location.coordinate.latitude + latRange
        let minLng = location.coordinate.longitude - lngRange
        let maxLng = location.coordinate.longitude + lngRange
        
        // Date threshold for refresh (7 days ago)
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        
        request.predicate = NSPredicate(
            format: "latitude >= %f AND latitude <= %f AND longitude >= %f AND longitude <= %f AND lastSeeded > %@",
            minLat, maxLat, minLng, maxLng, sevenDaysAgo as NSDate
        )
        
        do {
            let spots = try context.fetch(request)
            // Filter by actual distance to get precise results
            let nearbySpots = spots.filter { spot in
                let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
                return location.distance(from: spotLocation) <= radius
            }
            logger.info("Found \(nearbySpots.count) existing spots within radius (lastSeeded > 7 days ago)")
            return nearbySpots
        } catch {
            logger.error("Failed to fetch existing spots: \(error.localizedDescription)")
            errorMessage = "Failed to check existing spots: \(error.localizedDescription)"
            return []
        }
    }
    
    /**
     * Checks if a spot already exists using composite key and proximity against Core Data
     * - Parameter mapItem: The MKMapItem to check for duplicates
     * - Parameter existingSpots: Array of existing spots to check against
     * - Returns: True if a duplicate is found, false otherwise
     */
    private func isDuplicateSpot(mapItem: MKMapItem, existingSpots: [Spot]) -> Bool {
        let name = mapItem.name ?? "Unknown Location"
        let address = mapItem.placemark.title ?? "Unknown Address"
        let coordinate = mapItem.placemark.coordinate
        
        // Create composite key for exact matching
        let compositeKey = "\(name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        
        for existingSpot in existingSpots {
            // Check composite key match
            let existingCompositeKey = "\(existingSpot.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(existingSpot.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            
            if compositeKey == existingCompositeKey {
                self.logger.info("Found exact duplicate: \(name) at \(address)")
                return true
            }
            
            // Check proximity match (within 100 meters)
            let existingLocation = CLLocation(latitude: existingSpot.latitude, longitude: existingSpot.longitude)
            let newLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = existingLocation.distance(from: newLocation)
            
            if distance < 100.0 {
                self.logger.info("Found proximity duplicate: \(name) at \(address) (distance: \(distance)m)")
                return true
            }
        }
        
        return false
    }
    
    /**
     * Checks if a spot exists in Core Data using composite key (name + address)
     * - Parameter name: Spot name
     * - Parameter address: Spot address
     * - Returns: True if spot exists, false otherwise
     */
    private func spotExistsInCoreData(name: String, address: String) -> Bool {
        let context = persistenceController.container.viewContext
        let request: NSFetchRequest<Spot> = Spot.fetchRequest()
        
        let normalizedName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAddress = address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        request.predicate = NSPredicate(
            format: "name ==[c] %@ AND address ==[c] %@",
            normalizedName, normalizedAddress
        )
        
        do {
            let count = try context.count(for: request)
            return count > 0
        } catch {
            logger.error("Failed to check spot existence in Core Data: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - MKLocalSearch Implementation
    
    /**
     * Performs the actual spot discovery using MKLocalSearch
     * Filters out duplicates before enrichment to prevent unnecessary API calls
     */
    private func performSpotDiscovery(near location: CLLocation, radius: Double) async throws -> [Spot] {
        var allMapItems: [MKMapItem] = []
        
        // Get existing spots for duplicate checking
        let existingSpots = await checkExistingSpots(near: location, radius: radius)
        
        // Search each category
        for (index, category) in searchCategories.enumerated() {
            await updateDiscoveryState(progress: "Searching \(category)s... (\(index + 1)/\(searchCategories.count))")
            
            let mapItems = try await searchCategory(category, near: location, radius: radius)
            
            // Filter out duplicates before adding to allMapItems
            let uniqueMapItems = mapItems.filter { mapItem in
                !isDuplicateSpot(mapItem: mapItem, existingSpots: existingSpots)
            }
            
            allMapItems.append(contentsOf: uniqueMapItems)
            
            // Log duplicate detection and show alert
            let duplicateCount = mapItems.count - uniqueMapItems.count
            if duplicateCount > 0 {
                logger.info("Filtered out \(duplicateCount) duplicate \(category)s")
                await showDuplicateAlert(duplicateCount: duplicateCount, category: category)
            }
            
            // Small delay to avoid rate limiting
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        logger.info("Found \(allMapItems.count) unique map items (after duplicate filtering)")
        
        // If no new spots found, return existing spots
        if allMapItems.isEmpty {
            logger.info("No new spots to discover, returning existing spots")
            await updateDiscoveryState(progress: "No new spots found")
            errorMessage = "No new spots found - all locations already discovered"
            return existingSpots
        }
        
        // Enrich with Grok API and create Spot entities
        await updateDiscoveryState(progress: "Enriching locations with AI...")
        let enrichedSpots = try await enrichAndCreateSpots(from: allMapItems)
        
        // Combine existing and new spots
        let allSpots = existingSpots + enrichedSpots
        logger.info("Total spots after discovery: \(allSpots.count) (existing: \(existingSpots.count), new: \(enrichedSpots.count))")
        
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
     * Enriches map items with AI-generated data and creates Spot entities
     * Skips Grok API calls for spots already found in Core Data
     */
    private func enrichAndCreateSpots(from mapItems: [MKMapItem]) async throws -> [Spot] {
        guard let apiKey = getGrokAPIKey(), !apiKey.isEmpty else {
            logger.warning("GROK_API_KEY not found in build configuration")
            return try await createSpotsWithDefaults(from: mapItems)
        }
        
        var enrichedSpots: [Spot] = []
        let batchSize = 5 // Process in small batches to avoid overwhelming the API
        var skippedCount = 0
        
        for (index, mapItem) in mapItems.enumerated() {
            let name = mapItem.name ?? "Unknown Location"
            let address = mapItem.placemark.title ?? "Unknown Address"
            
            // Check if spot already exists in Core Data
            if spotExistsInCoreData(name: name, address: address) {
                logger.info("Skipping Grok API call for existing spot: \(name) at \(address)")
                skippedCount += 1
                continue
            }
            
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
        
        // Log API optimization results
        if skippedCount > 0 {
            logger.info("Skipped \(skippedCount) Grok API calls for existing spots")
        }
        
        // Deduplicate by address and save to Core Data
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
    
    // MARK: - Spot Creation
    
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
     * Deduplicates spots using composite key (name + address) and proximity
     * Checks against Core Data before saving to prevent duplicates
     */
    private func deduplicateSpots(_ spots: [Spot]) -> [Spot] {
        var seenKeys: Set<String> = []
        var deduplicated: [Spot] = []
        
        for spot in spots {
            // Create composite key for exact matching
            let compositeKey = "\(spot.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(spot.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            
            // Check for exact duplicate in current batch
            if seenKeys.contains(compositeKey) {
                logger.info("Skipping exact duplicate in batch: \(spot.name) at \(spot.address)")
                continue
            }
            
            // Check if spot already exists in Core Data
            if spotExistsInCoreData(name: spot.name, address: spot.address) {
                logger.info("Skipping spot that exists in Core Data: \(spot.name) at \(spot.address)")
                continue
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
        
        logger.info("Deduplicated \(spots.count) spots to \(deduplicated.count) (checked against Core Data)")
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
    
    /**
     * Shows duplicate detection alert using ThemeManager colors
     * - Parameter duplicateCount: Number of duplicates found
     * - Parameter category: Category of spots being processed
     */
    @MainActor
    private func showDuplicateAlert(duplicateCount: Int, category: String) {
        if duplicateCount > 0 {
            errorMessage = "Found \(duplicateCount) duplicate \(category)s - skipped to prevent duplicates"
            logger.info("Duplicate alert: \(duplicateCount) \(category)s skipped")
        }
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
