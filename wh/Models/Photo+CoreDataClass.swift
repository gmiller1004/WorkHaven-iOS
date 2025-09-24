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

/**
 * Photo+CoreDataClass provides the Core Data class implementation
 * for the Photo entity. This file contains custom logic and computed
 * properties for photo management and display.
 */
@objc(Photo)
public class Photo: NSManagedObject {
    
    // MARK: - Computed Properties
    
    /// Returns the UIImage representation of the stored image data
    public var image: UIImage? {
        get {
            return UIImage(data: imageData)
        }
        set {
            if let newImage = newValue {
                imageData = newImage.jpegData(compressionQuality: 0.8) ?? Data()
            } else {
                imageData = Data()
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
    }
    
    public override func awakeFromFetch() {
        super.awakeFromFetch()
        
        // Ensure cloudKitRecordID is not nil
        if cloudKitRecordID.isEmpty {
            cloudKitRecordID = ""
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
        // Ensure image data is not empty
        guard !imageData.isEmpty else {
            throw NSError(domain: "PhotoValidation", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Photo must have image data"])
        }
        
        // Ensure timestamp is valid
        guard timestamp.timeIntervalSince1970 > 0 else {
            throw NSError(domain: "PhotoValidation", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Photo must have a valid timestamp"])
        }
    }
}
