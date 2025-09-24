//
//  SpotDetailView.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import SwiftUI
import MapKit
import CoreLocation
import OSLog

/**
 * SpotDetailView displays comprehensive information about a selected work spot
 * including location details, amenities, user ratings, and interactive features
 */
struct SpotDetailView: View {
    
    // MARK: - Properties
    
    let spot: Spot
    let userLocation: CLLocation?
    
    @State private var showingMap = false
    @State private var showingRatingSheet = false
    @State private var showingShareSheet = false
    @State private var showingDirections = false
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotDetailView")
    
    // MARK: - Computed Properties
    
    private var distance: String {
        guard let userLocation = userLocation else {
            return "Distance unknown"
        }
        
        let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
        let distanceInMiles = userLocation.distance(from: spotLocation) / 1609.34 // Convert meters to miles
        
        if distanceInMiles < 0.1 {
            return "Less than 0.1 miles"
        } else {
            return String(format: "%.1f miles", distanceInMiles)
        }
    }
    
    private var overallRating: Double {
        // Calculate overall rating (50% aggregate + 50% user ratings)
        let aggregateRating = calculateAggregateRating()
        let userRatingAverage = calculateUserRatingAverage()
        
        if userRatingAverage > 0 {
            return (aggregateRating * 0.5) + (userRatingAverage * 0.5)
        } else {
            return aggregateRating
        }
    }
    
    // MARK: - Initialization
    
    init(spot: Spot, userLocation: CLLocation? = nil) {
        self.spot = spot
        self.userLocation = userLocation
    }
    
    // MARK: - Body
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.medium) {
                
                // Header Section
                headerSection
                
                // Rating Section
                ratingSection
                
                // Location Section
                locationSection
                
                // Amenities Section
                amenitiesSection
                
                // Tips Section
                tipsSection
                
                // User Ratings Section
                userRatingsSection
                
                // Action Buttons
                actionButtonsSection
                
                Spacer(minLength: 100) // Bottom padding for tab bar
            }
            .padding(ThemeManager.Spacing.medium)
        }
        .navigationTitle(spot.name)
        .navigationBarTitleDisplayMode(.large)
        .background(ThemeManager.SwiftUIColors.latte)
        .sheet(isPresented: $showingMap) {
            mapView
        }
        .sheet(isPresented: $showingRatingSheet) {
            ratingSheet
        }
        .sheet(isPresented: $showingShareSheet) {
            shareSheet
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.small) {
            Text(spot.name)
                .font(ThemeManager.SwiftUIFonts.title)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            Text(spot.address)
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
            
            HStack {
                Image(systemName: "location.fill")
                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                
                Text(distance)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.8))
            }
        }
        .padding(ThemeManager.Spacing.medium)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(ThemeManager.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .stroke(ThemeManager.SwiftUIColors.mocha.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Rating Section
    
    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.small) {
            HStack {
                Text("Overall Rating")
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Spacer()
                
                HStack(spacing: 4) {
                    ForEach(0..<5) { index in
                        Image(systemName: index < Int(overallRating) ? "star.fill" : "star")
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            .font(.system(size: 16))
                    }
                }
                
                Text(String(format: "%.1f", overallRating))
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            }
            
            if let userRatings = spot.userRatings?.allObjects as? [UserRating], !userRatings.isEmpty {
                Text("Based on \(userRatings.count) user rating\(userRatings.count == 1 ? "" : "s")")
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
            } else {
                Text("Based on aggregate data")
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
            }
        }
        .padding(ThemeManager.Spacing.medium)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(ThemeManager.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .stroke(ThemeManager.SwiftUIColors.mocha.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Location Section
    
    private var locationSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.small) {
            Text("Location")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            Text(spot.address)
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.8))
            
            Button(action: {
                showingMap = true
            }) {
                HStack {
                    Image(systemName: "map.fill")
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                    
                    Text("View on Map")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                }
            }
        }
        .padding(ThemeManager.Spacing.medium)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(ThemeManager.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .stroke(ThemeManager.SwiftUIColors.mocha.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Amenities Section
    
    private var amenitiesSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.small) {
            Text("Amenities")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            VStack(spacing: ThemeManager.Spacing.small) {
                amenityRow(
                    icon: "wifi",
                    title: "WiFi Quality",
                    rating: Int(spot.wifiRating),
                    color: ThemeManager.SwiftUIColors.coral
                )
                
                amenityRow(
                    icon: "speaker.wave.2",
                    title: "Noise Level",
                    value: spot.noiseRating,
                    color: noiseColor(spot.noiseRating)
                )
                
                amenityRow(
                    icon: "powerplug",
                    title: "Power Outlets",
                    value: spot.outlets ? "Available" : "Not Available",
                    color: spot.outlets ? .green : .red
                )
            }
        }
        .padding(ThemeManager.Spacing.medium)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(ThemeManager.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .stroke(ThemeManager.SwiftUIColors.mocha.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Tips Section
    
    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.small) {
            Text("Tips & Insights")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            Text(spot.tips)
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ThemeManager.Spacing.medium)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(ThemeManager.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .stroke(ThemeManager.SwiftUIColors.mocha.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - User Ratings Section
    
    private var userRatingsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.small) {
            HStack {
                Text("User Reviews")
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Spacer()
                
                Button("Add Review") {
                    showingRatingSheet = true
                }
                .font(ThemeManager.SwiftUIFonts.caption)
                .foregroundColor(ThemeManager.SwiftUIColors.coral)
            }
            
            if let userRatings = spot.userRatings?.allObjects as? [UserRating], !userRatings.isEmpty {
                ForEach(userRatings, id: \.objectID) { rating in
                    userRatingRow(rating)
                }
            } else {
                Text("No user reviews yet. Be the first to review!")
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.6))
                    .italic()
            }
        }
        .padding(ThemeManager.Spacing.medium)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(ThemeManager.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeManager.CornerRadius.medium)
                .stroke(ThemeManager.SwiftUIColors.mocha.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Action Buttons Section
    
    private var actionButtonsSection: some View {
        VStack(spacing: ThemeManager.Spacing.small) {
            Button(action: {
                showingDirections = true
            }) {
                HStack {
                    Image(systemName: "location.fill")
                    Text("Get Directions")
                }
                .frame(maxWidth: .infinity)
                .padding(ThemeManager.Spacing.medium)
                .background(ThemeManager.SwiftUIColors.coral)
                .foregroundColor(.white)
                .cornerRadius(ThemeManager.CornerRadius.medium)
            }
            
            HStack(spacing: ThemeManager.Spacing.small) {
                Button(action: {
                    showingShareSheet = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(ThemeManager.Spacing.medium)
                    .background(ThemeManager.SwiftUIColors.mocha.opacity(0.1))
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .cornerRadius(ThemeManager.CornerRadius.medium)
                }
                
                Button(action: {
                    showingRatingSheet = true
                }) {
                    HStack {
                        Image(systemName: "star.fill")
                        Text("Rate")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(ThemeManager.Spacing.medium)
                    .background(ThemeManager.SwiftUIColors.mocha.opacity(0.1))
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .cornerRadius(ThemeManager.CornerRadius.medium)
                }
            }
        }
    }
    
    // MARK: - Helper Views
    
    private func amenityRow(icon: String, title: String, rating: Int? = nil, value: String? = nil, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(title)
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            
            Spacer()
            
            if let rating = rating {
                HStack(spacing: 2) {
                    ForEach(0..<5) { index in
                        Image(systemName: index < rating ? "star.fill" : "star")
                            .foregroundColor(color)
                            .font(.system(size: 12))
                    }
                }
            } else if let value = value {
                Text(value)
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(color)
            }
        }
    }
    
    private func userRatingRow(_ rating: UserRating) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 2) {
                    ForEach(0..<5) { index in
                        Image(systemName: index < Int(rating.wifi) ? "star.fill" : "star")
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            .font(.system(size: 12))
                    }
                }
                
                Spacer()
                
                Text("WiFi: \(Int(rating.wifi))/5")
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.7))
            }
            
            if !rating.tip.isEmpty {
                Text(rating.tip)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ThemeManager.Spacing.small)
        .background(ThemeManager.SwiftUIColors.mocha.opacity(0.05))
        .cornerRadius(ThemeManager.CornerRadius.small)
    }
    
    // MARK: - Sheet Views
    
    private var mapView: some View {
        NavigationView {
            Map {
                Marker(spot.name, coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude))
            }
            .mapStyle(.standard)
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        showingMap = false
                    }
                }
            }
        }
    }
    
    private var ratingSheet: some View {
        // TODO: Implement rating sheet
        Text("Rating functionality coming soon!")
            .padding()
    }
    
    private var shareSheet: some View {
        // TODO: Implement share sheet
        Text("Share functionality coming soon!")
            .padding()
    }
    
    // MARK: - Helper Methods
    
    private func calculateAggregateRating() -> Double {
        let wifiScore = Double(spot.wifiRating) / 5.0
        let noiseScore = noiseRatingToScore(spot.noiseRating)
        let outletScore = spot.outlets ? 1.0 : 0.0
        
        return (wifiScore + noiseScore + outletScore) / 3.0 * 5.0
    }
    
    private func calculateUserRatingAverage() -> Double {
        guard let userRatings = spot.userRatings?.allObjects as? [UserRating], !userRatings.isEmpty else {
            return 0.0
        }
        
        let sum = userRatings.reduce(0) { $0 + Int($1.wifi) }
        return Double(sum) / Double(userRatings.count)
    }
    
    private func noiseRatingToScore(_ noise: String) -> Double {
        switch noise.lowercased() {
        case "low": return 5.0
        case "medium": return 3.0
        case "high": return 1.0
        default: return 3.0
        }
    }
    
    private func noiseColor(_ noise: String) -> Color {
        switch noise.lowercased() {
        case "low": return .green
        case "medium": return .orange
        case "high": return .red
        default: return .gray
        }
    }
}

// MARK: - Preview

#Preview {
    let context = PersistenceController.preview.container.viewContext
    let sampleSpot = Spot(context: context)
    sampleSpot.name = "Blue Bottle Coffee"
    sampleSpot.address = "150 Greenwich St, New York, NY 10007"
    sampleSpot.latitude = 40.7128
    sampleSpot.longitude = -74.0060
    sampleSpot.wifiRating = 5
    sampleSpot.noiseRating = "Medium"
    sampleSpot.outlets = true
    sampleSpot.tips = "Great coffee and strong WiFi make it ideal for productivity. Arrive early for the best seats."
    
    return NavigationView {
        SpotDetailView(spot: sampleSpot, userLocation: CLLocation(latitude: 40.7128, longitude: -74.0060))
    }
    .environment(\.managedObjectContext, context)
}
