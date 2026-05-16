//
//  FavoritesListView.swift
//  WorkHaven
//

import SwiftUI
import CoreData
import CoreLocation
import OSLog

struct FavoritesListView: View {

    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject private var locationService = LocationService.shared

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Spot.name, ascending: true)],
        predicate: NSPredicate(format: "favorites.@count > 0"),
        animation: .default
    )
    private var favoritedSpots: FetchedResults<Spot>

    @State private var isSyncing = false
    @State private var syncError: String?

    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "FavoritesList")

    var body: some View {
        NavigationStack {
            Group {
                if favoritedSpots.isEmpty {
                    emptyState
                } else {
                    List(favoritedSpots, id: \.objectID) { spot in
                        NavigationLink {
                            SpotDetailView(spot: spot, locationService: locationService)
                        } label: {
                            FavoriteSpotRow(spot: spot, userLocation: locationService.currentLocation)
                        }
                        .listRowBackground(ThemeManager.SwiftUIColors.latte)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ThemeManager.SwiftUIColors.latte.ignoresSafeArea())
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await syncFavorites() }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isSyncing)
                    .accessibilityLabel("Sync favorites")
                }
            }
            .refreshable {
                await syncFavorites()
            }
            .task {
                await syncFavorites()
            }
            .alert("Couldn’t Sync Favorites", isPresented: Binding(
                get: { syncError != nil },
                set: { if !$0 { syncError = nil } }
            )) {
                Button("OK", role: .cancel) { syncError = nil }
            } message: {
                Text(syncError ?? "")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "heart")
                .font(.system(size: 48))
                .foregroundColor(ThemeManager.SwiftUIColors.coral.opacity(0.6))

            Text("No favorites yet")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)

            Text("Tap the heart on any work spot to save it here. Favorites sync across devices when you’re signed in.")
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, ThemeManager.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func syncFavorites() async {
        guard AppConfig.isSupabaseConfigured else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            await SupabaseAuthService.shared.ensureAnonymousSession()
            try await SupabaseFavoritesService.shared.syncFavoritesToCoreData()
            viewContext.refreshAllObjects()
            logger.info("Favorites list synced")
        } catch {
            // Keep showing local favorites; only surface sync issues when the list is empty.
            if favoritedSpots.isEmpty {
                syncError = UserFacingError.message(for: error, context: .general)
                    ?? error.localizedDescription
            }
            logger.warning("Favorites sync failed: \(error.localizedDescription)")
        }
    }
}

private struct FavoriteSpotRow: View {
    @ObservedObject var spot: Spot
    let userLocation: CLLocation?

    @AppStorage("usesImperialUnits") private var usesImperialUnits = true

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
            Text(spot.name)
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)

            Text(spot.address)
                .font(ThemeManager.SwiftUIFonts.caption)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.75))
                .lineLimit(2)

            HStack {
                if let stars = spot.communityStarRating {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { value in
                            Image(systemName: value <= Int(stars) ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        }
                        Text(String(format: "%.1f", stars))
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    }
                }

                Spacer()

                Text(distanceLabel)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
            }
        }
        .padding(.vertical, ThemeManager.Spacing.xs)
    }

    private var distanceLabel: String {
        let fallback = CLLocation(latitude: 37.7749, longitude: -122.4194)
        let from = userLocation ?? fallback
        let to = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
        let meters = from.distance(from: to)

        if usesImperialUnits {
            return String(format: "%.1f mi", meters / 1609.34)
        }
        return String(format: "%.1f km", meters / 1000)
    }
}
