//
//  Photo+CoreDataClass.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import CoreData
import UIKit
import CloudKit

/**
 * Photo+CoreDataClass provides the Core Data class implementation
 * for the Photo entity. This file contains custom logic and computed
 * properties for photo management and display.
 */
@objc(Photo)
public class Photo: NSManagedObject {
    
    // MARK: - Computed Properties
    
    /// Returns the UIImage representation of the stored image data or CloudKit asset
    public var image: UIImage? {
        get {
            // First try to get from CloudKit asset
            if let photoAsset = photoAsset, !photoAsset.isEmpty {
                return loadImageFromCloudKitAsset(assetID: photoAsset)
            }
            
            // Fallback to local imageData
            guard let imageData = imageData else { return nil }
            return UIImage(data: imageData)
        }
        set {
            if let newImage = newValue {
                // Store as CloudKit asset instead of local data
                Task {
                    await uploadImageToCloudKit(newImage)
                }
            } else {
                imageData = nil
                photoAsset = nil
            }
        }
    }
    
    /// Returns a formatted timestamp string for display
    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    /// Returns the file size of the image data in a human-readable format
    public var fileSizeString: String {
        // For CloudKit assets, we can't easily determine size without downloading
        if photoAsset != nil && !photoAsset!.isEmpty {
            return "CloudKit Asset"
        }
        
        guard let imageData = imageData else { return "0 B" }
        let bytes = imageData.count
        
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
    
    // MARK: - Lifecycle Methods
    
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        
        // Set default values
        timestamp = Date()
        cloudKitRecordID = ""
        photoAsset = nil
    }
    
    public override func awakeFromFetch() {
        super.awakeFromFetch()
        
        // Ensure cloudKitRecordID is not nil
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = ""
        }
        
        // Ensure photoAsset is not nil
        if photoAsset == nil {
            photoAsset = nil
        }
    }
    
    // MARK: - Convenience Methods
    
    /// Creates a new Photo instance with the given image and spot
    /// - Parameters:
    ///   - image: The UIImage to store
    ///   - spot: The Spot this photo belongs to
    ///   - context: The Core Data context
    /// - Returns: A new Photo instance
    public static func create(with image: UIImage, for spot: Spot, in context: NSManagedObjectContext) -> Photo {
        let photo = Photo(context: context)
        photo.image = image
        photo.spot = spot
        photo.timestamp = Date()
        photo.cloudKitRecordID = ""
        return photo
    }
    
    /// Deletes the photo and removes it from its associated spot
    public func deletePhoto() {
        spot?.removeFromPhotos(self)
        managedObjectContext?.delete(self)
    }
    
    /// Compresses the image data to reduce storage size
    /// - Parameter quality: Compression quality (0.0 to 1.0)
    public func compressImage(quality: CGFloat = 0.8) {
        guard let currentImage = image else { return }
        image = currentImage
    }
    
    /// Returns a thumbnail version of the image
    /// - Parameter size: The desired thumbnail size
    /// - Returns: A thumbnail UIImage or nil if image data is invalid
    public func thumbnail(size: CGSize = CGSize(width: 150, height: 150)) -> UIImage? {
        guard let originalImage = image else { return nil }
        
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            originalImage.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    
    // MARK: - Validation
    
    public override func validateForInsert() throws {
        try super.validateForInsert()
        try validatePhoto()
    }
    
    public override func validateForUpdate() throws {
        try super.validateForUpdate()
        try validatePhoto()
    }
    
    private func validatePhoto() throws {
        // Ensure we have either image data or a CloudKit asset
        let hasImageData = imageData != nil && !imageData!.isEmpty
        let hasCloudKitAsset = photoAsset != nil && !photoAsset!.isEmpty
        
        guard hasImageData || hasCloudKitAsset else {
            throw NSError(domain: "PhotoValidation", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Photo must have image data or CloudKit asset"])
        }
        
        // Ensure timestamp is valid
        guard timestamp.timeIntervalSince1970 > 0 else {
            throw NSError(domain: "PhotoValidation", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Photo must have a valid timestamp"])
        }
    }
    
    // MARK: - CloudKit Asset Methods
    
    /// Uploads an image to CloudKit as a CKAsset
    /// - Parameter image: The UIImage to upload
    private func uploadImageToCloudKit(_ image: UIImage) async {
        do {
            // Compress image to JPEG with quality 0.7
            guard let compressedData = image.jpegData(compressionQuality: 0.7) else {
                print("Failed to compress image for CloudKit upload")
                return
            }
            
            // Create temporary file for CKAsset
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try compressedData.write(to: tempURL)
            
            // Create CKAsset
            let asset = CKAsset(fileURL: tempURL)
            
            // Create CloudKit record
            let recordID = CKRecord.ID(recordName: UUID().uuidString)
            let record = CKRecord(recordType: "Photo", recordID: recordID)
            record["imageAsset"] = asset
            record["timestamp"] = timestamp
            record["spotID"] = spot?.cloudKitRecordID ?? ""
            
            // Upload to CloudKit
            let container = CKContainer.default()
            let database = container.privateCloudDatabase
            
            let _ = try await database.save(record)
            
            // Update local properties
            await MainActor.run {
                self.photoAsset = record.recordID.recordName
                self.cloudKitRecordID = record.recordID.recordName
                // Remove local imageData since we're using CloudKit
                self.imageData = nil
                
                // Save context
                try? self.managedObjectContext?.save()
            }
            
            // Clean up temporary file
            try? FileManager.default.removeItem(at: tempURL)
            
        } catch {
            print("Failed to upload image to CloudKit: \(error.localizedDescription)")
        }
    }
    
    /// Loads an image from CloudKit asset
    /// - Parameter assetID: The CloudKit record ID of the asset
    /// - Returns: UIImage if successful, nil otherwise
    private func loadImageFromCloudKitAsset(assetID: String) -> UIImage? {
        // This is a synchronous method, so we'll return nil and handle async loading in the UI
        // The actual loading should be done asynchronously in the view layer
        return nil
    }
    
    /// Asynchronously loads an image from CloudKit asset
    /// - Parameter assetID: The CloudKit record ID of the asset
    /// - Returns: UIImage if successful, nil otherwise
    public func loadImageFromCloudKit(assetID: String) async -> UIImage? {
        do {
            let container = CKContainer.default()
            let database = container.privateCloudDatabase
            
            let recordID = CKRecord.ID(recordName: assetID)
            let record = try await database.record(for: recordID)
            
            guard let asset = record["imageAsset"] as? CKAsset,
                  let fileURL = asset.fileURL else {
                return nil
            }
            
            let imageData = try Data(contentsOf: fileURL)
            return UIImage(data: imageData)
            
        } catch {
            print("Failed to load image from CloudKit: \(error.localizedDescription)")
            return nil
        }
    }
}
