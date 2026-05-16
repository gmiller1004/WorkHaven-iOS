//
//  SupabaseFavoritesService.swift
//  WorkHaven
//

import Foundation
import CoreData
import Supabase
import OSLog

/// Decoded with SupabaseJSON's snake_case → camelCase strategy (no manual CodingKeys).
private struct RemoteFavoriteRow: Codable, Sendable {
    let userId: UUID
    let spotId: UUID
    let createdAt: Date?
}

private struct FavoriteInsertPayload: Encodable {
    let userId: UUID
    let spotId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case spotId = "spot_id"
    }
}

enum SupabaseFavoritesError: LocalizedError {
    case notConfigured
    case missingUser
    case missingSpotCatalogId
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Community favorites are not available right now."
        case .missingUser:
            return "Could not verify your account. Try again in a moment."
        case .missingSpotCatalogId:
            return "This spot is not in the community catalog yet."
        case .syncFailed(let message):
            return message
        }
    }
}

@MainActor
final class SupabaseFavoritesService {

    static let shared = SupabaseFavoritesService()

    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SupabaseFavorites")
    private let persistenceController = PersistenceController.shared

    private init() {}

    func fetchMyFavoriteSpotIds() async throws -> [UUID] {
        guard AppConfig.isSupabaseConfigured else { throw SupabaseFavoritesError.notConfigured }

        await SupabaseAuthService.shared.ensureAnonymousSession()
        guard let userId = SupabaseAuthService.shared.userID else {
            throw SupabaseFavoritesError.missingUser
        }

        let client = try SupabaseClientProvider.shared.requireClient()
        let rows: [RemoteFavoriteRow] = try await client
            .from("favorites")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value

        return rows.map(\.spotId)
    }

    func addFavorite(spotId: UUID) async throws {
        guard AppConfig.isSupabaseConfigured else { throw SupabaseFavoritesError.notConfigured }

        await SupabaseAuthService.shared.ensureAnonymousSession()
        guard let userId = SupabaseAuthService.shared.userID else {
            throw SupabaseFavoritesError.missingUser
        }

        let client = try SupabaseClientProvider.shared.requireClient()
        let payload = FavoriteInsertPayload(userId: userId, spotId: spotId)

        try await client
            .from("favorites")
            .upsert(payload, onConflict: "user_id,spot_id")
            .execute()

        logger.info("Added favorite for spot \(spotId.uuidString)")
    }

    func removeFavorite(spotId: UUID) async throws {
        guard AppConfig.isSupabaseConfigured else { throw SupabaseFavoritesError.notConfigured }

        await SupabaseAuthService.shared.ensureAnonymousSession()
        guard let userId = SupabaseAuthService.shared.userID else {
            throw SupabaseFavoritesError.missingUser
        }

        let client = try SupabaseClientProvider.shared.requireClient()
        try await client
            .from("favorites")
            .delete()
            .eq("user_id", value: userId.uuidString)
            .eq("spot_id", value: spotId.uuidString)
            .execute()

        logger.info("Removed favorite for spot \(spotId.uuidString)")
    }

    /// Pulls remote favorites and merges into Core Data for the current user.
    func syncFavoritesToCoreData() async throws {
        guard AppConfig.isSupabaseConfigured else { return }

        let remoteSpotIds = try await fetchMyFavoriteSpotIds()
        let context = persistenceController.container.viewContext

        try syncFavorites(spotIds: remoteSpotIds, in: context)
        logger.info("Synced \(remoteSpotIds.count) favorites from Supabase")
    }

    func syncFavorites(spotIds: [UUID], in context: NSManagedObjectContext) throws {
        let remoteIdSet = Set(spotIds.map(\.uuidString))

        for spotId in spotIds {
            let spotRequest = Spot.fetchRequest()
            spotRequest.predicate = NSPredicate(format: "supabaseId == %@", spotId.uuidString)
            spotRequest.fetchLimit = 1

            guard let spot = try context.fetch(spotRequest).first else { continue }

            if !spot.isFavorited {
                _ = spot.addToFavorites(in: context)
            }
        }

        let favoriteRequest = UserFavorite.fetchRequest()
        let localFavorites = try context.fetch(favoriteRequest)

        for favorite in localFavorites {
            guard let spot = favorite.spot,
                  let supabaseId = spot.supabaseId,
                  AppConfig.isSupabaseConfigured else { continue }

            if !remoteIdSet.contains(supabaseId) {
                favorite.removeFavorite()
            }
        }

        if context.hasChanges {
            try context.save()
        }
    }

    func setFavorite(_ isFavorite: Bool, for spot: Spot, in context: NSManagedObjectContext) async throws {
        guard let spotIdString = spot.supabaseId,
              let spotId = UUID(uuidString: spotIdString) else {
            throw SupabaseFavoritesError.missingSpotCatalogId
        }

        if isFavorite {
            try await addFavorite(spotId: spotId)
            if !spot.isFavorited {
                _ = spot.addToFavorites(in: context)
            }
            FavoriteActivityMonitor.shared.markSpotSeen(spotId: spotId)
        } else {
            try await removeFavorite(spotId: spotId)
            spot.removeFromFavorites(in: context)
        }

        if context.hasChanges {
            try context.save()
        }
    }
}
