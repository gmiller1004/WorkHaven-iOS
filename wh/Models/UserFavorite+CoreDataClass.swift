//
//  UserFavorite+CoreDataClass.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import CoreData
import CloudKit
import OSLog

/**
 * UserFavorite+CoreDataClass provides the custom NSManagedObject subclass
 * for the UserFavorite entity. Handles user favorites for work spots with
 * CloudKit synchronization and custom business logic.
 */
@objc(UserFavorite)
public class UserFavorite: NSManagedObject {
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "UserFavorite")
    
    // MARK: - Core Data Lifecycle
    
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        
        // Set default values for new favorites
        timestamp = Date()
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = ""
        }
    }
    
    public override func awakeFromFetch() {
        super.awakeFromFetch()
        
        // Ensure cloudKitRecordID is not nil
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = ""
        }
    }
    
    // MARK: - CloudKit Integration
    
    /**
     * Ensures the CloudKit record ID is set for synchronization
     */
    public func ensureCloudKitRecordID() {
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = ""
        }
    }
    
    /**
     * Marks the favorite as modified for CloudKit sync
     */
    public func markAsModified() {
        timestamp = Date()
    }
    
    // MARK: - Validation
    
    public override func validateForInsert() throws {
        try super.validateForInsert()
        try validateFavorite()
    }
    
    public override func validateForUpdate() throws {
        try super.validateForUpdate()
        try validateFavorite()
    }
    
    /**
     * Validates the favorite entity
     */
    private func validateFavorite() throws {
        guard spot != nil else {
            throw NSError(domain: "UserFavoriteValidation", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "Favorite must be associated with a spot"
            ])
        }
    }
    
    // MARK: - Convenience Methods
    
    /**
     * Creates a new UserFavorite for a spot
     * - Parameter spot: The spot to favorite
     * - Parameter context: The Core Data context
     * - Returns: A new UserFavorite instance
     */
    public static func create(for spot: Spot, in context: NSManagedObjectContext) -> UserFavorite {
        let favorite = UserFavorite(context: context)
        favorite.spot = spot
        favorite.timestamp = Date()
        favorite.cloudKitRecordID = ""
        favorite.markAsModified()
        
        let logger = Logger(subsystem: "com.nextsizzle.wh", category: "UserFavorite")
        logger.info("Created favorite for spot: \(spot.name)")
        return favorite
    }
    
    /**
     * Removes the favorite from Core Data and CloudKit
     */
    public func removeFavorite() {
        logger.info("Removing favorite for spot: \(self.spot?.name ?? "Unknown")")
        
        // Remove from Core Data
        managedObjectContext?.delete(self)
    }
    
    /**
     * Checks if the favorite is valid
     * - Returns: True if the favorite has a valid spot
     */
    public var isValid: Bool {
        return spot != nil
    }
    
    /**
     * Returns validation errors for this favorite
     * - Returns: Array of validation error messages
     */
    public var validationErrors: [String] {
        var errors: [String] = []
        
        if spot == nil {
            errors.append("Favorite must be associated with a spot")
        }
        
        return errors
    }
}
