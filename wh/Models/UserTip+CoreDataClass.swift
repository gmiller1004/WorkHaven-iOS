//
//  UserTip+CoreDataClass.swift
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
 * UserTip+CoreDataClass provides custom logic and computed properties
 * for the UserTip Core Data entity. This file contains business logic
 * and should be manually maintained.
 */
@objc(UserTip)
public class UserTip: NSManagedObject {
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "UserTip")
    
    // MARK: - Computed Properties
    
    /// Returns the net score (likes - dislikes) for this tip
    public var netScore: Int16 {
        return likes - dislikes
    }
    
    /// Returns a formatted string showing likes and dislikes
    public var likesDislikesString: String {
        if likes == 0 && dislikes == 0 {
            return "No reactions yet"
        } else if dislikes == 0 {
            return "\(likes) like\(likes == 1 ? "" : "s")"
        } else if likes == 0 {
            return "\(dislikes) dislike\(dislikes == 1 ? "" : "s")"
        } else {
            return "\(likes) like\(likes == 1 ? "" : "s"), \(dislikes) dislike\(dislikes == 1 ? "" : "s")"
        }
    }
    
    /// Returns a formatted timestamp string
    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    // MARK: - Lifecycle Methods
    
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        
        // Set default values
        timestamp = Date()
        cloudKitRecordID = ""
        likes = 0
        dislikes = 0
        text = ""
    }
    
    public override func awakeFromFetch() {
        super.awakeFromFetch()
        
        // Ensure cloudKitRecordID is not nil
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = ""
        }
    }
    
    // MARK: - Likes and Dislikes Methods
    
    /// Adds a like to this tip and syncs to CloudKit
    public func addLike() {
        likes += 1
        syncLikesToCloudKit()
    }
    
    /// Removes a like from this tip and syncs to CloudKit
    public func removeLike() {
        if likes > 0 {
            likes -= 1
            syncLikesToCloudKit()
        }
    }
    
    /// Adds a dislike to this tip and syncs to CloudKit
    public func addDislike() {
        dislikes += 1
        syncLikesToCloudKit()
    }
    
    /// Removes a dislike from this tip and syncs to CloudKit
    public func removeDislike() {
        if dislikes > 0 {
            dislikes -= 1
            syncLikesToCloudKit()
        }
    }
    
    // MARK: - CloudKit Sync Methods
    
    /// Syncs likes and dislikes to CloudKit
    private func syncLikesToCloudKit() {
        guard !cloudKitRecordID.isEmpty else { return }
        
        Task {
            do {
                let container = CKContainer.default()
                let database = container.privateCloudDatabase
                
                let recordID = CKRecord.ID(recordName: cloudKitRecordID)
                let record = try await database.record(for: recordID)
                
                record["likes"] = likes
                record["dislikes"] = dislikes
                
                let _ = try await database.save(record)
                logger.info("Successfully synced likes/dislikes to CloudKit for tip")
                
            } catch {
                logger.error("Failed to sync likes/dislikes to CloudKit: \(error.localizedDescription)")
            }
        }
    }
    
    /// Creates a new UserTip with CloudKit sync
    /// - Parameters:
    ///   - text: The tip text content
    ///   - spot: The spot this tip belongs to
    ///   - context: The Core Data context
    /// - Returns: The created UserTip instance
    public static func create(text: String, spot: Spot, in context: NSManagedObjectContext) -> UserTip {
        let userTip = UserTip(context: context)
        userTip.text = text
        userTip.spot = spot
        userTip.timestamp = Date()
        userTip.likes = 0
        userTip.dislikes = 0
        userTip.cloudKitRecordID = "" // CloudKit will generate this
        
        // Upload to CloudKit
        Task {
            await userTip.uploadToCloudKit()
        }
        
        return userTip
    }
    
    /// Uploads the tip to CloudKit
    private func uploadToCloudKit() async {
        do {
            // Create CloudKit record
            let recordID = CKRecord.ID(recordName: UUID().uuidString)
            let record = CKRecord(recordType: "UserTip", recordID: recordID)
            record["text"] = text
            record["timestamp"] = timestamp
            record["likes"] = likes
            record["dislikes"] = dislikes
            record["spotID"] = spot?.cloudKitRecordID ?? ""
            
            // Upload to CloudKit
            let container = CKContainer.default()
            let database = container.privateCloudDatabase
            
            let _ = try await database.save(record)
            
            await MainActor.run {
                self.cloudKitRecordID = record.recordID.recordName
                try? self.managedObjectContext?.save()
            }
            
            logger.info("Successfully uploaded tip to CloudKit")
            
        } catch {
            logger.error("Failed to upload tip to CloudKit: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Validation Methods
    
    public override func validateForInsert() throws {
        try super.validateForInsert()
        try validateTip()
    }
    
    public override func validateForUpdate() throws {
        try super.validateForUpdate()
        try validateTip()
    }
    
    private func validateTip() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "UserTipValidation", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Tip text cannot be empty"])
        }
        
        guard text.count <= 500 else {
            throw NSError(domain: "UserTipValidation", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Tip text cannot exceed 500 characters"])
        }
        
        guard likes >= 0 else {
            throw NSError(domain: "UserTipValidation", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Likes cannot be negative"])
        }
        
        guard dislikes >= 0 else {
            throw NSError(domain: "UserTipValidation", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Dislikes cannot be negative"])
        }
    }
}
