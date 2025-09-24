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
            
            // Log context state
            logger.info("Context has \(self.existingSpotsCache.count) spots")
            
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
     * Checks for existing spots using PersistenceController.shared.container.viewContext
     * Queries all spots and returns matches on name.lowercased() + address.lowercased() 
     * or lat/long proximity < 100m. Caches results to avoid redundant calls.
     */
    private func checkExistingSpots(near location: CLLocation, radius: Double) async -> [Spot] {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<Spot> = Spot.fetchRequest()
        
        // Query all spots (no predicate for comprehensive checking)
        do {
            let allSpots = try context.fetch(request)
            
            // Log context state
            logger.info("Context has \(allSpots.count) spots")
            
            // Filter by proximity (< 100m) for efficient matching
            let nearbySpots = allSpots.filter { spot in
                let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
                return location.distance(from: spotLocation) < 100.0
            }
            
            logger.info("Found \(nearbySpots.count) existing spots within 100m proximity")
            return nearbySpots
        } catch {
            logger.error("Failed to fetch existing spots: \(error.localizedDescription)")
            errorMessage = "Failed to check existing spots: \(error.localizedDescription)"
            return []
        }
    }
    
    /**
     * Checks if a spot matches existing spots by name.lowercased() + address.lowercased() 
     * or lat/long proximity < 100m
     * - Parameter mapItem: The MKMapItem to check for matches
     * - Returns: Matching existing spot if found, nil otherwise
     */
    private func findMatchingSpot(mapItem: MKMapItem) -> Spot? {
        let name = mapItem.name ?? "Unknown Location"
        let address = mapItem.placemark.title ?? "Unknown Address"
        let coordinate = mapItem.placemark.coordinate
        
        // Create composite key for exact matching (name.lowercased() + address.lowercased())
        let compositeKey = "\(name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        
        for existingSpot in existingSpotsCache {
            // Check composite key match (name.lowercased() + address.lowercased())
            let existingCompositeKey = "\(existingSpot.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(existingSpot.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            
            if compositeKey == existingCompositeKey {
                logger.info("Found exact match: \(name) at \(address)")
                return existingSpot
            }
            
            // Check proximity match (lat/long proximity < 100m)
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
            errorMessage = "No new spots added"
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
     * Batches Grok API calls (10 spots per request, max 2 concurrent) to reduce latency.
     * Only calls Grok API for new or stale spots.
     */
    private func enrichAndCreateSpots(from mapItems: [MKMapItem]) async throws -> [Spot] {
        guard let apiKey = getGrokAPIKey(), !apiKey.isEmpty else {
            logger.warning("GROK_API_KEY not found in build configuration")
            return try await createSpotsWithDefaults(from: mapItems)
        }
        
        var enrichedSpots: [Spot] = []
        let batchSize = 10 // 10 spots per request
        let maxConcurrent = 2 // Max 2 concurrent requests
        
        // Create batches
        let batches = stride(from: 0, to: mapItems.count, by: batchSize).map { batchStart in
            let batchEnd = min(batchStart + batchSize, mapItems.count)
            return Array(mapItems[batchStart..<batchEnd])
        }
        
        // Process batches with max 2 concurrent requests
        await withTaskGroup(of: Result<[Spot], Error>.self) { group in
            var activeTasks = 0
            var batchIndex = 0
            
            // Start initial tasks (up to maxConcurrent)
            while activeTasks < maxConcurrent && batchIndex < batches.count {
                let batch = batches[batchIndex]
                let currentBatchIndex = batchIndex
                group.addTask {
                    await self.updateDiscoveryState(progress: "Enriching batch \(currentBatchIndex + 1)/\(batches.count)...")
                    
                    do {
                        return .success(try await self.enrichBatchSpots(batch, apiKey: apiKey))
                    } catch {
                        self.logger.error("Failed to enrich batch \(currentBatchIndex + 1): \(error.localizedDescription)")
                        Task { @MainActor in
                            self.errorMessage = "Failed to enrich batch: \(error.localizedDescription)"
                        }
                        
                        // Create spots with defaults if batch API fails
                        do {
                            var fallbackSpots: [Spot] = []
                            for mapItem in batch {
                                let defaultSpot = try await self.createSpotWithDefaults(mapItem: mapItem)
                                fallbackSpots.append(defaultSpot)
                            }
                            return .success(fallbackSpots)
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                activeTasks += 1
                batchIndex += 1
            }
            
            // Process remaining batches as tasks complete
            while batchIndex < batches.count {
                if let result = await group.next() {
                    switch result {
                    case .success(let batchSpots):
                        enrichedSpots.append(contentsOf: batchSpots)
                    case .failure(let error):
                        logger.error("Batch processing failed: \(error.localizedDescription)")
                    }
                    activeTasks -= 1
                    
                    // Start next batch if available
                    if batchIndex < batches.count {
                        let batch = batches[batchIndex]
                        let currentBatchIndex = batchIndex
                        group.addTask {
                            await self.updateDiscoveryState(progress: "Enriching batch \(currentBatchIndex + 1)/\(batches.count)...")
                            
                            do {
                                return .success(try await self.enrichBatchSpots(batch, apiKey: apiKey))
                            } catch {
                                self.logger.error("Failed to enrich batch \(currentBatchIndex + 1): \(error.localizedDescription)")
                                Task { @MainActor in
                                    self.errorMessage = "Failed to enrich batch: \(error.localizedDescription)"
                                }
                                
                                // Create spots with defaults if batch API fails
                                do {
                                    var fallbackSpots: [Spot] = []
                                    for mapItem in batch {
                                        let defaultSpot = try await self.createSpotWithDefaults(mapItem: mapItem)
                                        fallbackSpots.append(defaultSpot)
                                    }
                                    return .success(fallbackSpots)
                                } catch {
                                    return .failure(error)
                                }
                            }
                        }
                        activeTasks += 1
                        batchIndex += 1
                    }
                }
            }
            
            // Collect remaining results
            for await result in group {
                switch result {
                case .success(let batchSpots):
                    enrichedSpots.append(contentsOf: batchSpots)
                case .failure(let error):
                    logger.error("Batch processing failed: \(error.localizedDescription)")
                }
            }
        }
        
        // Deduplicate and save to Core Data
        let deduplicatedSpots = deduplicateSpots(enrichedSpots)
        await saveSpotsToCoreData(deduplicatedSpots)
        
        await updateDiscoveredCount(deduplicatedSpots.count)
        return deduplicatedSpots
    }
    
    /**
     * Enriches a batch of spots using the Grok API
     * Processes up to 10 spots in a single API call to reduce latency
     */
    private func enrichBatchSpots(_ mapItems: [MKMapItem], apiKey: String) async throws -> [Spot] {
        let spotDescriptions = mapItems.map { mapItem in
            let name = mapItem.name ?? "Unknown Location"
            let address = mapItem.placemark.title ?? "Unknown Address"
            return "\(name) at \(address)"
        }.joined(separator: ", ")
        
        let prompt = """
        For these locations: \(spotDescriptions), estimate WiFi rating (1-5 stars), noise level (Low/Medium/High), plugs (Yes/No), and a short tip for each. 
        
        IMPORTANT: Respond ONLY with a valid JSON array in this exact format:
        [{"name": "Exact Location Name", "wifi": 4, "noise": "Medium", "plugs": true, "tip": "Great coffee and atmosphere"}]
        
        Ensure each location name matches exactly with the input. Use only "Low", "Medium", or "High" for noise levels.
        """
        
        let requestBody = GrokRequest(
            model: "grok-4-fast-non-reasoning",
            messages: [
                GrokMessage(role: "user", content: prompt)
            ],
            maxTokens: 500, // Increased for batch processing
            temperature: 0.3
        )
        
        let enrichedData = try await callGrokAPI(requestBody: requestBody, apiKey: apiKey)
        
        // Parse batch response and create spots
        var spots: [Spot] = []
        if let content = enrichedData.choices.first?.message.content,
           let data = content.data(using: .utf8) {
            
            logger.debug("Grok API response: \(content)")
            
            do {
                let batchData = try JSONDecoder().decode([BatchSpotData].self, from: data)
                logger.info("Successfully parsed \(batchData.count) enriched spots from Grok API")
                
                // Match batch data to map items by name
                for mapItem in mapItems {
                    let name = mapItem.name ?? "Unknown Location"
                    let address = mapItem.placemark.title ?? "Unknown Address"
                    
                    // Try exact match first
                    if let spotData = batchData.first(where: { $0.name.lowercased() == name.lowercased() }) {
                        let spot = createSpotFromMapItem(mapItem: mapItem, batchData: spotData)
                        spots.append(spot)
                        logger.debug("Enriched spot (exact match): \(name) - WiFi: \(spotData.wifi), Noise: \(spotData.noise)")
                    } else {
                        // Try partial match - Grok API includes full address in name
                        if let spotData = batchData.first(where: { grokName in
                            // Check if Grok name contains our venue name
                            grokName.name.lowercased().contains(name.lowercased()) ||
                            // Or if our venue name contains the first part of Grok name
                            name.lowercased().contains(grokName.name.components(separatedBy: " at ").first?.lowercased() ?? "")
                        }) {
                            let spot = createSpotFromMapItem(mapItem: mapItem, batchData: spotData)
                            spots.append(spot)
                            logger.debug("Enriched spot (partial match): \(name) - WiFi: \(spotData.wifi), Noise: \(spotData.noise)")
                        } else {
                            logger.warning("No Grok data found for \(name), using defaults")
                            // Fallback to default if no match found
                            let defaultSpot = try await createSpotWithDefaults(mapItem: mapItem)
                            spots.append(defaultSpot)
                        }
                    }
                }
            } catch {
                logger.error("Failed to parse batch enriched data: \(error.localizedDescription)")
                logger.error("Raw response: \(content)")
                // Fallback to individual processing
                for mapItem in mapItems {
                    let defaultSpot = try await createSpotWithDefaults(mapItem: mapItem)
                    spots.append(defaultSpot)
                }
            }
        } else {
            logger.warning("No content in Grok API response, using defaults")
            // Fallback to defaults if no content
            for mapItem in mapItems {
                let defaultSpot = try await createSpotWithDefaults(mapItem: mapItem)
                spots.append(defaultSpot)
            }
        }
        
        return spots
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
            // Configure URLSession with timeout
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30.0
            config.timeoutIntervalForResource = 60.0
            let session = URLSession(configuration: config)
            
            let (data, response) = try await session.data(for: request)
            
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
        // Let CloudKit generate the record ID automatically
        spot.cloudKitRecordID = ""
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
     * Creates a Spot entity from map item and batch data
     */
    private func createSpotFromMapItem(mapItem: MKMapItem, batchData: BatchSpotData) -> Spot {
        let context = persistenceController.container.viewContext
        let spot = Spot(context: context)
        
        spot.name = mapItem.name ?? "Unknown Location"
        spot.address = mapItem.placemark.title ?? "Unknown Address"
        spot.latitude = mapItem.placemark.coordinate.latitude
        spot.longitude = mapItem.placemark.coordinate.longitude
        spot.lastModified = Date()
        spot.lastSeeded = Date()
        // Let CloudKit generate the record ID automatically
        spot.cloudKitRecordID = ""
        spot.markAsModified()
        
        // Use batch data
        spot.wifiRating = Int16(batchData.wifi)
        spot.noiseRating = batchData.noise
        spot.outlets = batchData.plugs
        spot.tips = batchData.tip
        
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
        // Let CloudKit generate the record ID automatically
        spot.cloudKitRecordID = ""
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
            logger.info("Found Grok API key from environment variable")
            return apiKey
        }
        
        // Fallback: Get from Info.plist (from build configuration)
        if let apiKey = Bundle.main.object(forInfoDictionaryKey: "GROK_API_KEY") as? String, !apiKey.isEmpty {
            logger.info("Found Grok API key from Info.plist")
            return apiKey
        }
        
        logger.warning("GROK_API_KEY not found in environment or Info.plist")
        return nil
    }
    
    /**
     * Deduplicates spots and updates existing stale spots
     * Updates existing spots (wifiRating, noiseRating, outlets, tips, lastSeeded) 
     * if lastSeeded > 7 days, otherwise skips
     */
    private func deduplicateSpots(_ spots: [Spot]) -> [Spot] {
        var seenKeys: Set<String> = []
        var deduplicated: [Spot] = []
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        var updatedExistingCount = 0
        
        for spot in spots {
            // Create composite key for exact matching (name.lowercased() + address.lowercased())
            let compositeKey = "\(spot.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(spot.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            
            // Check for exact duplicate in current batch
            if seenKeys.contains(compositeKey) {
                logger.info("Skipping exact duplicate in batch: \(spot.name) at \(spot.address)")
                continue
            }
            
            // Check if we should update an existing spot (lastSeeded > 7 days)
            var shouldUpdate = false
            for existingSpot in existingSpotsCache {
                let existingCompositeKey = "\(existingSpot.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(existingSpot.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
                
                if compositeKey == existingCompositeKey && existingSpot.lastSeeded < sevenDaysAgo {
                    // Update existing stale spot (wifiRating, noiseRating, outlets, tips, lastSeeded)
                    logger.info("Updating stale spot: \(spot.name) at \(spot.address)")
                    existingSpot.wifiRating = spot.wifiRating
                    existingSpot.noiseRating = spot.noiseRating
                    existingSpot.outlets = spot.outlets
                    existingSpot.tips = spot.tips
                    existingSpot.lastSeeded = Date()
                    existingSpot.lastModified = Date()
                    existingSpot.markAsModified()
                    shouldUpdate = true
                    updatedExistingCount += 1
                    break
                } else if compositeKey == existingCompositeKey {
                    logger.info("Skipping fresh spot (lastSeeded < 7 days): \(spot.name) at \(spot.address)")
                    shouldUpdate = true
                    break
                }
            }
            
            if shouldUpdate {
                continue // Skip adding to deduplicated list since we updated existing or skipped fresh
            }
            
            // Check for proximity duplicate (lat/long proximity < 100m)
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
        
        logger.info("Deduplicated \(spots.count) spots to \(deduplicated.count) (updated \(updatedExistingCount) existing stale spots)")
        return deduplicated
    }
    
    /**
     * Saves spots to Core Data
     */
    private func saveSpotsToCoreData(_ spots: [Spot]) async {
        let context = persistenceController.container.viewContext
        
        do {
            if context.hasChanges {
                try context.save()
                logger.info("Saved \(spots.count) spots to Core Data")
                
                // Trigger CloudKit sync
                logger.info("CloudKit sync triggered for \(spots.count) spots")
            }
        } catch {
            logger.error("Failed to save spots to Core Data: \(error.localizedDescription)")
        }
    }
    
    /**
     * Updates discovery state
     */
    @MainActor
    private func updateDiscoveryState(isDiscovering: Bool? = nil, progress: String? = nil) async {
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

/**
 * Batch spot enrichment data model
 */
private struct BatchSpotData: Codable {
    let name: String
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