//
//  SpotListView.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import SwiftUI
import CoreLocation
import OSLog

/**
 * SpotListView displays a list of work spots with comprehensive information and ratings.
 * Features intelligent sorting, refresh capabilities, navigation to SpotDetailView, and accessibility support.
 * Uses @StateObject SpotViewModel for data management and @ObservedObject LocationService for user location.
 * Implements ThemeManager for consistent styling with Avenir Next fonts and proper spacing.
 */
struct SpotListView: View {
    
    // MARK: - Properties
    
    @ObservedObject var spotViewModel: SpotViewModel
    @ObservedObject private var locationService = LocationService.shared
    @State private var showingError = false
    @State private var searchText = ""
    @State private var sortOption: SortOption = .distance
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotListView")
    
    // MARK: - Sort Options
    
    enum SortOption: String, CaseIterable {
        case distance = "Distance"
        case rating = "Rating"
        case name = "Name"
    }
    
    // MARK: - Computed Properties
    
    /**
     * Filtered spots based on search text
     */
    private var filteredSpots: [Spot] {
        if searchText.isEmpty {
            return spotViewModel.spots
        }
        
        let searchLower = searchText.lowercased()
        return spotViewModel.spots.filter { spot in
            spot.name.lowercased().contains(searchLower) ||
            spot.address.lowercased().contains(searchLower)
        }
    }
    
    /**
     * Sorted spots based on selected sort option
     */
    private var sortedSpots: [Spot] {
        let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
        let userLocation = locationService.currentLocation ?? fallbackLocation
        
        if userLocation == locationService.currentLocation && locationService.currentLocation == nil {
            logger.info("DEBUG: userLocation nil for sorting, using fallback location")
        }
        
        switch sortOption {
        case .distance:
            return filteredSpots.sorted { spot1, spot2 in
                let location1 = CLLocation(latitude: spot1.latitude, longitude: spot1.longitude)
                let location2 = CLLocation(latitude: spot2.latitude, longitude: spot2.longitude)
                let distance1 = userLocation.distance(from: location1)
                let distance2 = userLocation.distance(from: location2)
                return distance1 < distance2
            }
        case .rating:
            return filteredSpots.sorted { spot1, spot2 in
                let tempViewModel = SpotViewModel()
                let rating1 = tempViewModel.calculateOverallRating(for: spot1)
                let rating2 = tempViewModel.calculateOverallRating(for: spot2)
                return rating1 > rating2
            }
        case .name:
            return filteredSpots.sorted { spot1, spot2 in
                spot1.name < spot2.name
            }
        }
    }
    
    // MARK: - Initialization
    
    /**
     * Initializes SpotListView with shared SpotViewModel instance
     * Uses @ObservedObject for shared state management
     */
    init(spotViewModel: SpotViewModel) {
        self.spotViewModel = spotViewModel
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                ThemeManager.SwiftUIColors.latte
                    .ignoresSafeArea()
                
                if spotViewModel.isSeeding {
                    // Progress view during loading with SpotDiscoveryService progress
                    VStack(spacing: ThemeManager.Spacing.md) {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(ThemeManager.SwiftUIColors.coral)
                        
                        Text(spotViewModel.discoveryProgress.isEmpty ? "Discovering work spots..." : spotViewModel.discoveryProgress)
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ThemeManager.Spacing.md)
                    }
                    .padding(ThemeManager.Spacing.md)
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
                } else if spotViewModel.spots.isEmpty {
                    // Empty state
                    emptyStateView
                } else if sortedSpots.isEmpty {
                    // No search results
                    noSearchResultsView
                } else {
                    // Search and sort controls with spots list
                    VStack(spacing: 0) {
                        // Search and sort controls
                        searchAndSortControls
                        
                        // Spots list
                        spotsList
                    }
                }
            }
            .navigationTitle("Work Spots")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    refreshButton
                }
            }
            .refreshable {
                await refreshSpots()
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {
                    spotViewModel.clearError()
                }
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            } message: {
                Text(spotViewModel.errorMessage ?? "An unknown error occurred")
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            }
            .background(ThemeManager.SwiftUIColors.latte)
            .onAppear {
                loadSpotsIfNeeded()
            }
        }
    }
    
    // MARK: - Views
    
    /**
     * Main spots list with refreshable functionality
     */
    private var spotsList: some View {
        List {
            ForEach(sortedSpots, id: \.objectID) { spot in
                        NavigationLink(destination: SpotDetailView(spot: spot, locationService: locationService)) {
                    SpotListRowView(spot: spot, userLocation: locationService.currentLocation)
                }
                .listRowBackground(ThemeManager.SwiftUIColors.latte)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: ThemeManager.Spacing.sm,
                    leading: ThemeManager.Spacing.md,
                    bottom: ThemeManager.Spacing.sm,
                    trailing: ThemeManager.Spacing.md
                ))
            }
        }
        .listStyle(PlainListStyle())
        .background(ThemeManager.SwiftUIColors.latte)
        .refreshable {
            await refreshSpots()
        }
    }
    
    /**
     * Refresh button in navigation bar
     */
    private var refreshButton: some View {
        Button(action: {
            Task {
                await refreshSpots()
            }
        }) {
            Image(systemName: "arrow.clockwise")
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
        }
        .accessibilityLabel("Refresh spots")
        .disabled(spotViewModel.isSeeding)
    }
    
    /**
     * Search field and sort picker controls
     */
    private var searchAndSortControls: some View {
        VStack(spacing: ThemeManager.Spacing.sm) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.6))
                    .font(ThemeManager.SwiftUIFonts.body)
                
                TextField("Search spots...", text: $searchText)
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .textFieldStyle(PlainTextFieldStyle())
                    .accessibilityLabel("Search spots field")
                
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.6))
                            .font(ThemeManager.SwiftUIFonts.body)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(ThemeManager.Spacing.sm)
            .background(ThemeManager.SwiftUIColors.latte)
            .cornerRadius(ThemeManager.CornerRadius.small)
            .overlay(
                RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.small)
                    .stroke(ThemeManager.SwiftUIColors.mocha.opacity(0.2), lineWidth: 1)
            )
            
            // Sort picker
            HStack {
                Text("Sort by:")
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Picker("Sort by", selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .accessibilityLabel("Sort by \(sortOption.rawValue) picker")
            }
        }
        .padding(.horizontal, ThemeManager.Spacing.md)
        .padding(.vertical, ThemeManager.Spacing.sm)
        .background(ThemeManager.SwiftUIColors.latte)
    }
    
    /**
     * Empty state when no spots are available
     */
    private var emptyStateView: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "location.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.6))
            
            Text("No work spots found")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            Text("Pull down to refresh or check your location settings")
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, ThemeManager.Spacing.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No work spots found. Pull down to refresh or check your location settings")
    }
    
    /**
     * No search results state
     */
    private var noSearchResultsView: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            // Search and sort controls
            searchAndSortControls
            
            VStack(spacing: ThemeManager.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.6))
                
                Text("No spots match your search")
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Text("Try adjusting your search terms or sort options")
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ThemeManager.Spacing.md)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No spots match your search. Try adjusting your search terms or sort options")
        }
    }
    
    // MARK: - Methods
    
    /**
     * Loads spots if user location is available
     * Note: ContentView handles initial spot loading with shared SpotViewModel
     */
    private func loadSpotsIfNeeded() {
        // ContentView handles spot loading with the shared SpotViewModel
        logger.info("SpotListView onAppear - spots will be loaded by ContentView")
    }
    
    /**
     * Refreshes spots with current user location
     */
    private func refreshSpots() async {
        guard let location = locationService.currentLocation else {
            logger.warning("Cannot refresh spots: no user location")
            return
        }
        
        await spotViewModel.refreshSpots(near: location)
        
        // Show error alert if needed
        if spotViewModel.errorMessage != nil {
            showingError = true
        }
    }
}

// MARK: - SpotRowView

/**
 * Individual spot row with comprehensive information display
 */
public struct SpotListRowView: View {
    public let spot: Spot
    public let userLocation: CLLocation?
    
    public init(spot: Spot, userLocation: CLLocation?) {
        self.spot = spot
        self.userLocation = userLocation
    }
    
    private var distance: Double {
        let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
        let locationToUse = userLocation ?? fallbackLocation
        
        if userLocation == nil {
            print("DEBUG: userLocation nil for spot \(spot.name), using fallback location")
        }
        
        let tempViewModel = SpotViewModel()
        let distance = tempViewModel.distanceToSpot(spot, from: locationToUse)
        return distance
    }
    
    private var overallRating: Double {
        // Create a temporary SpotViewModel to access rating calculation methods
        let tempViewModel = SpotViewModel()
        return tempViewModel.calculateOverallRating(for: spot)
    }
    
    /**
     * Returns the appropriate SF Symbol icon based on spot type
     */
    private var typeIcon: String {
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
    
    public var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            // Header with type icon, name and distance
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: ThemeManager.Spacing.sm) {
                        // Type-specific icon
                        Image(systemName: typeIcon)
                            .font(.system(size: 18))
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        
                        Text(spot.name)
                            .font(ThemeManager.SwiftUIFonts.headline)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                            .lineLimit(1)
                    }
                    
                    Text(spot.address)
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                        .lineLimit(2)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(SpotViewModel().formattedDistance(spot: spot, from: userLocation))
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                    
                    // Overall rating with stars
                    HStack(spacing: 2) {
                        ForEach(0..<5) { index in
                            Image(systemName: index < Int(overallRating) ? "star.fill" : "star")
                                .font(.system(size: 12))
                                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        }
                        Text(String(format: "%.1f", overallRating))
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
                    }
                }
            }
            
            // Rating indicators
            HStack(spacing: ThemeManager.Spacing.md) {
                // WiFi rating
                HStack(spacing: 2) {
                    Image(systemName: "wifi")
                        .font(.system(size: 14))
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.6))
                    
                    WiFiSignalBars(rating: Int(spot.wifiRating))
                }
                
                // Noise rating
                HStack(spacing: 2) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 14))
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.6))
                    
                    NoiseLevelIndicator(level: spot.noiseRating)
                }
                
                // Outlets indicator
                HStack(spacing: 2) {
                    Image(systemName: "powerplug")
                        .font(.system(size: 14))
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.6))
                    
                    Image(systemName: spot.outlets ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(spot.outlets ? ThemeManager.SwiftUIColors.coral : .red.opacity(0.6))
                }
                
                Spacer()
            }
            
            // Tips section
            if !spot.tips.isEmpty && spot.tips != "No tips available" {
                Text(spot.tips)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.8))
                    .padding(.top, 4)
                    .lineLimit(2)
            }
        }
        .padding(ThemeManager.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .fill(Color.white)
                .shadow(
                    color: ThemeManager.SwiftUIColors.mocha.opacity(0.1),
                    radius: 2,
                    x: 0,
                    y: 1
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
    
    /**
     * VoiceOver accessibility label
     */
    private var accessibilityLabel: String {
        let distanceText = SpotViewModel().formattedDistance(spot: spot, from: userLocation)
        let ratingText = String(format: "%.1f stars", overallRating)
        let wifiText = "\(Int(spot.wifiRating)) out of 5 WiFi"
        let noiseText = "\(spot.noiseRating) noise level"
        let outletsText = spot.outlets ? "has outlets" : "no outlets"
        let typeText = spotTypeDescription
        
        return "\(typeText), \(spot.name), \(distanceText), \(ratingText), \(wifiText), \(noiseText), \(outletsText)"
    }
    
    /**
     * Returns a human-readable description of the spot type
     */
    private var spotTypeDescription: String {
        switch spot.type.lowercased() {
        case "coffee":
            return "Coffee shop"
        case "park":
            return "Park"
        case "library":
            return "Library"
        case "coworking":
            return "Co-working space"
        default:
            return "Work spot"
        }
    }
}

// MARK: - WiFi Signal Bars

/**
 * Visual representation of WiFi signal strength
 */
struct WiFiSignalBars: View {
    let rating: Int
    
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5) { index in
                Rectangle()
                    .fill(barColor(for: index))
                    .frame(width: 3, height: barHeight(for: index))
                    .cornerRadius(1)
            }
        }
    }
    
    private func barColor(for index: Int) -> Color {
        return index < rating ? ThemeManager.SwiftUIColors.coral : Color.gray.opacity(0.3)
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [4, 6, 8, 10, 12]
        return heights[index]
    }
}

// MARK: - Noise Level Indicator

/**
 * Visual representation of noise level
 */
struct NoiseLevelIndicator: View {
    let level: String
    
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(circleColor(for: index))
                    .frame(width: 6, height: 6)
            }
        }
    }
    
    private func circleColor(for index: Int) -> Color {
        let levelIndex = noiseLevelIndex
        return index <= levelIndex ? ThemeManager.SwiftUIColors.coral : Color.gray.opacity(0.3)
    }
    
    private var noiseLevelIndex: Int {
        switch level.lowercased() {
        case "low": return 0
        case "medium": return 1
        case "high": return 2
        default: return 1
        }
    }
}

// MARK: - Coffee Steam Spinner

/**
 * Custom loading animation with coffee steam theme
 */
struct CoffeeSteamSpinner: View {
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 4) {
            // Coffee cup
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 24))
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            // Steam animation
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    SteamLine()
                        .animation(
                            Animation.easeInOut(duration: 1.0)
                                .repeatForever()
                                .delay(Double(index) * 0.2),
                            value: isAnimating
                        )
                }
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

/**
 * Individual steam line animation
 */
struct SteamLine: View {
    @State private var opacity: Double = 0.3
    @State private var yOffset: CGFloat = 0
    
    var body: some View {
        Rectangle()
            .fill(ThemeManager.SwiftUIColors.latte)
            .frame(width: 2, height: 20)
            .opacity(opacity)
            .offset(y: yOffset)
            .onAppear {
                withAnimation(
                    Animation.easeInOut(duration: 1.0)
                        .repeatForever()
                ) {
                    opacity = 0.8
                    yOffset = -10
                }
            }
    }
}

// MARK: - Preview

#Preview {
    SpotListView(spotViewModel: SpotViewModel())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
