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
    @ObservedObject private var authService = SupabaseAuthService.shared
    
    @State private var showingMap = false
    @State private var showingCommunitySignIn = false
    @State private var pendingCommunityAction: PendingCommunityAction?
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
    @State private var overallStarRating: Double = 4.0
    @State private var wifiRating: Double = 3.0
    @State private var noiseLevel = "Medium"
    @State private var outletsAvailable = true
    @State private var userTip = ""
    
    // Favorite state
    @State private var isFavorited: Bool = false
    @State private var isFavoriteBusy = false
    
    @State private var showingReportProblem = false
    @State private var showingReportSubmitted = false
    
    // Photo picker state
    @State private var selectedImage: UIImage?
    
    // CloudKit asset loading state
    @State private var loadedImages: [String: UIImage] = [:]
    @State private var loadingImages: Set<String> = []
    
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "SpotDetailView")
    
    private var usesCommunityBackend: Bool {
        AppConfig.isSupabaseConfigured && spot.supabaseId != nil
    }
    
    private enum PendingCommunityAction {
        case addRating
        case uploadPhoto
        case submitTip(String)
    }
    
    // MARK: - Favorite Methods
    
    /**
     * Toggles the favorite status of the spot (Core Data + Supabase when configured).
     */
    private func toggleFavorite() {
        guard !isFavoriteBusy else { return }
        let adding = !isFavorited
        Task { await toggleFavoriteAsync(adding: adding) }
    }

    @MainActor
    private func toggleFavoriteAsync(adding: Bool) async {
        isFavoriteBusy = true
        isFavorited = adding
        defer { isFavoriteBusy = false }

        do {
            if AppConfig.isSupabaseConfigured {
                try await SupabaseFavoritesService.shared.setFavorite(
                    adding,
                    for: spot,
                    in: viewContext
                )
            } else if adding {
                _ = spot.addToFavorites(in: viewContext)
                try viewContext.save()
            } else {
                spot.removeFromFavorites(in: viewContext)
                try viewContext.save()
            }
            isFavorited = spot.isFavorited
            logger.info("\(adding ? "Added" : "Removed") favorite for '\(spot.name)'")
        } catch {
            isFavorited = spot.isFavorited
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showError(message)
            logger.warning("Favorite toggle failed: \(message)")
        }
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
            let shareCardView = ShareCardView(
                spot: spot,
                distanceString: distanceString,
                rating: spot.communityStarRating ?? 0
            )
            
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
     * Creates share text with spot details and Universal Link
     */
    private func createShareText() -> String {
        // Create Universal Link using the specified format
        let spotID = spot.supabaseId ?? (spot.cloudKitRecordID.isEmpty ? "unknown" : spot.cloudKitRecordID)
        let universalLink = "https://nextsizzle.com/spot/\(spotID)"
        
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
                    communityReviewsSection
                    userRatingFormSection
                    spotSummarySection
                    userTipsSection
                    photoGallerySection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnTap()
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
                NavigationStack {
                    ratingFormView
                }
                .dismissKeyboardOnTap()
            }
            .sheet(isPresented: $showingReportProblem) {
                ReportProblemSheet(
                    spotName: spot.name,
                    allowsWebResearch: usesCommunityBackend && spot.supabaseId != nil,
                    onResearch: usesCommunityBackend && spot.supabaseId != nil
                        ? { try await researchSpotFromWeb(fromProblemReport: true) }
                        : nil,
                    onSubmit: { category, details in
                        try await submitProblemReport(category: category, details: details)
                        showingReportSubmitted = true
                    },
                    onCancel: { showingReportProblem = false }
                )
            }
            .sheet(isPresented: $showingCommunitySignIn) {
                CommunitySignInSheet(
                    featureTitle: communitySignInFeatureTitle,
                    onSignedIn: {
                        showingCommunitySignIn = false
                        resumePendingCommunityAction()
                    },
                    onCancel: {
                        showingCommunitySignIn = false
                        pendingCommunityAction = nil
                    }
                )
            }
            .fullScreenCover(isPresented: $showPhotoViewer) {
                photoViewer
            }
            .alert("Report Submitted", isPresented: $showingReportSubmitted) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Thanks for helping improve this listing. We'll review your report.")
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
                    let text = newTipText.trimmingCharacters(in: .whitespacesAndNewlines)
                    promptForCommunityWriteIfNeeded(.submitTip(text)) {
                        Task { await submitTip() }
                    }
                }
            } message: {
                Text("Are you sure you want to submit this tip?")
            }
            .onAppear {
                initializeFavoriteStatus()
                spot.normalizeOutletUnknownState()
                if viewContext.hasChanges {
                    try? viewContext.save()
                }
                Task {
                    await SupabaseUGCService.shared.refreshCommunityContent(for: spot)
                    viewContext.refreshAllObjects()
                }
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
                    Group {
                        if isFavoriteBusy {
                            ProgressView()
                        } else {
                            Image(systemName: isFavorited ? "heart.fill" : "heart")
                        }
                    }
                    .font(.system(size: 24))
                    .foregroundColor(isFavorited ? ThemeManager.SwiftUIColors.coral : .gray)
                }
                .disabled(isFavoriteBusy)
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
            
            if let phone = spot.phone, !phone.isEmpty,
               let phoneURL = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                Link(destination: phoneURL) {
                    Label(phone, systemImage: "phone.fill")
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                }
                .accessibilityLabel("Call \(phone)")
            }
            
            if let website = spot.website,
               let websiteURL = URL(string: website),
               websiteURL.scheme?.hasPrefix("http") == true {
                Link(destination: websiteURL) {
                    Label("Website", systemImage: "globe")
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                }
                .accessibilityLabel("Open website")
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
                if let stars = spot.communityStarRating {
                    HStack {
                        Text("Community rating:")
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        HStack(spacing: 2) {
                            ForEach(0..<5) { index in
                                Image(systemName: index < Int(stars) ? "star.fill" : "star")
                                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            }
                        }
                        Text(String(format: "%.1f", stars))
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        Text("(\(spot.communityRatingCount))")
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(.gray)
                    }
                    .accessibilityLabel("Community rating \(String(format: "%.1f", stars)) from \(spot.communityRatingCount) reviews")
                } else {
                    Text("No community star rating yet—be the first to rate this spot.")
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                }
                
                if spot.wifiKnown {
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            .accessibilityHidden(true)
                        Text("WiFi:")
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        WiFiSignalBars(rating: Int(spot.wifiRating))
                            .accessibilityLabel("WiFi rating: \(spot.wifiRating) out of 5")
                    }
                }
                
                if spot.noiseKnown {
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
                }
                
                if spot.outletsKnown {
                    HStack {
                        Image(systemName: outletsDetailIcon)
                            .foregroundColor(ThemeManager.SwiftUIColors.coral)
                            .accessibilityHidden(true)
                        Text("Outlets:")
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                        Text(spot.outletsDisplayLabel)
                            .font(ThemeManager.SwiftUIFonts.body)
                            .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                            .accessibilityLabel("Outlets: \(spot.outletsDisplayLabel)")
                    }
                }
            }
            
            communityActionsSection
        }
    }
    
    private var showReportButton: Bool {
        usesCommunityBackend && spot.supabaseId != nil
    }
    
    private var communityActionsFooter: String? {
        guard usesCommunityBackend else { return nil }
        return "Incorrect info? Report a problem—you can refresh amenities from the web there before submitting."
    }
    
    private var communityActionsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            if showReportButton {
                Button {
                    showingReportProblem = true
                } label: {
                    Label("Report a Problem", systemImage: "exclamationmark.bubble")
                        .font(ThemeManager.SwiftUIFonts.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeManager.SwiftUIColors.mocha)
                .accessibilityHint("Flag incorrect information or update this spot from web sources.")
            }
            
            if let footer = communityActionsFooter {
                Text(footer)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.75))
            }
        }
    }
    
    @MainActor
    private func submitProblemReport(category: SpotProblemCategory, details: String) async throws {
        guard let spotId = spot.supabaseId.flatMap(UUID.init(uuidString:)) else {
            throw SupabaseUGCError.problemReportFailed("This spot is not linked to the community catalog.")
        }
        try await SupabaseUGCService.shared.submitProblemReport(
            spotId: spotId,
            category: category,
            details: details
        )
    }
    
    @MainActor
    private func researchSpotFromWeb(fromProblemReport: Bool) async throws {
        guard let spotId = spot.supabaseId.flatMap(UUID.init(uuidString:)) else {
            throw SupabaseCommunityError.researchFailed(
                "This spot is not linked to the community catalog yet."
            )
        }
        
        let updated = try await SupabaseCommunityService.shared.researchSpot(
            spotId: spotId,
            fromProblemReport: fromProblemReport
        )
        _ = try SupabaseCommunityService.shared.syncToCoreData(remoteSpots: [updated])
        viewContext.refresh(spot, mergeChanges: true)
        viewContext.refreshAllObjects()
        CommunitySpotNotifications.postSpotUpdated(supabaseId: spotId.uuidString)
        logger.info("Web research completed for \(spot.name)")
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
                    promptForCommunityWriteIfNeeded(.addRating) {
                        showingRatingForm = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeManager.SwiftUIColors.mocha)
                .foregroundColor(ThemeManager.SwiftUIColors.latte)
                .accessibilityLabel("Add rating button")
            }
        }
    }
    
    // MARK: - Tips Section
    
    private var outletsDetailIcon: String {
        guard spot.outletsKnown, let outlets = spot.outlets else { return "questionmark.circle" }
        return outlets.boolValue ? "powerplug.fill" : "powerplug"
    }
    
    // MARK: - Community Reviews
    
    @ViewBuilder
    private var communityReviewsSection: some View {
        let reviews = spot.sortedCommunityReviews
        if !reviews.isEmpty {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                Text("Community Reviews")
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .accessibilityAddTraits(.isHeader)
                
                Text("Star ratings and optional notes from people who worked here.")
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.75))
                
                ForEach(reviews, id: \.objectID) { review in
                    communityReviewRow(review)
                }
            }
        }
    }
    
    private func communityReviewRow(_ review: UserRating) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.xs) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { value in
                    Image(systemName: value <= Int(review.stars) ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                }
                Spacer()
                Text(review.oneLineSummary)
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.8))
            }
            
            if review.hasTips {
                Text(review.formattedTip)
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeManager.SwiftUIColors.latte)
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            review.hasTips
                ? "\(Int(review.stars)) stars. \(review.oneLineSummary). \(review.formattedTip)"
                : "\(Int(review.stars)) stars. \(review.oneLineSummary)"
        )
    }
    
    private var enrichmentSourceCaption: String? {
        switch spot.enrichmentSource {
        case "community_reviews":
            return "Summary from aggregated community reviews"
        case "web_search":
            return "Summary from web research"
        case "baseline":
            return "Not yet researched—add a review or report a problem to update from the web"
        default:
            return nil
        }
    }
    
    @ViewBuilder
    private var spotSummarySection: some View {
        if spot.showsSpotSummary {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                Text("Spot Summary")
                    .font(ThemeManager.SwiftUIFonts.headline)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .accessibilityAddTraits(.isHeader)
                
                if let caption = enrichmentSourceCaption {
                    Text(caption)
                        .font(ThemeManager.SwiftUIFonts.caption)
                        .foregroundColor(ThemeManager.SwiftUIColors.coral)
                }
                
                Text(spot.tips)
                    .font(ThemeManager.SwiftUIFonts.body)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                    .padding()
                    .background(ThemeManager.SwiftUIColors.latte)
                    .cornerRadius(8)
                    .accessibilityLabel("Spot summary: \(spot.tips)")
            }
        }
    }
    
    // MARK: - User Tips Section
    
    private var userTipsSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("Quick Tips")
                .font(ThemeManager.SwiftUIFonts.headline)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                .accessibilityAddTraits(.isHeader)
            
            Text("Short standalone tips—separate from star ratings and review notes above.")
                .font(ThemeManager.SwiftUIFonts.caption)
                .foregroundColor(ThemeManager.SwiftUIColors.mocha.opacity(0.75))
            
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
                    promptForCommunityWriteIfNeeded(.uploadPhoto) {
                        showingImagePicker = true
                    }
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
        let canSubmit = overallStarRating >= 1
        
        return Form {
            Section {
                Text("Your star rating is separate from WiFi, noise, and outlets—those help other workers, but only stars appear on the list.")
                    .font(ThemeManager.SwiftUIFonts.caption)
                    .foregroundColor(ThemeManager.SwiftUIColors.mocha)
            }
            
            Section("Your overall rating") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Stars: \(Int(overallStarRating))")
                            .font(ThemeManager.SwiftUIFonts.body)
                        Spacer()
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { value in
                                Image(systemName: value <= Int(overallStarRating) ? "star.fill" : "star")
                                    .foregroundColor(ThemeManager.SwiftUIColors.coral)
                                    .onTapGesture { overallStarRating = Double(value) }
                            }
                        }
                    }
                    Slider(value: $overallStarRating, in: 1...5, step: 1)
                        .tint(ThemeManager.SwiftUIColors.coral)
                }
            }
            
            Section("WiFi at this spot") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Rating: \(Int(wifiRating))")
                            .font(ThemeManager.SwiftUIFonts.body)
                        Spacer()
                        Text("\(Int(wifiRating))/5")
                            .font(ThemeManager.SwiftUIFonts.caption)
                            .foregroundColor(.gray)
                    }
                    Slider(value: $wifiRating, in: 1...5, step: 1)
                        .tint(ThemeManager.SwiftUIColors.coral)
                }
            }
            
            Section("Noise at this spot") {
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
            
            Section {
                TextField("Optional note with your review…", text: $userTip, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Notes (optional)")
            } footer: {
                Text("Appears under Community Reviews on this spot. For short standalone tips, use Quick Tips on the detail page.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .dismissKeyboardOnTap()
        .navigationTitle("Rate This Spot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    showingRatingForm = false
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Submit") {
                    submitRating()
                }
                .disabled(!canSubmit)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: ThemeManager.Spacing.sm) {
                Button {
                    submitRating()
                } label: {
                    Text("Submit Rating")
                        .font(ThemeManager.SwiftUIFonts.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeManager.SwiftUIColors.coral)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.vertical, ThemeManager.Spacing.sm)
            .background(ThemeManager.SwiftUIColors.latte)
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
        Task {
            await submitRatingToCommunity()
        }
    }
    
    @MainActor
    private func refreshSpotEnrichmentFromCommunity(spotId: UUID) async {
        do {
            if let updated = try await SupabaseCommunityService.shared.enrichSpotFromCommunity(spotId: spotId) {
                _ = try SupabaseCommunityService.shared.syncToCoreData(remoteSpots: [updated])
                viewContext.refreshAllObjects()
                logger.info("Refreshed community enrichment for \(spot.name)")
            }
        } catch {
            logger.warning("Spot re-enrichment failed: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func applyReviewToCoreData(
        stars: Int,
        wifi: Int,
        noise: String,
        plugs: Bool,
        tip: String,
        supabaseId: String?
    ) throws {
        let rating: UserRating
        if let supabaseId {
            let request = UserRating.fetchRequest()
            request.predicate = NSPredicate(format: "supabaseId == %@", supabaseId)
            request.fetchLimit = 1
            if let existing = try viewContext.fetch(request).first {
                rating = existing
            } else {
                rating = UserRating(context: viewContext)
                rating.supabaseId = supabaseId
                rating.spot = spot
            }
        } else {
            rating = UserRating(context: viewContext)
            rating.spot = spot
        }
        
        rating.stars = Int16(stars)
        rating.wifi = Int16(wifi)
        rating.noise = noise
        rating.plugs = plugs
        rating.tip = tip
    }
    
    @MainActor
    private func submitRatingToCommunity() async {
        let trimmedTip = userTip.trimmingCharacters(in: .whitespacesAndNewlines)
        let stars = max(1, min(5, Int(overallStarRating)))
        let wifi = max(1, min(5, Int(wifiRating)))
        
        do {
            if usesCommunityBackend {
                try authService.requireCommunityWriter()
                guard let spotId = spot.supabaseId.flatMap(UUID.init(uuidString:)),
                      let userId = authService.userID else {
                    showError("This spot is not linked to the community catalog yet.")
                    return
                }
                
                let remote = try await SupabaseUGCService.shared.upsertReview(
                    spotId: spotId,
                    userId: userId,
                    stars: stars,
                    wifi: wifi,
                    noise: noiseLevel,
                    plugs: outletsAvailable,
                    tip: trimmedTip
                )
                
                try applyReviewToCoreData(
                    stars: stars,
                    wifi: wifi,
                    noise: noiseLevel,
                    plugs: outletsAvailable,
                    tip: trimmedTip,
                    supabaseId: remote.id.uuidString
                )
            } else {
                try applyReviewToCoreData(
                    stars: stars,
                    wifi: wifi,
                    noise: noiseLevel,
                    plugs: outletsAvailable,
                    tip: trimmedTip,
                    supabaseId: nil
                )
            }
            
            try viewContext.save()
            CommunitySpotNotifications.postSpotUpdated(supabaseId: spot.supabaseId)
            
            if usesCommunityBackend, let spotId = spot.supabaseId.flatMap(UUID.init(uuidString:)) {
                await refreshSpotEnrichmentFromCommunity(spotId: spotId)
                await SupabaseUGCService.shared.refreshCommunityContent(for: spot)
                viewContext.refresh(spot, mergeChanges: true)
                viewContext.refreshAllObjects()
            }
            
            logger.info("Successfully saved user rating for \(spot.name)")
            showingRatingForm = false
            resetRatingForm()
        } catch SupabaseAuthError.communitySignInRequired {
            showingRatingForm = false
            pendingCommunityAction = .addRating
            showingCommunitySignIn = true
        } catch {
            logger.error("Failed to save user rating: \(error.localizedDescription)")
            showError(UserFacingError.message(for: error, context: .saveRating) ?? "Your rating couldn’t be saved. Please try again.")
        }
    }
    
    private func savePhoto(_ image: UIImage) {
        Task {
            await savePhotoToCommunity(image)
        }
    }
    
    @MainActor
    private func savePhotoToCommunity(_ image: UIImage) async {
        do {
            if usesCommunityBackend {
                try authService.requireCommunityWriter()
                guard let spotId = spot.supabaseId.flatMap(UUID.init(uuidString:)),
                      let userId = authService.userID else {
                    showError("This spot is not linked to the community catalog yet.")
                    return
                }
                
                let remote = try await SupabaseUGCService.shared.uploadPhoto(
                    spotId: spotId,
                    userId: userId,
                    image: image
                )
                
                let photo = Photo(context: viewContext)
                photo.timestamp = Date()
                photo.spot = spot
                photo.cloudKitRecordID = ""
                photo.supabaseId = remote.id.uuidString
                photo.photoAsset = remote.storagePath
                photo.imageData = image.jpegData(compressionQuality: 0.85)
            } else {
                let photo = Photo(context: viewContext)
                photo.timestamp = Date()
                photo.spot = spot
                photo.cloudKitRecordID = ""
                photo.image = image
            }
            
            try viewContext.save()
            logger.info("Successfully saved photo for \(spot.name)")
        } catch SupabaseAuthError.communitySignInRequired {
            pendingCommunityAction = .uploadPhoto
            showingCommunitySignIn = true
        } catch {
            logger.error("Failed to save photo: \(error.localizedDescription)")
            showError(UserFacingError.message(for: error, context: .savePhoto) ?? "Your photo couldn’t be uploaded. Please try again.")
        }
    }
    
    private func photoThumbnailView(photo: Photo) -> some View {
        Group {
            if let photoAsset = photo.photoAsset, !photoAsset.isEmpty {
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
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ThemeManager.SwiftUIColors.latte)
                        .frame(width: 120, height: 120)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(ThemeManager.SwiftUIColors.mocha)
                                .font(.title2)
                        )
                        .onAppear {
                            if isCommunityStoragePath(photoAsset) {
                                loadCommunityPhoto(photo: photo, storagePath: photoAsset)
                            } else {
                                loadCloudKitImage(photo: photo, assetID: photoAsset)
                            }
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
    
    private var communitySignInFeatureTitle: String {
        switch pendingCommunityAction {
        case .addRating:
            return "rate this spot"
        case .uploadPhoto:
            return "upload photos"
        case .submitTip:
            return "share tips"
        case .none:
            return "contribute"
        }
    }
    
    private func promptForCommunityWriteIfNeeded(
        _ action: PendingCommunityAction,
        perform: @escaping () -> Void
    ) {
        guard usesCommunityBackend, !authService.canWriteCommunityContent else {
            perform()
            return
        }
        pendingCommunityAction = action
        showingCommunitySignIn = true
    }
    
    private func resumePendingCommunityAction() {
        guard let action = pendingCommunityAction else { return }
        pendingCommunityAction = nil
        
        switch action {
        case .addRating:
            showingRatingForm = true
        case .uploadPhoto:
            showingImagePicker = true
        case .submitTip:
            Task { await submitTip() }
        }
    }
    
    private func isCommunityStoragePath(_ path: String) -> Bool {
        path.contains("/")
    }
    
    private func loadCommunityPhoto(photo: Photo, storagePath: String) {
        guard !loadingImages.contains(storagePath) else { return }
        loadingImages.insert(storagePath)
        
        Task {
            defer {
                Task { @MainActor in
                    loadingImages.remove(storagePath)
                }
            }
            
            do {
                let url = try SupabaseUGCService.shared.publicPhotoURL(storagePath: storagePath)
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    await MainActor.run {
                        loadedImages[storagePath] = image
                    }
                }
            } catch {
                logger.warning("Failed to load community photo: \(error.localizedDescription)")
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
        overallStarRating = 4.0
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
    
    @MainActor
    private func submitTip() async {
        let trimmedText = newTipText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        do {
            if usesCommunityBackend {
                try authService.requireCommunityWriter()
                guard let spotId = spot.supabaseId.flatMap(UUID.init(uuidString:)),
                      let userId = authService.userID else {
                    showError("This spot is not linked to the community catalog yet.")
                    return
                }
                
                let remote = try await SupabaseUGCService.shared.insertTip(
                    spotId: spotId,
                    userId: userId,
                    text: trimmedText
                )
                
                let userTip = UserTip(context: viewContext)
                userTip.text = trimmedText
                userTip.timestamp = remote.createdAt ?? Date()
                userTip.supabaseId = remote.id.uuidString
                userTip.cloudKitRecordID = ""
                userTip.spot = spot
            } else {
                let userTip = UserTip.create(text: trimmedText, spot: spot, in: viewContext)
                spot.addToUserTips(userTip)
            }
            
            try viewContext.save()
            logger.info("Successfully submitted tip: \(trimmedText)")
            newTipText = ""
        } catch SupabaseAuthError.communitySignInRequired {
            pendingCommunityAction = .submitTip(trimmedText)
            showingCommunitySignIn = true
        } catch {
            logger.error("Failed to submit tip: \(error.localizedDescription)")
            showError(UserFacingError.message(for: error, context: .saveTip) ?? "Your tip couldn’t be posted. Please try again.")
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
        sampleSpot.outlets = NSNumber(value: true)
        sampleSpot.tips = "Great coffee and cozy atmosphere. Perfect for remote work."
        sampleSpot.lastSeeded = Date()
        sampleSpot.cloudKitRecordID = "sample-record-id"
        
        // Add a sample user rating
        let sampleUserRating = UserRating(context: viewContext)
        sampleUserRating.stars = 5
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