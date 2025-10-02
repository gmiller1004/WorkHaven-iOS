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
    @AppStorage("usesImperialUnits") private var usesImperialUnits: Bool = true
    @StateObject private var notificationManager = NotificationManager.shared
    
    @State private var showingMap = false
    @State private var showingImagePicker = false
    @State private var showingRatingForm = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isGeneratingShareCard = false
    
    // Photo gallery state
    @State private var showPhotoViewer = false
    @State private var selectedPhotoIndex = 0
    @State private var showFlagConfirmation = false
    @State private var flaggedPhoto: Photo?
    
    // User tips state
    @State private var newTipText = ""
    @State private var showTipConfirmation = false
    @State private var showAllTips = false
    
    // User rating form state
    @State private var wifiRating: Double = 3.0
    @State private var noiseLevel = "Medium"
    @State private var outletsAvailable = true
    @State private var userTip = ""
    
    // Favorite state
    @State private var isFavorited: Bool = false
    
    // Photo picker state
    @State private var selectedImage: UIImage?
    
    // CloudKit asset loading state
    @State private var loadedImages: [String: UIImage] = [:]
    @State private var loadingImages: Set<String> = []
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotDetailView")
    
    // MARK: - Favorite Methods
    
    /**
     * Toggles the favorite status of the spot
     */
    private func toggleFavorite() {
        if isFavorited {
            // Remove from favorites
            spot.removeFromFavorites(in: viewContext)
            isFavorited = false
            logger.info("Removed spot '\(spot.name)' from favorites")
        } else {
            // Add to favorites
            spot.addToFavorites(in: viewContext)
            isFavorited = true
            logger.info("Added spot '\(spot.name)' to favorites")
            
            // Schedule community update notification if enabled
            if UserDefaults.standard.bool(forKey: "CommunityUpdatesEnabled") {
                notificationManager.scheduleCommunityUpdate(for: spot, activityType: "favorite")
                logger.info("Scheduled community update notification for favorited spot")
            }
        }
        
        // Save changes to Core Data and CloudKit
        saveContext()
    }
    
    /**
     * Initializes the favorite status based on existing UserFavorite entities
     */
    private func initializeFavoriteStatus() {
        isFavorited = spot.isFavorited
        logger.debug("Initialized favorite status for '\(spot.name)': \(isFavorited)")
    }
    
    // MARK: - Share Methods
    
    /**
     * Shares the spot with context-aware content including share card and text
     */
    private func shareSpot() async {
        isGeneratingShareCard = true
        
        do {
            // Create share card as UIImage asynchronously
            let shareCardImage = try await createShareCardImageAsync()
            
            // Create share text with spot details and deep link
            let shareText = createShareText()
            
            // Prepare share items
            await MainActor.run {
                shareItems = [shareCardImage, shareText]
                showingShareSheet = true
                isGeneratingShareCard = false
            }
            
            logger.info("Prepared share content for spot: \(spot.name)")
            logger.info("Share card image size: \(shareCardImage.size.width) x \(shareCardImage.size.height)")
            logger.info("Share text length: \(shareText.count) characters")
            logger.info("Share text preview: \(String(shareText.prefix(100)))...")
            logger.info("Activity items count: \(shareItems.count)")
        } catch {
            await MainActor.run {
                logger.error("Failed to create share content: \(error.localizedDescription)")
                errorMessage = "Failed to create share content: \(error.localizedDescription)"
                showingError = true
                isGeneratingShareCard = false
            }
        }
    }
    
    /**
     * Creates a share card image from SwiftUI view asynchronously
     */
    private func createShareCardImageAsync() async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            let shareCardView = ShareCardView(spot: spot, distanceString: distanceString, rating: calculateOverallRating())
            
            let hostingController = UIHostingController(rootView: shareCardView)
            hostingController.view.backgroundColor = UIColor.clear
            
            // Set the size for the share card
            let targetSize = CGSize(width: 400, height: 300)
            hostingController.view.frame = CGRect(origin: .zero, size: targetSize)
            
            // Add to a temporary window for proper rendering
            let window = UIWindow(frame: CGRect(origin: .zero, size: targetSize))
            window.rootViewController = hostingController
            window.makeKeyAndVisible()
            
            // Force layout and wait for next run loop
            hostingController.view.layoutIfNeeded()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let renderer = UIGraphicsImageRenderer(size: targetSize)
                let image = renderer.image { context in
                    hostingController.view.drawHierarchy(in: hostingController.view.bounds, afterScreenUpdates: true)
                }
                
                // Clean up the temporary window
                window.isHidden = true
                window.rootViewController = nil
                
                continuation.resume(returning: image)
            }
        }
    }
    
    /**
     * Calculates the overall rating for a spot based on aggregate and user ratings
     */
    private func calculateOverallRating() -> Double {
        // Calculate aggregate rating (50% weight)
        let wifiNormalized = Double(spot.wifiRating)
        
        let noiseInverted: Double
        switch spot.noiseRating.lowercased() {
        case "low": noiseInverted = 5.0
        case "medium": noiseInverted = 3.0
        case "high": noiseInverted = 1.0
        default: noiseInverted = 3.0
        }
        
        let outlets = spot.outlets ? 5.0 : 1.0
        let aggregateRating = (wifiNormalized + noiseInverted + outlets) / 3.0
        
        // Calculate user rating average (50% weight)
        let userRatingAverage: Double
        if let userRatings = spot.userRatings, userRatings.count > 0 {
            let totalRating = userRatings.reduce(into: 0.0) { sum, rating in
                guard let userRating = rating as? UserRating else { return }
                let wifi = Double(userRating.wifi)
                let noise: Double
                switch userRating.noise.lowercased() {
                case "low": noise = 5.0
                case "medium": noise = 3.0
                case "high": noise = 1.0
                default: noise = 3.0
                }
                let outlets = userRating.plugs ? 5.0 : 1.0
                sum += (wifi + noise + outlets) / 3.0
            }
            userRatingAverage = totalRating / Double(userRatings.count)
        } else {
            userRatingAverage = 0.0
        }
        
        // Combine with 50/50 weighting and cap at 5 stars
        let combinedRating = userRatingAverage == 0 ? aggregateRating : (aggregateRating * 0.5) + (userRatingAverage * 0.5)
        return min(5.0, combinedRating)
    }

    /**
     * Creates share text with spot details and Universal Link
     */
    private func createShareText() -> String {
        // Create Universal Link using the specified format
        let universalLink = "https://nextsizzle.com/spot/\(spot.cloudKitRecordID.isEmpty ? "unknown" : spot.cloudKitRecordID)"
        
        // Format the share text exactly as specified
        let shareText = "\(spot.name) - \(distanceString) - \(spot.tips) - Discover your perfect work spot with WorkHaven! \(universalLink) #WorkHaven"
        
        return shareText
    }
    
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
                    headerSection
                    mapPreviewSection
                    directionsSection
                    ratingsSection
                    userRatingFormSection
                    tipsSection
                    userTipsSection
                    photoGallerySection
                }
                .padding()
            }
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Share Spot") {
                        Task {
                            await shareSpot()
                        }
                    }
                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                    .font(.custom("Avenir Next", size: 16))
                    .fontWeight(.medium)
                    .padding(.horizontal, ThemeManager.Spacing.sm)
                    .padding(.vertical, ThemeManager.Spacing.xs)
                    .background(ThemeManager.SwiftUIColors.latte)
                    .cornerRadius(ThemeManager.CornerRadius.small)
                    .disabled(isGeneratingShareCard)
                    .accessibilityLabel(isGeneratingShareCard ? "Share spot button, generating card" : "Share spot button")
                    .accessibilityHint("Share this work spot with others")
                }
                
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
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            } message: {
                Text(errorMessage)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            }
            .background(ThemeManager.SwiftUIColors.latte)
            .alert("Confirm Flag", isPresented: $showFlagConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Flag as Inappropriate", role: .destructive) {
                    flagPhoto()
                }
            } message: {
                Text("Are you sure you want to flag this photo as inappropriate? This action cannot be undone.")
            }
            .alert("Submit Tip", isPresented: $showTipConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Submit", role: .none) {
                    submitTip()
                }
            } message: {
                Text("Are you sure you want to submit this tip?")
            }
            .onAppear {
                initializeFavoriteStatus()
            }
        .sheet(isPresented: $showingShareSheet) {
            ActivityViewController(activityItems: shareItems)
        }
        .overlay(
            Group {
                if isGeneratingShareCard {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        
                        VStack(spacing: ThemeManager.Spacing.md) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: ThemeManager.SwiftUIColors.coral))
                                .scaleEffect(1.5)
                            
                            Text("Generating share card...")
                                .font(ThemeManager.SwiftUIFonts.body)
                                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        }
                        .padding(ThemeManager.Spacing.lg)
                        .background(ThemeManager.SwiftUIColors.latte)
                        .cornerRadius(ThemeManager.CornerRadius.medium)
                        .shadow(color: ThemeManager.SwiftUIColors.mocha.opacity(0.1), radius: 4, x: 0, y: 2)
                    }
                }
            }
        )
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack(spacing: ThemeManager.Spacing.sm) {
                // Type-specific icon
                Image(systemName: typeIcon)
                    .font(.system(size: 24))
                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                    .accessibilityHidden(true)
                
                Text(spot.name)
                    .font(ThemeManager.SwiftUIFonts.title)
                    .fontWeight(.bold)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .accessibilityLabel("\(spotTypeDescription), \(spot.name), header icon")
                
                Spacer()
                
                // Favorite button
                Button(action: {
                    toggleFavorite()
                }) {
                    Image(systemName: isFavorited ? "heart.fill" : "heart")
                        .font(.system(size: 24))
                        .foregroundColor(isFavorited ? ThemeManager.SwiftUIColors.coral : .gray)
                }
                .accessibilityLabel(isFavorited ? "Remove from favorites" : "Add to favorites")
                .accessibilityHint("Tap to \(isFavorited ? "unfavorite" : "favorite") this spot")
            }
            
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
                    .accessibilityLabel("\(distanceString) from current location")
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
                Map(position: .constant(.region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )))) {
                    Annotation(
                        spot.name,
                        coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
                    ) {
                        VStack {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(ThemeManager.SwiftUIColors.coral)
                                .font(.title)
                            Text(spot.name)
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
    
    // MARK: - User Tips Section
    
    private var userTipsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("User Tips")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .accessibilityAddTraits(.isHeader)
            
            // Tip submission form
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                TextField("Add your tip...", text: $newTipText, axis: .vertical)
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .padding()
                    .background(ThemeManager.SwiftUIColors.latte)
                    .cornerRadius(8)
                    .lineLimit(3...6)
                    .accessibilityLabel("Tip text field")
                
                Button("Submit Tip") {
                    if !newTipText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showTipConfirmation = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeManager.SwiftUIColors.mocha)
                .foregroundColor(ThemeManager.SwiftUIColors.latte)
                .disabled(newTipText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Submit tip button")
            }
            
            // Display user tips
            if let userTips = spot.userTips as? Set<UserTip>, !userTips.isEmpty {
                let sortedTips = Array(userTips).sorted { tip1, tip2 in
                    let score1 = tip1.likes - tip1.dislikes
                    let score2 = tip2.likes - tip2.dislikes
                    return score1 > score2
                }
                
                let displayedTips = showAllTips ? sortedTips : Array(sortedTips.prefix(5))
                
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                    ForEach(Array(displayedTips.enumerated()), id: \.element.objectID) { index, tip in
                        userTipRow(tip: tip, index: index)
                    }
                    
                    if sortedTips.count > 5 {
                        Button(showAllTips ? "Show Less" : "Show More") {
                            showAllTips.toggle()
                        }
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                        .accessibilityLabel(showAllTips ? "Show less tips button" : "Show more tips button")
                    }
                }
            } else {
                Text("No user tips yet. Be the first to add one!")
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .italic()
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(ThemeManager.SwiftUIColors.latte)
                    .cornerRadius(8)
                    .accessibilityLabel("No user tips available")
            }
        }
        .onTapGesture {
            // Dismiss keyboard when tapping anywhere outside the text field
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
        Map(position: .constant(.region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )))) {
                Annotation(
                    spot.name,
                    coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
                ) {
                    VStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            .font(.title)
                        Text(spot.name)
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
    
    private var imagePickerView: some View {
        ImagePicker(selectedImage: $selectedImage, allowsEditing: true) { image in
            savePhoto(image)
        }
    }
    
    private var ratingFormView: some View {
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
        let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)
        let userLocation = locationService.currentLocation ?? fallbackLocation
        
        if locationService.currentLocation == nil {
            logger.debug("userLocation nil for spot \(spot.name), using fallback.")
        }
        
        let spotLocation = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
        let distanceInMeters = userLocation.distance(from: spotLocation)
        
        return formatDistance(distanceInMeters)
    }
    
    /**
     * Formats distance for display with unit conversion based on user preference
     */
    private func formatDistance(_ distance: Double) -> String {
        if usesImperialUnits {
            // Convert to miles
            let miles = distance / 1609.34
            return String(format: "%.1f mi", miles)
        } else {
            // Convert to kilometers
            let kilometers = distance / 1000
            return String(format: "%.1f km", kilometers)
        }
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
    
    // MARK: - User Tips Helper Methods
    
    private func userTipRow(tip: UserTip, index: Int) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
            HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
                    Text(tip.text)
                        .font(ThemeManager.SwiftUIFonts.body)
                        .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: ThemeManager.Spacing.sm) {
                        Text(tip.likesDislikesString)
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        
                        Text("•")
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        
                        Text(tip.formattedTimestamp)
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    }
                }
                
                Spacer()
                
                HStack(spacing: ThemeManager.Spacing.sm) {
                    Button(action: {
                        tip.addLike()
                        saveContext()
                    }) {
                        Image(systemName: "hand.thumbsup")
                            .font(.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                    }
                    .accessibilityLabel("Thumbs up button")
                    
                    Button(action: {
                        tip.addDislike()
                        saveContext()
                    }) {
                        Image(systemName: "hand.thumbsdown")
                            .font(.caption)
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                    }
                    .accessibilityLabel("Thumbs down button")
                }
            }
        }
        .padding(ThemeManager.Spacing.sm)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("User tip: \(tip.text), \(tip.likesDislikesString), thumbs up button, thumbs down button")
    }
    
    private func submitTip() {
        let trimmedText = newTipText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        do {
            let userTip = UserTip.create(text: trimmedText, spot: spot, in: viewContext)
            spot.addToUserTips(userTip)
            
            try viewContext.save()
            logger.info("Successfully submitted tip: \(trimmedText)")
            
            // Clear the text field
            newTipText = ""
            
        } catch {
            logger.error("Failed to submit tip: \(error.localizedDescription)")
            showError("Failed to submit tip: \(error.localizedDescription)")
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
                                    .font(.system(size: 24))
                                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            }
                            .accessibilityLabel("Thumbs down")
                            
                            Spacer()
                            
                            // Thumbs up button
                            Button(action: {
                                onLike(photos[selectedIndex])
                            }) {
                                Image(systemName: "hand.thumbsup.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            }
                            .accessibilityLabel("Thumbs up")
                            
                            Spacer()
                            
                            // Flag button
                            Button(action: {
                                onFlag(photos[selectedIndex])
                            }) {
                                Image(systemName: "flag.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                            }
                            .accessibilityLabel("Flag as inappropriate")
                        }
                        .padding(.horizontal, ThemeManager.Spacing.lg)
                        .padding(.bottom, ThemeManager.Spacing.xl)
                    }
                }
            )
    }
    
    // MARK: - Helper Views
    
    private func photoView(photo: Photo, index: Int) -> some View {
        ZStack {
            if let image = loadedImages[photo.photoAsset ?? ""] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        VStack {
                            if loadingImages.contains(photo.photoAsset ?? "") {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)
                            } else {
                                Image(systemName: "photo")
                                    .font(.system(size: 48))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                    )
                    .onAppear {
                        loadImageFromCloudKit(photo: photo)
                    }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func loadImageFromCloudKit(photo: Photo) {
        guard let photoAsset = photo.photoAsset, !photoAsset.isEmpty else { return }
        
        // Check if already loaded
        if loadedImages[photoAsset] != nil { return }
        
        // Check if already loading
        if loadingImages.contains(photoAsset) { return }
        
        loadingImages.insert(photoAsset)
        
        Task {
            do {
                let container = CKContainer.default()
                let database = container.privateCloudDatabase
                let recordID = CKRecord.ID(recordName: photoAsset)
                
                let record = try await database.record(for: recordID)
                
                if let asset = record["photoAsset"] as? CKAsset,
                   let fileURL = asset.fileURL,
                   let imageData = try? Data(contentsOf: fileURL),
                   let image = UIImage(data: imageData) {
                    
                    await MainActor.run {
                        loadedImages[photoAsset] = image
                        loadingImages.remove(photoAsset)
                    }
                } else {
                    await MainActor.run {
                        loadingImages.remove(photoAsset)
                    }
                }
            } catch {
                logger.error("Failed to load image from CloudKit: \(error.localizedDescription)")
                await MainActor.run {
                    loadingImages.remove(photoAsset)
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

// MARK: - ShareCardView

/**
 * SwiftUI view for creating share card images
 */
struct ShareCardView: View {
    let spot: Spot
    let distanceString: String
    let rating: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            // Header with spot name - headline mocha #8B5E3C
            Text(spot.name)
                .font(.custom("Avenir Next", size: 20))
                .fontWeight(.bold)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .lineLimit(2)
            
            // Overall rating stars - coral #F28C38
            HStack(spacing: 4) {
                ForEach(0..<5) { index in
                    Image(systemName: index < Int(rating) ? "star.fill" : "star")
                        .font(.system(size: 16))
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                }
            }
            
            // Tip text - gray
            if !spot.tips.isEmpty && spot.tips != "No tips available" {
                Text(spot.tips)
                    .font(.custom("Avenir Next", size: 14))
                    .foregroundColor(.gray)
                    .lineLimit(3)
            }
            
            // AsyncImage from photoURL or placeholder
            AsyncImage(url: URL(string: spot.photoURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeManager.SwiftUIColors.latte)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.5))
                    )
            }
            .frame(height: 120)
            .cornerRadius(8)
        }
        .padding(ThemeManager.Spacing.sm)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(12)
        .shadow(color: ThemeManager.SwiftUIColors.mocha.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

// MARK: - ActivityViewController

/**
 * UIKit wrapper for UIActivityViewController to use in SwiftUI
 */
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        
        // Don't exclude any activity types - let system decide what's available
        controller.excludedActivityTypes = []
        
        // Add completion handler for debugging
        controller.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            if let error = error {
                print("Share error: \(error.localizedDescription)")
            } else if completed {
                print("Share completed with activity: \(activityType?.rawValue ?? "unknown")")
            } else {
                print("Share cancelled")
            }
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}