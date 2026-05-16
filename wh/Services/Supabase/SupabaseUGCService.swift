//
//  SupabaseUGCService.swift
//  WorkHaven
//

import Foundation
import CoreData
import Supabase
import UIKit
import OSLog

struct RemoteSpotReview: Codable, Sendable, Identifiable {
    let id: UUID
    let spotId: UUID
    let userId: UUID
    let wifi: Int
    let noise: String
    let plugs: Bool
    let tip: String
    let createdAt: Date?
}

struct RemoteSpotTip: Codable, Sendable, Identifiable {
    let id: UUID
    let spotId: UUID
    let userId: UUID
    let text: String
    let likes: Int
    let dislikes: Int
    let createdAt: Date?
}

struct RemoteSpotPhoto: Codable, Sendable, Identifiable {
    let id: UUID
    let spotId: UUID
    let userId: UUID
    let storagePath: String
    let likes: Int
    let dislikes: Int
    let createdAt: Date?
}

/// Community UGC reads and writes (requires non-anonymous Supabase session).
@MainActor
final class SupabaseUGCService {
    
    static let shared = SupabaseUGCService()
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SupabaseUGC")
    private let persistenceController = PersistenceController.shared
    private let photoBucket = "spot-photos"
    
    private init() {}
    
    // MARK: - Reviews
    
    func fetchReviews(spotId: UUID) async throws -> [RemoteSpotReview] {
        let client = try SupabaseClientProvider.shared.requireClient()
        return try await client
            .from("spot_reviews")
            .select()
            .eq("spot_id", value: spotId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }
    
    func upsertReview(
        spotId: UUID,
        userId: UUID,
        wifi: Int,
        noise: String,
        plugs: Bool,
        tip: String
    ) async throws -> RemoteSpotReview {
        let client = try SupabaseClientProvider.shared.requireClient()
        let payload = SpotReviewPayload(
            spotId: spotId,
            userId: userId,
            wifi: wifi,
            noise: noise,
            plugs: plugs,
            tip: tip
        )
        
        let rows: [RemoteSpotReview] = try await client
            .from("spot_reviews")
            .upsert(payload, onConflict: "spot_id,user_id")
            .select()
            .execute()
            .value
        
        guard let review = rows.first else {
            throw SupabaseCommunityError.invalidResponse
        }
        
        logger.info("Upserted community review for spot \(spotId.uuidString)")
        return review
    }
    
    func syncReviewsToCoreData(_ reviews: [RemoteSpotReview], spot: Spot, in context: NSManagedObjectContext) throws {
        for review in reviews {
            let request = UserRating.fetchRequest()
            request.predicate = NSPredicate(format: "supabaseId == %@", review.id.uuidString)
            request.fetchLimit = 1
            
            let rating: UserRating
            if let existing = try context.fetch(request).first {
                rating = existing
            } else {
                rating = UserRating(context: context)
                rating.supabaseId = review.id.uuidString
                rating.spot = spot
            }
            
            rating.wifi = Int16(review.wifi)
            rating.noise = review.noise
            rating.plugs = review.plugs
            rating.tip = review.tip
        }
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    // MARK: - Tips
    
    func fetchTips(spotId: UUID) async throws -> [RemoteSpotTip] {
        let client = try SupabaseClientProvider.shared.requireClient()
        return try await client
            .from("spot_tips")
            .select()
            .eq("spot_id", value: spotId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }
    
    func insertTip(spotId: UUID, userId: UUID, text: String) async throws -> RemoteSpotTip {
        let client = try SupabaseClientProvider.shared.requireClient()
        let payload = SpotTipPayload(spotId: spotId, userId: userId, text: text)
        
        let rows: [RemoteSpotTip] = try await client
            .from("spot_tips")
            .insert(payload)
            .select()
            .execute()
            .value
        
        guard let tip = rows.first else {
            throw SupabaseCommunityError.invalidResponse
        }
        
        logger.info("Inserted community tip for spot \(spotId.uuidString)")
        return tip
    }
    
    func syncTipsToCoreData(_ tips: [RemoteSpotTip], spot: Spot, in context: NSManagedObjectContext) throws {
        for remote in tips {
            let request = UserTip.fetchRequest()
            request.predicate = NSPredicate(format: "supabaseId == %@", remote.id.uuidString)
            request.fetchLimit = 1
            
            let tip: UserTip
            if let existing = try context.fetch(request).first {
                tip = existing
            } else {
                tip = UserTip(context: context)
                tip.supabaseId = remote.id.uuidString
                tip.spot = spot
                tip.cloudKitRecordID = ""
            }
            
            tip.text = remote.text
            tip.likes = Int16(remote.likes)
            tip.dislikes = Int16(remote.dislikes)
            tip.timestamp = remote.createdAt ?? Date()
        }
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    // MARK: - Photos
    
    func fetchPhotos(spotId: UUID) async throws -> [RemoteSpotPhoto] {
        let client = try SupabaseClientProvider.shared.requireClient()
        return try await client
            .from("spot_photos")
            .select()
            .eq("spot_id", value: spotId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }
    
    func uploadPhoto(spotId: UUID, userId: UUID, image: UIImage) async throws -> RemoteSpotPhoto {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw SupabaseCommunityError.invalidResponse
        }
        
        let client = try SupabaseClientProvider.shared.requireClient()
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        
        try await client.storage
            .from(photoBucket)
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: "image/jpeg", upsert: false)
            )
        
        let payload = SpotPhotoPayload(spotId: spotId, userId: userId, storagePath: path)
        let rows: [RemoteSpotPhoto] = try await client
            .from("spot_photos")
            .insert(payload)
            .select()
            .execute()
            .value
        
        guard let photo = rows.first else {
            throw SupabaseCommunityError.invalidResponse
        }
        
        logger.info("Uploaded community photo for spot \(spotId.uuidString)")
        return photo
    }
    
    func publicPhotoURL(storagePath: String) throws -> URL {
        let client = try SupabaseClientProvider.shared.requireClient()
        return try client.storage.from(photoBucket).getPublicURL(path: storagePath)
    }
    
    func syncPhotosToCoreData(_ photos: [RemoteSpotPhoto], spot: Spot, in context: NSManagedObjectContext) throws {
        for remote in photos {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "supabaseId == %@", remote.id.uuidString)
            request.fetchLimit = 1
            
            let photo: Photo
            if let existing = try context.fetch(request).first {
                photo = existing
            } else {
                photo = Photo(context: context)
                photo.supabaseId = remote.id.uuidString
                photo.spot = spot
                photo.cloudKitRecordID = ""
                photo.timestamp = remote.createdAt ?? Date()
            }
            
            photo.photoAsset = remote.storagePath
            photo.likes = Int16(remote.likes)
            photo.dislikes = Int16(remote.dislikes)
        }
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    /// Loads community UGC for a spot into Core Data when Supabase is configured.
    func refreshCommunityContent(for spot: Spot) async {
        guard AppConfig.isSupabaseConfigured,
              let spotIdString = spot.supabaseId,
              let spotId = UUID(uuidString: spotIdString) else {
            return
        }
        
        let context = persistenceController.container.viewContext
        
        do {
            async let reviews = fetchReviews(spotId: spotId)
            async let tips = fetchTips(spotId: spotId)
            async let photos = fetchPhotos(spotId: spotId)
            
            try syncReviewsToCoreData(try await reviews, spot: spot, in: context)
            try syncTipsToCoreData(try await tips, spot: spot, in: context)
            try syncPhotosToCoreData(try await photos, spot: spot, in: context)
            
            logger.info("Synced community UGC for \(spot.name)")
        } catch {
            logger.warning("Failed to refresh community UGC: \(error.localizedDescription)")
        }
    }
}

// MARK: - API payloads

private struct SpotReviewPayload: Encodable, Sendable {
    let spotId: UUID
    let userId: UUID
    let wifi: Int
    let noise: String
    let plugs: Bool
    let tip: String
    
    enum CodingKeys: String, CodingKey {
        case spotId = "spot_id"
        case userId = "user_id"
        case wifi, noise, plugs, tip
    }
}

private struct SpotTipPayload: Encodable, Sendable {
    let spotId: UUID
    let userId: UUID
    let text: String
    
    enum CodingKeys: String, CodingKey {
        case spotId = "spot_id"
        case userId = "user_id"
        case text
    }
}

private struct SpotPhotoPayload: Encodable, Sendable {
    let spotId: UUID
    let userId: UUID
    let storagePath: String
    
    enum CodingKeys: String, CodingKey {
        case spotId = "spot_id"
        case userId = "user_id"
        case storagePath = "storage_path"
    }
}
