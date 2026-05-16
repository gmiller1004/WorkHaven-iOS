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
    case researchFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Add SUPABASE_URL and SUPABASE_ANON_KEY to Secrets.xcconfig."
        case .invalidResponse:
            return "Unexpected response from Supabase."
        case .researchFailed(let message):
            return message
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
    let outlets: Bool?
    let tips: String
    let enrichedAt: Date?
    let enrichmentSource: String?
    let enrichmentReviewCount: Int?
    let phone: String?
    let website: String?
}

struct DiscoverEnrichRequest: Encodable, Sendable {
    let locations: [DiscoverLocationPayload]?
    let spotIds: [UUID]?
    
    enum CodingKeys: String, CodingKey {
        case locations
        case spotIds = "spot_ids"
    }
}

struct ReEnrichSpotRequest: Encodable, Sendable {
    let spotIds: [UUID]
    
    enum CodingKeys: String, CodingKey {
        case spotIds = "spot_ids"
    }
}

struct DiscoverLocationPayload: Encodable, Sendable {
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let type: String
    let phone: String?
    let website: String?
    let poiCategory: String?
    let externalPlaceId: String?
    
    enum CodingKeys: String, CodingKey {
        case name
        case address
        case latitude
        case longitude
        case type
        case phone
        case website
        case poiCategory = "poi_category"
        case externalPlaceId = "external_place_id"
    }
}

struct ResearchSpotRequest: Encodable, Sendable {
    let spotId: UUID
    /// When true, edge function allows research even if community reviews exist.
    let fromProblemReport: Bool
    
    enum CodingKeys: String, CodingKey {
        case spotId = "spot_id"
        case fromProblemReport = "from_problem_report"
    }
    
    init(spotId: UUID, fromProblemReport: Bool = false) {
        self.spotId = spotId
        self.fromProblemReport = fromProblemReport
    }
}

struct ResearchSpotResponse: Decodable, Sendable {
    let spot: RemoteSpot?
    let error: String?
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
        
        do {
            let response: DiscoverEnrichResponse = try await client.functions.invoke(
                "discover-enrich",
                options: FunctionInvokeOptions(
                    body: DiscoverEnrichRequest(locations: locations, spotIds: nil)
                )
            )
            logger.info("discover-enrich returned \(response.spots.count) spots")
            return response.spots
        } catch {
            logger.error("discover-enrich decode failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Re-aggregates amenity fields from community reviews for one spot (no web search).
    func enrichSpotFromCommunity(spotId: UUID) async throws -> RemoteSpot? {
        let client = try SupabaseClientProvider.shared.requireClient()
        
        let response: DiscoverEnrichResponse = try await client.functions.invoke(
            "discover-enrich",
            options: FunctionInvokeOptions(
                body: ReEnrichSpotRequest(spotIds: [spotId])
            )
        )
        
        logger.info("Re-enriched spot \(spotId.uuidString) via \(response.spots.first?.enrichmentSource ?? "unknown")")
        return response.spots.first
    }
    
    /// On-demand web research via OpenRouter (edge function `research-spot`).
    func researchSpot(spotId: UUID, fromProblemReport: Bool = false) async throws -> RemoteSpot {
        let client = try SupabaseClientProvider.shared.requireClient()
        
        do {
            let response: ResearchSpotResponse = try await client.functions.invoke(
                "research-spot",
                options: FunctionInvokeOptions(
                    body: ResearchSpotRequest(
                        spotId: spotId,
                        fromProblemReport: fromProblemReport
                    )
                )
            )
            
            if let error = response.error, !error.isEmpty {
                throw SupabaseCommunityError.researchFailed(error)
            }
            
            guard let spot = response.spot else {
                throw SupabaseCommunityError.invalidResponse
            }
            
            logger.info("Web research completed for \(spotId.uuidString)")
            return spot
        } catch let researchError as SupabaseCommunityError {
            throw researchError
        } catch {
            throw SupabaseCommunityError.researchFailed(error.localizedDescription)
        }
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
        
        for remote in remoteSpots {
            CommunitySpotNotifications.postSpotUpdated(supabaseId: remote.id.uuidString)
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
        spot.tips = remote.tips
        spot.enrichmentSource = remote.enrichmentSource
        if remote.enrichmentSource == "baseline" {
            spot.outlets = nil
        } else if let outlets = remote.outlets {
            spot.outlets = NSNumber(value: outlets)
        } else {
            spot.outlets = nil
        }
        spot.phone = remote.phone
        spot.website = remote.website
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
