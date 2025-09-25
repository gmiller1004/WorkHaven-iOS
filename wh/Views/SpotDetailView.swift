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
import PhotosUI
import CloudKit

/**
 * SpotDetailView displays comprehensive information about a selected work spot
 * including location details, amenities, user ratings, photo gallery, and interactive features
 */
struct SpotDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) var dismiss
    @ObservedObject var spot: Spot
    @ObservedObject var locationService: LocationService
    
    @State private var showingMap = false
    @State private var showingImagePicker = false
    @State private var showingRatingForm = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    // Photo gallery state
    @State private var showPhotoViewer = false
    @State private var selectedPhotoIndex = 0
    @State private var showFlagConfirmation = false
    @State private var flaggedPhoto: Photo?
    
    // User rating form state
    @State private var wifiRating: Double = 3.0
    @State private var noiseLevel = "Medium"
    @State private var outletsAvailable = true
    @State private var userTip = ""
    
    // Photo picker state
    @State private var selectedImage: UIImage?
    
    // CloudKit asset loading state
    @State private var loadedImages: [String: UIImage] = [:]
    @State private var loadingImages: Set<String> = []
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotDetailView")
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
                    headerSection
                    mapPreviewSection
                    directionsSection
                    ratingsSection
                    userRatingFormSection
                    tipsSection
                    photoGallerySection
                }
                .padding()
            }
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                }
            }
            .background(ThemeManager.SwiftUIColors.latte)
            .sheet(isPresented: $showingMap) {
                mapView
            }
            .sheet(isPresented: $showingImagePicker) {
                imagePickerView
            }
            .sheet(isPresented: $showingRatingForm) {
                ratingFormView
            }
            .fullScreenCover(isPresented: $showPhotoViewer) {
                photoViewer
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .alert("Confirm Flag", isPresented: $showFlagConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Flag as Inappropriate", role: .destructive) {
                    flagPhoto()
                }
            } message: {
                Text("Are you sure you want to flag this photo as inappropriate? This action cannot be undone.")
            }
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text(spot.name)
                .font(ThemeManager.SwiftUIFonts.title)
                .fontWeight(.bold)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .accessibilityLabel("Spot name: \(spot.name)")
            
            Text(spot.address)
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(.gray)
                .accessibilityLabel("Address: \(spot.address)")
            
            HStack {
                Image(systemName: "location.fill")
                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                    .accessibilityHidden(true)
                Text(distanceString)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                    .accessibilityLabel("Distance: \(distanceString)")
            }
        }
    }
    
    // MARK: - Map Preview Section
    
    private var mapPreviewSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("Location")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .accessibilityAddTraits(.isHeader)
            
            Button(action: { showingMap = true }) {
                Map(coordinateRegion: .constant(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )), annotationItems: [MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude), title: spot.name)]) { item in
                    MapAnnotation(coordinate: item.coordinate) {
                        VStack {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                                .font(.title)
                            Text(item.title)
                                .font(.caption)
                                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                                .padding(.horizontal, 4)
                                .background(ThemeManager.SwiftUIColors.latte)
                                .cornerRadius(4)
                        }
                    }
                }
                .frame(height: 200)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(ThemeManager.SwiftUIColors.mocha.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Map preview for \(spot.name)")
        }
    }
    
    // MARK: - Directions Section
    
    private var directionsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Button("Get Directions") {
                openDirections()
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeManager.SwiftUIColors.mocha)
            .foregroundColor(ThemeManager.SwiftUIColors.latte)
            .accessibilityLabel("Get directions to \(spot.name)")
        }
    }
    
    // MARK: - Ratings Section
    
    private var ratingsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("Ratings")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .accessibilityAddTraits(.isHeader)
            
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                // WiFi Rating
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        .accessibilityHidden(true)
                    Text("WiFi:")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    HStack(spacing: 2) {
                        ForEach(0..<5) { index in
                            Image(systemName: index < Int(spot.wifiRating) ? "signal.3" : "signal.3")
                                .foregroundColor(index < Int(spot.wifiRating) ? ThemeManager.SwiftUIColors.coral : .gray)
                        }
                    }
                    .accessibilityLabel("WiFi rating: \(spot.wifiRating) out of 5")
                }
                
                // Noise Rating
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        .accessibilityHidden(true)
                    Text("Noise:")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    Text(spot.noiseRating)
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        .accessibilityLabel("Noise level: \(spot.noiseRating)")
                }
                
                // Outlets
                HStack {
                    Image(systemName: "powerplug.fill")
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        .accessibilityHidden(true)
                    Text("Outlets:")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    Text(spot.outlets ? "Available" : "Not Available")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        .accessibilityLabel("Outlets: \(spot.outlets ? "Available" : "Not Available")")
                }
                
                // Overall Rating
                HStack {
                    Text("Overall:")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    HStack(spacing: 2) {
                        ForEach(0..<5) { index in
                            Image(systemName: index < Int(overallRating) ? "star.fill" : "star")
                                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        }
                    }
                    Text(String(format: "%.1f", overallRating))
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        .accessibilityLabel("Overall rating: \(String(format: "%.1f", overallRating)) out of 5 stars")
                }
            }
        }
    }
    
    // MARK: - User Rating Form Section
    
    private var userRatingFormSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack {
                Text("Rate This Spot")
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .accessibilityAddTraits(.isHeader)
                
                Spacer()
                
                Button("Add Rating") {
                    showingRatingForm = true
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeManager.SwiftUIColors.mocha)
                .foregroundColor(ThemeManager.SwiftUIColors.latte)
                .accessibilityLabel("Add rating button")
            }
        }
    }
    
    // MARK: - Tips Section
    
    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("Tips & Insights")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .accessibilityAddTraits(.isHeader)
            
            Text(spot.tips)
                .font(ThemeManager.SwiftUIFonts.body)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .padding()
                .background(ThemeManager.SwiftUIColors.latte)
                .cornerRadius(8)
                .accessibilityLabel("Tips: \(spot.tips)")
        }
    }
    
    // MARK: - Photo Gallery Section
    
    private var photoGallerySection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack {
                Text("Photos")
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .accessibilityAddTraits(.isHeader)
                
                Spacer()
                
                Button("Upload Photo") {
                    showingImagePicker = true
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeManager.SwiftUIColors.mocha)
                .foregroundColor(ThemeManager.SwiftUIColors.latte)
                .accessibilityLabel("Upload photo button")
            }
            
            if let photos = spot.photos as? Set<Photo>, !photos.isEmpty {
                let sortedPhotos = Array(photos).sorted { photo1, photo2 in
                    let score1 = photo1.likes - photo1.dislikes
                    let score2 = photo2.likes - photo2.dislikes
                    return score1 > score2
                }
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ThemeManager.Spacing.sm) {
                        ForEach(Array(sortedPhotos.enumerated()), id: \.element.objectID) { index, photo in
                            photoThumbnailView(photo: photo)
                                .onTapGesture {
                                    selectedPhotoIndex = index
                                    showPhotoViewer = true
                                }
                        }
                    }
                    .padding(.horizontal)
                }
                .accessibilityLabel("Photo gallery with \(photos.count) image\(photos.count == 1 ? "" : "s")")
            } else {
                Text("No photos yet. Be the first to add one!")
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .italic()
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(ThemeManager.SwiftUIColors.latte)
                    .cornerRadius(8)
                    .accessibilityLabel("No photos available")
            }
        }
    }
    
    // MARK: - Sheet Views
    
    private var mapView: some View {
        NavigationView {
            Map(coordinateRegion: .constant(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )), annotationItems: [MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude), title: spot.name)]) { item in
                MapAnnotation(coordinate: item.coordinate) {
                    VStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            .font(.title)
                        Text(item.title)
                            .font(.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                            .padding(.horizontal, 4)
                            .background(ThemeManager.SwiftUIColors.latte)
                            .cornerRadius(4)
                    }
                }
            }
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
    
    private var imagePickerView: some View {
        ImagePicker(selectedImage: $selectedImage, allowsEditing: true) { image in
            savePhoto(image)
        }
    }
    
    private var ratingFormView: some View {
        NavigationView {
            Form {
                Section("WiFi Quality") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Rating: \(Int(wifiRating))")
                                .font(ThemeManager.SwiftUIFonts.body)
                            Spacer()
                            Text("\(Int(wifiRating))/5")
                                .font(ThemeManager.SwiftUIFonts.caption)
                                .foregroundColor(.gray)
                        }
                        Slider(value: $wifiRating, in: 0...5, step: 1)
                            .tint(ThemeManager.SwiftUIColors.coral)
                    }
                }
                
                Section("Noise Level") {
                    Picker("Noise Level", selection: $noiseLevel) {
                        Text("Low").tag("Low")
                        Text("Medium").tag("Medium")
                        Text("High").tag("High")
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Outlets") {
                    Toggle("Outlets Available", isOn: $outletsAvailable)
                        .tint(ThemeManager.SwiftUIColors.coral)
                }
                
                Section("Tips") {
                    TextField("Share your tips about this spot...", text: $userTip, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Rate This Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingRatingForm = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit") {
                        submitRating()
                    }
                    .disabled(userTip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    
    private var photoViewer: some View {
        PhotoViewer(
            photos: getSortedPhotos(),
            selectedIndex: $selectedPhotoIndex,
            onLike: { photo in
                photo.addLike()
                saveContext()
            },
            onDislike: { photo in
                photo.addDislike()
                saveContext()
            },
            onFlag: { photo in
                flaggedPhoto = photo
                showFlagConfirmation = true
            }
        )
    }
    
    // MARK: - Helper Methods
    
    private var distanceString: String {
        guard let userLocation = locationService.currentLocation else {
            logger.debug("userLocation nil for spot \(spot.name), using fallback.")
            let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
            let distance = spot.location.distance(from: fallbackLocation)
            return String(format: "%.1f miles", distance / 1609.34)
        }
        let distance = spot.location.distance(from: userLocation)
        return String(format: "%.1f miles", distance / 1609.34)
    }
    
    private var overallRating: Double {
        // Calculate overall rating using the same logic as SpotViewModel
        let wifiNormalized = Double(spot.wifiRating)
        
        let noiseInverted: Double
        switch spot.noiseRating.lowercased() {
        case "low": noiseInverted = 5.0
        case "medium": noiseInverted = 3.0
        case "high": noiseInverted = 1.0
        default: noiseInverted = 3.0
        }
        
        let outlets = spot.outlets ? 5.0 : 1.0
        let aggregateRating = min(5.0, (wifiNormalized + noiseInverted + outlets) / 3.0)
        
        // Calculate user rating average
        guard let userRatings = spot.userRatings, userRatings.count > 0 else {
            return round(aggregateRating * 2.0) / 2.0
        }
        
        let totalRating = userRatings.reduce(into: 0.0) { sum, rating in
            guard let userRating = rating as? UserRating else { return }
            
            let userWifi = Double(userRating.wifi)
            let userNoise: Double
            switch userRating.noise.lowercased() {
            case "low": userNoise = 5.0
            case "medium": userNoise = 3.0
            case "high": userNoise = 1.0
            default: userNoise = 3.0
            }
            let userOutlets = userRating.plugs ? 5.0 : 1.0
            
            let userAverage = min(5.0, (userWifi + userNoise + userOutlets) / 3.0)
            sum += userAverage
        }
        
        let userRatingAverage = min(5.0, totalRating / Double(userRatings.count))
        let combinedRating = (aggregateRating * 0.5) + (userRatingAverage * 0.5)
        return round(min(5.0, combinedRating) * 2.0) / 2.0
    }
    
    private func openDirections() {
        guard let userLocation = locationService.currentLocation else {
            showError("Location not available. Please enable location services.")
            return
        }
        
        let sourcePlacemark = MKPlacemark(coordinate: userLocation.coordinate)
        let destinationPlacemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude))
        
        let sourceMapItem = MKMapItem(placemark: sourcePlacemark)
        let destinationMapItem = MKMapItem(placemark: destinationPlacemark)
        destinationMapItem.name = spot.name
        
        MKMapItem.openMaps(with: [sourceMapItem, destinationMapItem], launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
    
    private func submitRating() {
        let userRating = UserRating(context: viewContext)
        userRating.wifi = Int16(wifiRating)
        userRating.noise = noiseLevel
        userRating.plugs = outletsAvailable
        userRating.tip = userTip.trimmingCharacters(in: .whitespacesAndNewlines)
        // UserRating doesn't have a timestamp property
        userRating.spot = spot
        
        do {
            try viewContext.save()
            logger.info("Successfully saved user rating for \(spot.name)")
            showingRatingForm = false
            resetRatingForm()
        } catch {
            logger.error("Failed to save user rating: \(error.localizedDescription)")
            showError("Failed to save rating: \(error.localizedDescription)")
        }
    }
    
    private func savePhoto(_ image: UIImage) {
        let photo = Photo(context: viewContext)
        photo.timestamp = Date()
        photo.spot = spot
        photo.cloudKitRecordID = ""
        
        // Set the image which will trigger CloudKit upload
        photo.image = image
        
        do {
            try viewContext.save()
            logger.info("Successfully saved photo for \(spot.name)")
        } catch {
            logger.error("Failed to save photo: \(error.localizedDescription)")
            showError("Failed to save photo: \(error.localizedDescription)")
        }
    }
    
    private func photoThumbnailView(photo: Photo) -> some View {
        Group {
            if let photoAsset = photo.photoAsset, !photoAsset.isEmpty {
                // CloudKit asset
                if let image = loadedImages[photoAsset] {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 120)
                        .clipped()
                        .cornerRadius(8)
                        .accessibilityLabel("Photo taken on \(photo.formattedTimestamp)")
                } else if loadingImages.contains(photoAsset) {
                    // Loading state
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ThemeManager.SwiftUIColors.latte)
                        .frame(width: 120, height: 120)
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: ThemeManager.SwiftUIColors.mocha))
                        )
                        .accessibilityLabel("Loading photo")
                } else {
                    // Load CloudKit asset
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ThemeManager.SwiftUIColors.latte)
                        .frame(width: 120, height: 120)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                                .font(.title2)
                        )
                        .onAppear {
                            loadCloudKitImage(photo: photo, assetID: photoAsset)
                        }
                        .accessibilityLabel("Photo taken on \(photo.formattedTimestamp)")
                }
            } else if let image = photo.image {
                // Local image data (fallback)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipped()
                    .cornerRadius(8)
                    .accessibilityLabel("Photo taken on \(photo.formattedTimestamp)")
            } else {
                // No image available
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeManager.SwiftUIColors.latte)
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                            .font(.title2)
                    )
                    .accessibilityLabel("Photo taken on \(photo.formattedTimestamp)")
            }
        }
    }
    
    private func loadCloudKitImage(photo: Photo, assetID: String) {
        guard !loadingImages.contains(assetID) else { return }
        
        loadingImages.insert(assetID)
        
        Task {
            if let image = await photo.loadImageFromCloudKit(assetID: assetID) {
                await MainActor.run {
                    loadedImages[assetID] = image
                    loadingImages.remove(assetID)
                }
            } else {
                await MainActor.run {
                    loadingImages.remove(assetID)
                }
            }
        }
    }
    
    private func resetRatingForm() {
        wifiRating = 3.0
        noiseLevel = "Medium"
        outletsAvailable = true
        userTip = ""
    }
    
    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
    
    private func getSortedPhotos() -> [Photo] {
        guard let photos = spot.photos as? Set<Photo> else { return [] }
        return Array(photos).sorted { photo1, photo2 in
            let score1 = photo1.likes - photo1.dislikes
            let score2 = photo2.likes - photo2.dislikes
            return score1 > score2
        }
    }
    
    private func saveContext() {
        do {
            try viewContext.save()
            logger.info("Successfully saved context")
        } catch {
            logger.error("Failed to save context: \(error.localizedDescription)")
            showError("Failed to save changes: \(error.localizedDescription)")
        }
    }
    
    private func flagPhoto() {
        guard let photo = flaggedPhoto else { return }
        
        Task {
            do {
                // Delete from CloudKit if it has a photoAsset
                if let photoAsset = photo.photoAsset, !photoAsset.isEmpty {
                    let container = CKContainer.default()
                    let database = container.privateCloudDatabase
                    let recordID = CKRecord.ID(recordName: photoAsset)
                    
                    try await database.deleteRecord(withID: recordID)
                    logger.info("Successfully deleted photo from CloudKit")
                }
                
                // Delete from Core Data
                await MainActor.run {
                    viewContext.delete(photo)
                    saveContext()
                    logger.info("Successfully flagged and deleted photo")
                }
            } catch {
                logger.error("Failed to flag photo: \(error.localizedDescription)")
                await MainActor.run {
                    showError("Failed to flag photo: \(error.localizedDescription)")
                }
            }
        }
        
        // Reset states
        flaggedPhoto = nil
        showFlagConfirmation = false
    }
}

// MARK: - Photo Viewer

struct PhotoViewer: View {
    let photos: [Photo]
    @Binding var selectedIndex: Int
    let onLike: (Photo) -> Void
    let onDislike: (Photo) -> Void
    let onFlag: (Photo) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var loadedImages: [String: UIImage] = [:]
    @State private var loadingImages: Set<String> = []
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "PhotoViewer")
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color.black
                    .ignoresSafeArea()
                
                if !photos.isEmpty {
                    TabView(selection: $selectedIndex) {
                        ForEach(Array(photos.enumerated()), id: \.element.objectID) { index, photo in
                            photoView(photo: photo, index: index)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    .ignoresSafeArea()
                } else {
                    Text("No photos available")
                        .foregroundColor(.white)
                        .font(ThemeManager.SwiftUIFonts.title)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !photos.isEmpty {
                        Button("Flag") {
                            onFlag(photos[selectedIndex])
                        }
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    }
                }
            }
            .overlay(
                // Bottom controls
                VStack {
                    Spacer()
                    
                    if !photos.isEmpty {
                        HStack(spacing: ThemeManager.Spacing.lg) {
                            // Thumbs down button
                            Button(action: {
                                onDislike(photos[selectedIndex])
                            }) {
                                Image(systemName: "hand.thumbsdown.fill")
                                    .font(.title2)
                                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            }
                            .accessibilityLabel("Thumbs down button")
                            
                            // Photo counter
                            Text("\(selectedIndex + 1) of \(photos.count)")
                                .font(ThemeManager.SwiftUIFonts.body)
                                .foregroundColor(.white)
                                .accessibilityLabel("Photo \(selectedIndex + 1) of \(photos.count)")
                            
                            // Thumbs up button
                            Button(action: {
                                onLike(photos[selectedIndex])
                            }) {
                                Image(systemName: "hand.thumbsup.fill")
                                    .font(.title2)
                                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            }
                            .accessibilityLabel("Thumbs up button")
                        }
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(ThemeManager.CornerRadius.medium)
                        .padding(.bottom, 50)
                    }
                }
            )
        }
    }
    
    private func photoView(photo: Photo, index: Int) -> some View {
        Group {
            if let photoAsset = photo.photoAsset, !photoAsset.isEmpty {
                // CloudKit asset
                if let image = loadedImages[photoAsset] {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .ignoresSafeArea()
                        .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                } else if loadingImages.contains(photoAsset) {
                    // Loading state
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(2.0)
                        .accessibilityLabel("Loading photo")
                } else {
                    // Load CloudKit asset
                    Rectangle()
                        .fill(Color.gray)
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(2.0)
                        )
                        .onAppear {
                            loadCloudKitImage(photo: photo, assetID: photoAsset)
                        }
                        .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                }
            } else if let image = photo.image {
                // Local image data (fallback)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
                    .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
            } else {
                // No image available
                Rectangle()
                    .fill(Color.gray)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.white)
                            .font(.largeTitle)
                    )
                    .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
            }
        }
    }
    
    private func loadCloudKitImage(photo: Photo, assetID: String) {
        guard !loadingImages.contains(assetID) else { return }
        
        loadingImages.insert(assetID)
        
        Task {
            if let image = await photo.loadImageFromCloudKit(assetID: assetID) {
                await MainActor.run {
                    loadedImages[assetID] = image
                    loadingImages.remove(assetID)
                }
            } else {
                await MainActor.run {
                    loadingImages.remove(assetID)
                }
            }
        }
    }
}

// MARK: - Image Picker

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    let allowsEditing: Bool
    let onImageSelected: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = allowsEditing
        picker.sourceType = .photoLibrary
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage {
                parent.onImageSelected(image)
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Map Annotation Item

struct MapAnnotationItem: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
}

// MARK: - Extensions

// MARK: - Previews

struct SpotDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let persistenceController = PersistenceController.preview
        let viewContext = persistenceController.container.viewContext
        
        // Create a sample spot
        let sampleSpot = Spot(context: viewContext)
        sampleSpot.name = "Sample Cafe"
        sampleSpot.address = "123 Coffee Lane, New York, NY"
        sampleSpot.latitude = 40.7128
        sampleSpot.longitude = -74.0060
        sampleSpot.wifiRating = 5
        sampleSpot.noiseRating = "Low"
        sampleSpot.outlets = true
        sampleSpot.tips = "Great coffee and cozy atmosphere. Perfect for remote work."
        sampleSpot.lastSeeded = Date()
        sampleSpot.cloudKitRecordID = "sample-record-id"
        
        // Add a sample user rating
        let sampleUserRating = UserRating(context: viewContext)
        sampleUserRating.wifi = 4
        sampleUserRating.noise = "Low"
        sampleUserRating.plugs = true
        sampleUserRating.tip = "Loved the ambiance and the strong espresso!"
        // UserRating doesn't have a timestamp property
        sampleUserRating.spot = sampleSpot
        
        // Add a sample photo
        let samplePhoto = Photo(context: viewContext)
        samplePhoto.image = UIImage(systemName: "photo.fill")
        samplePhoto.timestamp = Date()
        samplePhoto.spot = sampleSpot
        samplePhoto.cloudKitRecordID = "sample-photo-id"
        
        let userLocation = CLLocation(latitude: 40.7000, longitude: -74.0100)
        
        return SpotDetailView(spot: sampleSpot, locationService: LocationService.shared)
            .environment(\.managedObjectContext, viewContext)
    }
}