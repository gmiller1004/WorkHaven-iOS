//
//  SupabaseCommunityService.swift
//  WorkHaven
//

import Foundation
import CoreData
import CoreLocation
import Supabase
import OSLog

enum SupabaseCommunityError: LocalizedError {
    case notConfigured
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Add SUPABASE_URL and SUPABASE_ANON_KEY to Secrets.xcconfig."
        case .invalidResponse:
            return "Unexpected response from Supabase."
        }
    }
}

/// Remote spot row from Supabase `spots` table / edge function.
struct RemoteSpot: Codable, Sendable {
    let id: UUID
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let type: String
    let wifiRating: Int
    let noiseRating: String
    let outlets: Bool
    let tips: String
    let enrichedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id, name, address, latitude, longitude, type, tips
        case wifiRating = "wifi_rating"
        case noiseRating = "noise_rating"
        case outlets
        case enrichedAt = "enriched_at"
    }
}

struct DiscoverEnrichRequest: Encodable, Sendable {
    let locations: [DiscoverLocationPayload]
}

struct DiscoverLocationPayload: Encodable, Sendable {
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let type: String
}

struct DiscoverEnrichResponse: Decodable, Sendable {
    let spots: [RemoteSpot]
}

/// Fetches community spots and syncs them into Core Data for existing UI.
@MainActor
final class SupabaseCommunityService {
    
    static let shared = SupabaseCommunityService()
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SupabaseCommunity")
    private let persistenceController = PersistenceController.shared
    
    private init() {}
    
    func fetchNearbySpots(
        near location: CLLocation,
        radiusMeters: Double = 32186.88
    ) async throws -> [RemoteSpot] {
        let client = try SupabaseClientProvider.shared.requireClient()
        
        let rows: [RemoteSpot] = try await client
            .rpc(
                "nearby_spots",
                params: NearbySpotsParams(
                    pLat: location.coordinate.latitude,
                    pLng: location.coordinate.longitude,
                    pRadiusMeters: radiusMeters
                )
            )
            .execute()
            .value
        
        logger.info("Fetched \(rows.count) community spots from Supabase")
        return rows
    }
    
    func discoverAndEnrich(locations: [DiscoverLocationPayload]) async throws -> [RemoteSpot] {
        let client = try SupabaseClientProvider.shared.requireClient()
        
        let response: DiscoverEnrichResponse = try await client.functions
            .invoke(
                "discover-enrich",
                options: FunctionInvokeOptions(
                    body: DiscoverEnrichRequest(locations: locations)
                )
            )
        
        logger.info("discover-enrich returned \(response.spots.count) spots")
        return response.spots
    }
    
    /// Merges remote spots into Core Data; returns local `Spot` entities for the UI.
    func syncToCoreData(remoteSpots: [RemoteSpot]) throws -> [Spot] {
        let context = persistenceController.container.viewContext
        var localSpots: [Spot] = []
        
        for remote in remoteSpots {
            let spot = try upsertSpot(remote, in: context)
            localSpots.append(spot)
        }
        
        if context.hasChanges {
            try context.save()
        }
        
        return localSpots
    }
    
    private func upsertSpot(_ remote: RemoteSpot, in context: NSManagedObjectContext) throws -> Spot {
        let request = Spot.fetchRequest()
        request.predicate = NSPredicate(format: "supabaseId == %@", remote.id.uuidString)
        request.fetchLimit = 1
        
        let spot: Spot
        if let existing = try context.fetch(request).first {
            spot = existing
        } else {
            spot = Spot(context: context)
            spot.supabaseId = remote.id.uuidString
            spot.cloudKitRecordID = remote.id.uuidString
        }
        
        spot.name = remote.name
        spot.address = remote.address
        spot.latitude = remote.latitude
        spot.longitude = remote.longitude
        spot.type = remote.type
        spot.wifiRating = Int16(remote.wifiRating)
        spot.noiseRating = remote.noiseRating
        spot.outlets = remote.outlets
        spot.tips = remote.tips
        spot.lastSeeded = remote.enrichedAt ?? Date()
        spot.lastModified = Date()
        spot.markAsModified()
        
        return spot
    }
}

private struct NearbySpotsParams: Encodable, Sendable {
    let pLat: Double
    let pLng: Double
    let pRadiusMeters: Double
    
    enum CodingKeys: String, CodingKey {
        case pLat = "p_lat"
        case pLng = "p_lng"
        case pRadiusMeters = "p_radius_meters"
    }
}
