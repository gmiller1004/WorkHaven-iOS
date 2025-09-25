//
//  Spot+CoreDataClass.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import CoreData
import CoreLocation
import OSLog

/**
 * Spot represents a work-friendly location in the WorkHaven app.
 * Each Spot contains location data, amenities, and user ratings.
 * This class provides additional functionality beyond the basic Core Data properties.
 */
@objc(Spot)
public class Spot: NSManagedObject {
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "Spot")
    
    // MARK: - Computed Properties
    
    /// Returns the location as a CLLocation object for mapping and distance calculations
    public var location: CLLocation {
        return CLLocation(latitude: latitude, longitude: longitude)
    }
    
    /// Returns the average WiFi rating from all user ratings
    public var averageWifiRating: Double {
        guard let ratings = userRatings?.allObjects as? [UserRating], !ratings.isEmpty else {
            return Double(wifiRating)
        }
        
        let sum = ratings.reduce(0) { $0 + Int($1.wifi) }
        return Double(sum) / Double(ratings.count)
    }
    
    /// Returns the most common noise rating from user ratings
    public var commonNoiseRating: String {
        guard let ratings = userRatings?.allObjects as? [UserRating], !ratings.isEmpty else {
            return noiseRating
        }
        
        let noiseCounts = ratings.reduce(into: [String: Int]()) { counts, rating in
            counts[rating.noise, default: 0] += 1
        }
        
        return noiseCounts.max(by: { $0.value < $1.value })?.key ?? noiseRating
    }
    
    /// Returns the percentage of users who found outlets available
    public var outletAvailabilityPercentage: Double {
        guard let ratings = userRatings?.allObjects as? [UserRating], !ratings.isEmpty else {
            return outlets ? 100.0 : 0.0
        }
        
        let withOutlets = ratings.filter { $0.plugs }.count
        return (Double(withOutlets) / Double(ratings.count)) * 100.0
    }
    
    // MARK: - Lifecycle Methods
    
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        
        // Set default values for new spots
        if type.isEmpty {
            type = "unknown"
        }
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = ""
        }
        lastModified = Date()
        lastSeeded = Date()
    }
    
    public override func awakeFromFetch() {
        super.awakeFromFetch()
        
        // Ensure type is not empty (fallback for existing data)
        if type.isEmpty {
            type = "unknown"
        }
        // Ensure cloudKitRecordID is not nil
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = ""
        }
    }
    
    // MARK: - Helper Methods
    
    /// Updates the lastModified timestamp to the current date
    public func updateLastModified() {
        lastModified = Date()
    }
    
    /// Calculates the distance to another spot in meters
    public func distance(to otherSpot: Spot) -> CLLocationDistance {
        return location.distance(from: otherSpot.location)
    }
    
    /// Calculates the distance to a given location in meters
    public func distance(to location: CLLocation) -> CLLocationDistance {
        return self.location.distance(from: location)
    }
    
    /// Returns a formatted address string
    public var formattedAddress: String {
        return address
    }
    
    /// Returns a summary of amenities
    public var amenitiesSummary: String {
        var amenities: [String] = []
        
        if outlets {
            amenities.append("Outlets Available")
        }
        
        if !tips.isEmpty {
            amenities.append("Tips Available")
        }
        
        if photoURL != nil {
            amenities.append("Photo Available")
        }
        
        return amenities.joined(separator: " • ")
    }
    
    /// Returns a display-friendly name with location context
    public var displayName: String {
        if let city = extractCityFromAddress() {
            return "\(name) (\(city))"
        }
        return name
    }
    
    /// Extracts city name from the address string
    private func extractCityFromAddress() -> String? {
        let components = address.components(separatedBy: ",")
        return components.count > 1 ? components[1].trimmingCharacters(in: .whitespaces) : nil
    }
    
    // MARK: - CloudKit Integration
    
    /// Generates a unique CloudKit record ID if not already set
    public func ensureCloudKitRecordID() {
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = UUID().uuidString
        }
    }
    
    /// Updates CloudKit record ID and timestamp
    public func markAsModified() {
        updateLastModified()
        ensureCloudKitRecordID()
    }
    
    // MARK: - Validation
    
    /// Validates that the spot has required data
    public var isValid: Bool {
        return !name.isEmpty && 
               !address.isEmpty && 
               !cloudKitRecordID.isEmpty &&
               latitude != 0.0 && 
               longitude != 0.0
    }
    
    /// Returns validation errors if any
    public var validationErrors: [String] {
        var errors: [String] = []
        
        if name.isEmpty {
            errors.append("Name is required")
        }
        
        if address.isEmpty {
            errors.append("Address is required")
        }
        
        if latitude == 0.0 && longitude == 0.0 {
            errors.append("Valid coordinates are required")
        }
        
        if cloudKitRecordID.isEmpty {
            errors.append("CloudKit record ID is required")
        }
        
        return errors
    }
    
    // MARK: - Favorite Management
    
    /**
     * Adds this spot to user favorites
     * - Parameter context: The Core Data context to use
     * - Returns: The created UserFavorite instance
     */
    public func addToFavorites(in context: NSManagedObjectContext) -> UserFavorite {
        let favorite = UserFavorite.create(for: self, in: context)
        addToFavorites(favorite)
        markAsModified()
        
        logger.info("Added spot '\(self.name)' to favorites")
        return favorite
    }
    
    /**
     * Removes this spot from user favorites
     * - Parameter context: The Core Data context to use
     */
    public func removeFromFavorites(in context: NSManagedObjectContext) {
        guard let favoritesSet = favorites,
              let favoritesArray = favoritesSet.allObjects as? [UserFavorite] else {
            logger.warning("No favorites found for spot '\(self.name)'")
            return
        }
        
        for favorite in favoritesArray {
            favorite.removeFavorite()
        }
        
        markAsModified()
        logger.info("Removed spot '\(self.name)' from favorites")
    }
    
    /**
     * Checks if this spot is favorited by the user
     * - Returns: True if the spot has any favorites
     */
    public var isFavorited: Bool {
        guard let favoritesSet = favorites else { return false }
        return favoritesSet.count > 0
    }
    
    /**
     * Returns the number of times this spot has been favorited
     * - Returns: Count of favorites for this spot
     */
    public var favoriteCount: Int {
        return favorites?.count ?? 0
    }
    
    /**
     * Returns the most recent favorite timestamp
     * - Returns: The timestamp of the most recent favorite, or nil if not favorited
     */
    public var lastFavorited: Date? {
        guard let favoritesSet = favorites,
              let favoritesArray = favoritesSet.allObjects as? [UserFavorite] else {
            return nil
        }
        
        return favoritesArray.map { $0.timestamp }.max()
    }
}
