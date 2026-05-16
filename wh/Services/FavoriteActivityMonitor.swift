//
//  FavoriteActivityMonitor.swift
//  WorkHaven
//

import Foundation
import CoreData
import Supabase
import OSLog

/// Polls Supabase for new tips and photos on favorited spots and fires local notifications.
@MainActor
final class FavoriteActivityMonitor {

    static let shared = FavoriteActivityMonitor()

    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "FavoriteActivity")
    private let defaults = UserDefaults.standard
    private let enabledKey = "CommunityUpdatesEnabled"

    private init() {}

    func markSpotSeen(spotId: UUID) {
        defaults.set(Date().timeIntervalSince1970, forKey: watermarkKey(spotId))
    }

    func checkForUpdates() async {
        guard defaults.bool(forKey: enabledKey) else { return }
        guard AppConfig.isSupabaseConfigured else { return }

        await SupabaseAuthService.shared.ensureAnonymousSession()
        guard let currentUserId = SupabaseAuthService.shared.userID else { return }

        do {
            let favoriteSpotIds = try await SupabaseFavoritesService.shared.fetchMyFavoriteSpotIds()
            guard !favoriteSpotIds.isEmpty else { return }

            let client = try SupabaseClientProvider.shared.requireClient()

            for spotId in favoriteSpotIds {
                let spotName = await spotDisplayName(spotId: spotId)
                let since = watermarkDate(for: spotId)

                if let tip = try await latestTip(
                    client: client,
                    spotId: spotId,
                    since: since,
                    excludingUserId: currentUserId
                ) {
                    NotificationManager.shared.scheduleCommunityUpdate(
                        forSpotName: spotName,
                        spotSupabaseId: spotId.uuidString,
                        activityType: "tip"
                    )
                    if let created = tip.createdAt {
                        defaults.set(created.timeIntervalSince1970, forKey: watermarkKey(spotId))
                    }
                }

                if let photo = try await latestPhoto(
                    client: client,
                    spotId: spotId,
                    since: since,
                    excludingUserId: currentUserId
                ) {
                    NotificationManager.shared.scheduleCommunityUpdate(
                        forSpotName: spotName,
                        spotSupabaseId: spotId.uuidString,
                        activityType: "photo"
                    )
                    if let created = photo.createdAt {
                        defaults.set(created.timeIntervalSince1970, forKey: watermarkKey(spotId))
                    }
                }
            }
        } catch {
            logger.warning("Favorite activity check failed: \(error.localizedDescription)")
        }
    }

    private func watermarkKey(_ spotId: UUID) -> String {
        "favoriteUGCWatermark_\(spotId.uuidString)"
    }

    private func watermarkDate(for spotId: UUID) -> Date {
        let interval = defaults.double(forKey: watermarkKey(spotId))
        if interval > 0 {
            return Date(timeIntervalSince1970: interval)
        }
        return Date.distantPast
    }

    private func spotDisplayName(spotId: UUID) async -> String {
        let context = PersistenceController.shared.container.viewContext
        let request = Spot.fetchRequest()
        request.predicate = NSPredicate(format: "supabaseId == %@", spotId.uuidString)
        request.fetchLimit = 1
        if let spot = try? context.fetch(request).first {
            return spot.name
        }
        return "a favorited spot"
    }

    private func latestTip(
        client: SupabaseClient,
        spotId: UUID,
        since: Date,
        excludingUserId: UUID
    ) async throws -> RemoteSpotTip? {
        let iso = iso8601String(since)
        let rows: [RemoteSpotTip] = try await client
            .from("spot_tips")
            .select()
            .eq("spot_id", value: spotId.uuidString)
            .gt("created_at", value: iso)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value

        return rows.first { $0.userId != excludingUserId }
    }

    private func latestPhoto(
        client: SupabaseClient,
        spotId: UUID,
        since: Date,
        excludingUserId: UUID
    ) async throws -> RemoteSpotPhoto? {
        let iso = iso8601String(since)
        let rows: [RemoteSpotPhoto] = try await client
            .from("spot_photos")
            .select()
            .eq("spot_id", value: spotId.uuidString)
            .gt("created_at", value: iso)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value

        return rows.first { $0.userId != excludingUserId }
    }

    private func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
