//
//  MapView.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import SwiftUI
import MapKit
import CoreLocation
import Combine
import OSLog

/**
 * MapView displays work spots on a MapKit map with comprehensive location information.
 * Features dynamic spot loading from SpotViewModel, user location integration, and "Search Here" functionality.
 * Uses @ObservedObject SpotViewModel for spots data and map state management.
 * Implements ThemeManager for consistent styling with coral annotation pins and latte background.
 */
struct MapView: View {
    
    // MARK: - Properties
    
    @ObservedObject var spotViewModel: SpotViewModel
    @ObservedObject private var locationService = LocationService.shared
    
    @State private var mapRegion: MKCoordinateRegion
    @State private var showingError = false
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "MapView")
    
    // MARK: - Initialization
    
    init(spotViewModel: SpotViewModel) {
        self.spotViewModel = spotViewModel
        
        // Initialize map region based on SpotViewModel's current region or fallback
        if let currentRegion = spotViewModel.currentMapRegion {
            self._mapRegion = State(initialValue: currentRegion)
        } else {
            let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
            self._mapRegion = State(initialValue: MKCoordinateRegion(
                center: fallbackLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
    }
    
    // MARK: - Computed Properties
    
    /**
     * Map annotations for each spot
     */
    private var mapAnnotations: [MapAnnotationItem] {
        return spotViewModel.spots.map { spot in
            MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude),
                title: spot.name
            )
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                ThemeManager.SwiftUIColors.latte
                    .ignoresSafeArea()
                
                if spotViewModel.spots.isEmpty && !spotViewModel.isSeeding {
                    // Empty state
                    emptyStateView
                } else {
                    // Map with spots
                    mapContent
                }
                
                // Location button overlay (top-right)
                VStack {
                    HStack {
                        Spacer()
                        
                        locationButton
                            .padding(.trailing, ThemeManager.Spacing.md)
                            .padding(.top, ThemeManager.Spacing.lg)
                    }
                    
                    Spacer()
                }
                
                // Search Here button overlay (bottom-center)
                VStack {
                    Spacer()
                    
                    HStack {
                        Spacer()
                        
                        searchHereButton
                            .padding(.trailing, ThemeManager.Spacing.md)
                            .padding(.bottom, ThemeManager.Spacing.lg)
                        
                        Spacer()
                    }
                }
                
                // Progress overlay when searching
                if spotViewModel.isSeeding {
                    progressOverlay
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.large)
            .background(ThemeManager.SwiftUIColors.latte)
            .onReceive(spotViewModel.$currentMapRegion) { newRegion in
                if let newRegion = newRegion {
                    mapRegion = newRegion
                }
            }
            .onChange(of: spotViewModel.errorMessage) { errorMessage in
                if errorMessage != nil {
                    showingError = true
                }
            }
            .alert("Search Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {
                    spotViewModel.clearError()
                }
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            } message: {
                Text(spotViewModel.errorMessage ?? "An error occurred while searching for spots")
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            }
        }
    }
    
    // MARK: - Views
    
    /**
     * Main map content with annotations
     */
    private var mapContent: some View {
        Map(coordinateRegion: $mapRegion, annotationItems: mapAnnotations) { annotation in
            MapAnnotation(coordinate: annotation.coordinate) {
                VStack(spacing: 2) {
                    // Custom annotation pin
                    ZStack {
                        // Pin background
                        Circle()
                            .fill(ThemeManager.SwiftUIColors.coral)
                            .frame(width: 30, height: 30)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        
                        // Pin icon based on spot type
                        Image(systemName: typeIcon(for: annotation))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                    }
                    
                    // Spot name label
                    Text(annotation.title)
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .fontWeight(.medium)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(ThemeManager.SwiftUIColors.latte)
                                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityLabel("Map showing \(spotViewModel.spots.count) spots")
        .accessibilityHint("Tap on pins to view spot details")
    }
    
    /**
     * Empty state when no spots are available
     */
    private var emptyStateView: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundColor(ThemeManager.SwiftUIColors.coral.opacity(0.6))
                .accessibilityHidden(true)
            
            Text("No Spots Available")
                .font(ThemeManager.SwiftUIFonts.title)
                .fontWeight(.semibold)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .accessibilityAddTraits(.isHeader)
            
            Text("Work spots will appear on the map once they're discovered in your area.")
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, ThemeManager.Spacing.lg)
                .accessibilityLabel("No work spots available. Spots will appear on the map once discovered in your area.")
        }
        .padding(ThemeManager.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .fill(Color.white)
                .shadow(
                    color: ThemeManager.SwiftUIColors.mocha.opacity(0.1),
                    radius: 4,
                    x: 0,
                    y: 2
                )
        )
        .padding(.horizontal, ThemeManager.Spacing.lg)
    }
    
    /**
     * Location button to recenter map on user location
     */
    private var locationButton: some View {
        Button(action: {
            recenterOnUserLocation()
        }) {
            Image(systemName: "location.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(ThemeManager.SwiftUIColors.latte)
                        .shadow(
                            color: ThemeManager.SwiftUIColors.mocha.opacity(0.2),
                            radius: 4,
                            x: 0,
                            y: 2
                        )
                )
        }
        .disabled(locationService.currentLocation == nil)
        .accessibilityLabel("Location button")
        .accessibilityHint("Center map on your current location")
    }
    
    /**
     * Search Here button overlay
     */
    private var searchHereButton: some View {
        Button(action: {
            searchHere()
        }) {
            HStack(spacing: ThemeManager.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                
                Text("Search Here")
                    .font(ThemeManager.SwiftUIFonts.body)
                    .fontWeight(.medium)
            }
            .foregroundColor(ThemeManager.SwiftUIColors.coral)
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.vertical, ThemeManager.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                    .fill(ThemeManager.SwiftUIColors.latte)
                    .shadow(
                        color: ThemeManager.SwiftUIColors.mocha.opacity(0.2),
                        radius: 4,
                        x: 0,
                        y: 2
                    )
            )
        }
        .disabled(spotViewModel.isSeeding)
        .accessibilityLabel("Search Here button")
        .accessibilityHint("Search for work spots at the current map location")
    }
    
    /**
     * Progress overlay when searching for spots
     */
    private var progressOverlay: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            ProgressView()
                .scaleEffect(1.2)
                .progressViewStyle(CircularProgressViewStyle(tint: ThemeManager.SwiftUIColors.coral))
            
            if !spotViewModel.discoveryProgress.isEmpty {
                Text(spotViewModel.discoveryProgress)
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .fill(ThemeManager.SwiftUIColors.latte)
                .shadow(
                    color: ThemeManager.SwiftUIColors.mocha.opacity(0.1),
                    radius: 4,
                    x: 0,
                    y: 2
                )
        )
        .accessibilityLabel("Searching for spots")
    }
    
    // MARK: - Helper Methods
    
    /**
     * Returns the appropriate icon for a spot type
     */
    private func typeIcon(for annotation: MapAnnotationItem) -> String {
        // Find the spot that matches this annotation
        guard let spot = spotViewModel.spots.first(where: { 
            $0.name == annotation.title && 
            $0.latitude == annotation.coordinate.latitude && 
            $0.longitude == annotation.coordinate.longitude 
        }) else {
            return "questionmark.circle.fill"
        }
        
        switch spot.type.lowercased() {
        case "coffee":
            return "cup.and.saucer.fill"
        case "park":
            return "tree.fill"
        case "library":
            return "book.fill"
        case "coworking":
            return "deskclock.fill"
        default:
            return "questionmark.circle.fill"
        }
    }
    
    /**
     * Recenters the map on the user's current location
     */
    private func recenterOnUserLocation() {
        guard let userLocation = locationService.currentLocation else {
            logger.warning("Cannot recenter map: user location not available")
            return
        }
        
        logger.info("Recenter button tapped, moving to user location: \(userLocation.coordinate.latitude), \(userLocation.coordinate.longitude)")
        
        // Update map region to center on user location
        withAnimation(.easeInOut(duration: 0.5)) {
            mapRegion = MKCoordinateRegion(
                center: userLocation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01) // Zoomed in view
            )
        }
        
        // Also update the SpotViewModel's map region for consistency
        spotViewModel.currentMapRegion = mapRegion
    }
    
    /**
     * Searches for spots at the current map center location with zoom-based radius
     */
    private func searchHere() {
        logger.info("Search Here button tapped at \(mapRegion.center.latitude), \(mapRegion.center.longitude) with span: \(mapRegion.span.latitudeDelta)")
        
        Task {
            await spotViewModel.searchHere(at: mapRegion.center, span: mapRegion.span, threshold: 5)
        }
    }
}


// MARK: - Preview

#Preview {
    MapView(spotViewModel: SpotViewModel())
}
