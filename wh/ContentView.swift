//
//  ContentView.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import SwiftUI
import CoreData
import CoreLocation

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var discoveryService = SpotDiscoveryService()

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Spot.name, ascending: true)],
        animation: .default)
    private var spots: FetchedResults<Spot>

    var body: some View {
        NavigationView {
            VStack {
                if discoveryService.isDiscovering {
                    VStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text(discoveryService.discoveryProgress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                List {
                    ForEach(spots) { spot in
                        NavigationLink {
                            SpotDetailView(spot: spot)
                        } label: {
                            SpotRowView(spot: spot)
                        }
                    }
                    .onDelete(perform: deleteSpots)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem {
                    Button(action: discoverNearbySpots) {
                        Label("Discover Spots", systemImage: "location.magnifyingglass")
                    }
                    .disabled(discoveryService.isDiscovering)
                }
            }
            .navigationTitle("WorkHaven")
        }
    }

    private func discoverNearbySpots() {
        // For now, use a default location (San Francisco)
        // In a real app, you'd get the user's current location
        let defaultLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
        
        Task {
            let discoveredSpots = await discoveryService.discoverSpots(near: defaultLocation)
            print("Discovered \(discoveredSpots.count) spots")
        }
    }

    private func deleteSpots(offsets: IndexSet) {
        withAnimation {
            offsets.map { spots[$0] }.forEach(viewContext.delete)

            do {
                try viewContext.save()
            } catch {
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }
}

// MARK: - Supporting Views

struct SpotRowView: View {
    let spot: Spot
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spot.name)
                    .font(.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                
                Spacer()
                
                HStack(spacing: 4) {
                    ForEach(0..<Int(spot.wifiRating), id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }
            }
            
            Text(spot.address)
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Label(spot.noiseRating, systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if spot.outlets {
                    Label("Outlets", systemImage: "powerplug")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                Spacer()
                
                if let userRatings = spot.userRatings, userRatings.count > 0 {
                    Text("\(userRatings.count) reviews")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SpotDetailView: View {
    let spot: Spot
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(spot.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    
                    Text(spot.address)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Ratings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ratings")
                        .font(.headline)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text("WiFi")
                                .font(.subheadline)
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { index in
                                    Image(systemName: index < Int(spot.wifiRating) ? "star.fill" : "star")
                                        .foregroundColor(.yellow)
                                }
                                Text("(\(spot.wifiRating)/5)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing) {
                            Text("Noise Level")
                                .font(.subheadline)
                            Text(spot.noiseRating)
                                .font(.subheadline)
                                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        }
                    }
                    
                    HStack {
                        Label("Electrical Outlets", systemImage: "powerplug")
                            .foregroundColor(spot.outlets ? .green : .red)
                        Spacer()
                    }
                }
                
                // Tips
                if !spot.tips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tips")
                            .font(.headline)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        
                        Text(spot.tips)
                            .font(.body)
                            .padding()
                            .background(ThemeManager.SwiftUIColors.latte)
                            .cornerRadius(8)
                    }
                }
                
                // User Ratings
                if let userRatings = spot.userRatings, userRatings.count > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("User Reviews (\(userRatings.count))")
                            .font(.headline)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        
                        ForEach(Array(userRatings) as! [UserRating], id: \.objectID) { rating in
                            UserRatingView(rating: rating)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct UserRatingView: View {
    let rating: UserRating
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WiFi: \(rating.wifiRatingDescription)")
                    .font(.caption)
                Spacer()
                Text("Noise: \(rating.noise)")
                    .font(.caption)
                if rating.plugs {
                    Image(systemName: "powerplug")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            
            if !rating.tip.isEmpty {
                Text(rating.tip)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

private let itemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

#Preview {
    ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
