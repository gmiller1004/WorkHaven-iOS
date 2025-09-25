//
//  NotificationManager.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import UserNotifications
import CloudKit
import CoreLocation
import OSLog
import SwiftUI

/**
 * NotificationManager handles all push notifications and CloudKit subscriptions for WorkHaven.
 * Provides APNs integration for geofencing alerts and community updates, plus CloudKit
 * subscription management for real-time data synchronization across devices.
 * 
 * Features:
 * - Geofencing notifications for nearby high-rated spots
 * - Community update notifications for ratings, photos, and tips
 * - CloudKit subscription management for real-time updates
 * - Permission handling and authorization status tracking
 * - Error handling with comprehensive logging
 */
@MainActor
public class NotificationManager: NSObject, ObservableObject {
    
    // MARK: - Singleton
    
    public static let shared = NotificationManager()
    
    // MARK: - Published Properties
    
    /// Current authorization status for notifications
    @Published public var isAuthorized: Bool = false
    
    /// Current error message for UI display
    @Published public var errorMessage: String?
    
    // MARK: - Private Properties
    
    private let notificationCenter = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "NotificationManager")
    private nonisolated let nonisolatedLogger = Logger(subsystem: "com.nextsizzle.wh", category: "NotificationManager")
    private let cloudKitContainer = CKContainer(identifier: "iCloud.com.nextsizzle.wh")
    private let spotViewModel = SpotViewModel()
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        notificationCenter.delegate = self
        checkAuthorizationStatus()
    }
    
    // MARK: - Authorization Management
    
    /**
     * Requests notification permissions from the user
     * - Parameter completion: Optional completion handler called with authorization result
     */
    public func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        logger.info("Requesting notification authorization")
        
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        
        notificationCenter.requestAuthorization(options: options) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.logger.error("Notification authorization error: \(error.localizedDescription)")
                    self?.errorMessage = "Failed to request notification permissions: \(error.localizedDescription)"
                    completion?(false)
                    return
                }
                
                self?.isAuthorized = granted
                
                if granted {
                    self?.logger.info("Notification authorization granted")
                    self?.errorMessage = nil
                } else {
                    self?.logger.warning("Notification permission denied")
                    self?.errorMessage = "Notification permissions are required for location-based alerts"
                }
                
                completion?(granted)
            }
        }
    }
    
    /**
     * Checks the current authorization status
     */
    public func checkAuthorizationStatus() {
        notificationCenter.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self?.isAuthorized = true
                    self?.logger.info("Notification authorization status: \(settings.authorizationStatus.rawValue)")
                case .denied:
                    self?.isAuthorized = false
                    self?.logger.warning("Notification authorization denied")
                case .notDetermined:
                    self?.isAuthorized = false
                    self?.logger.info("Notification authorization not determined")
                case .ephemeral:
                    self?.isAuthorized = true
                    self?.logger.info("Notification authorization ephemeral")
                @unknown default:
                    self?.isAuthorized = false
                    self?.logger.warning("Unknown notification authorization status")
                }
            }
        }
    }
    
    // MARK: - Geofencing Notifications
    
    /**
     * Schedules a geofencing notification for a nearby high-rated spot
     * - Parameter spot: The spot to monitor
     * - Parameter radius: The geofencing radius in meters (default: 1 mile)
     * - Parameter condition: The rating condition for triggering (default: > 4.0)
     */
    public func scheduleNearbyAlert(for spot: Spot, radius: Double = 1609.34, condition: Double = 4.0) {
        guard isAuthorized else {
            logger.warning("Cannot schedule notification: not authorized")
            errorMessage = "Notification permissions required for location alerts"
            return
        }
        
        // Check if spot meets rating condition
        let overallRating = spotViewModel.calculateOverallRating(for: spot)
        guard overallRating > condition else {
            logger.debug("Spot '\(spot.name)' rating \(overallRating) does not meet condition \(condition)")
            return
        }
        
        // Create location trigger
        let coordinate = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
        let region = CLCircularRegion(center: coordinate, radius: radius, identifier: "spot_\(spot.objectID)")
        
        region.notifyOnEntry = true
        region.notifyOnExit = false
        
        let trigger = UNLocationNotificationTrigger(region: region, repeats: false)
        
        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "Great Work Spot Nearby!"
        content.body = "\(spot.name) is nearby and has a \(String(format: "%.1f", overallRating)) star rating"
        content.sound = .default
        content.badge = 1
        
        // Add spot information to user info
        content.userInfo = [
            "spotID": spot.objectID.uriRepresentation().absoluteString,
            "spotName": spot.name,
            "spotAddress": spot.address,
            "spotRating": overallRating,
            "notificationType": "nearby_alert"
        ]
        
        // Create notification request
        let request = UNNotificationRequest(
            identifier: "nearby_\(spot.objectID)",
            content: content,
            trigger: trigger
        )
        
        // Schedule notification
        notificationCenter.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to schedule nearby alert for \(spot.name): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.errorMessage = "Failed to schedule location alert"
                }
            } else {
                self?.logger.info("Scheduled nearby alert for spot: \(spot.name)")
            }
        }
    }
    
    /**
     * Cancels a nearby alert for a specific spot
     * - Parameter spot: The spot to stop monitoring
     */
    public func cancelNearbyAlert(for spot: Spot) {
        let identifier = "nearby_\(spot.objectID)"
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
        logger.info("Cancelled nearby alert for spot: \(spot.name)")
    }
    
    // MARK: - Community Update Notifications
    
    /**
     * Schedules a delayed community update notification
     * - Parameter spot: The spot that was updated
     * - Parameter activityType: Type of activity ("rating", "photo", "tip")
     * - Parameter delay: Delay in seconds before showing notification (default: 30)
     */
    public func scheduleCommunityUpdate(for spot: Spot, activityType: String, delay: TimeInterval = 30) {
        guard isAuthorized else {
            logger.warning("Cannot schedule community update: not authorized")
            return
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        
        // Create notification content based on activity type
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.badge = 1
        
        switch activityType.lowercased() {
        case "rating":
            content.title = "New Rating Added!"
            content.body = "Someone rated \(spot.name) - check it out!"
        case "photo":
            content.title = "New Photo Added!"
            content.body = "See the latest photo of \(spot.name)"
        case "tip":
            content.title = "New Tip Added!"
            content.body = "Read the latest tip for \(spot.name)"
        default:
            content.title = "Spot Updated!"
            content.body = "\(spot.name) has new activity"
        }
        
        // Add spot information to user info
        content.userInfo = [
            "spotID": spot.objectID.uriRepresentation().absoluteString,
            "spotName": spot.name,
            "activityType": activityType,
            "notificationType": "community_update"
        ]
        
        // Create notification request
        let request = UNNotificationRequest(
            identifier: "community_\(spot.objectID)_\(activityType)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        
        // Schedule notification
        notificationCenter.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to schedule community update for \(spot.name): \(error.localizedDescription)")
            } else {
                self?.logger.info("Scheduled community update for spot: \(spot.name), activity: \(activityType)")
            }
        }
    }
    
    // MARK: - CloudKit Subscriptions
    
    /**
     * Subscribes to CloudKit updates for community activity on a specific spot
     * - Parameter spot: The spot to monitor for updates
     */
    public func subscribeToCommunityUpdates(for spot: Spot) {
        guard !spot.cloudKitRecordID.isEmpty else {
            logger.warning("Cannot subscribe to updates: spot has no CloudKit record ID")
            return
        }
        
        Task {
            do {
                let database = cloudKitContainer.privateCloudDatabase
                
                // Create predicate for the specific spot
                let spotRecordID = CKRecord.ID(recordName: spot.cloudKitRecordID)
                let predicate = NSPredicate(format: "recordID == %@", spotRecordID)
                
                // Create subscription
                let subscription = CKQuerySubscription(
                    recordType: "Spot",
                    predicate: predicate,
                    subscriptionID: "spot_updates_\(spot.cloudKitRecordID)",
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
                )
                
                // Configure notification info
                let notificationInfo = CKSubscription.NotificationInfo()
                notificationInfo.alertBody = "\(spot.name) has been updated!"
                notificationInfo.shouldBadge = true
                notificationInfo.shouldSendContentAvailable = true
                
                subscription.notificationInfo = notificationInfo
                
                // Save subscription
                try await database.save(subscription)
                logger.info("Created CloudKit subscription for spot: \(spot.name)")
                
            } catch {
                logger.error("Failed to create CloudKit subscription for \(spot.name): \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "Failed to subscribe to spot updates"
                }
            }
        }
    }
    
    /**
     * Unsubscribes from CloudKit updates for a specific spot
     * - Parameter spot: The spot to stop monitoring
     */
    public func unsubscribeFromCommunityUpdates(for spot: Spot) {
        guard !spot.cloudKitRecordID.isEmpty else {
            logger.warning("Cannot unsubscribe: spot has no CloudKit record ID")
            return
        }
        
        Task {
            do {
                let database = cloudKitContainer.privateCloudDatabase
                let subscriptionID = "spot_updates_\(spot.cloudKitRecordID)"
                
                try await database.deleteSubscription(withID: subscriptionID)
                logger.info("Removed CloudKit subscription for spot: \(spot.name)")
                
            } catch {
                logger.error("Failed to remove CloudKit subscription for \(spot.name): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Notification Management
    
    /**
     * Cancels all pending notifications
     */
    public func cancelAllNotifications() {
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
        logger.info("Cancelled all notifications")
    }
    
    /**
     * Gets all pending notifications
     * - Parameter completion: Completion handler with array of pending notifications
     */
    public func getPendingNotifications(completion: @escaping ([UNNotificationRequest]) -> Void) {
        notificationCenter.getPendingNotificationRequests(completionHandler: completion)
    }
    
    /**
     * Gets all delivered notifications
     * - Parameter completion: Completion handler with array of delivered notifications
     */
    public func getDeliveredNotifications(completion: @escaping ([UNNotification]) -> Void) {
        notificationCenter.getDeliveredNotifications(completionHandler: completion)
    }
    
    // MARK: - Error Handling
    
    /**
     * Clears the current error message
     */
    public func clearError() {
        errorMessage = nil
    }
    
    /**
     * Shows an error alert using ThemeManager styling
     * - Parameter message: The error message to display
     */
    private func showErrorAlert(message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: @preconcurrency UNUserNotificationCenterDelegate {
    
    /**
     * Handles notifications when app is in foreground
     */
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        nonisolatedLogger.info("Received notification in foreground: \(notification.request.identifier)")
        
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    /**
     * Handles notification taps
     */
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let notificationType = userInfo["notificationType"] as? String
        
        nonisolatedLogger.info("User tapped notification: \(response.notification.request.identifier), type: \(notificationType ?? "unknown")")
        
        // Handle different notification types
        switch notificationType {
        case "nearby_alert":
            handleNearbyAlertTap(userInfo: userInfo)
        case "community_update":
            handleCommunityUpdateTap(userInfo: userInfo)
        default:
            nonisolatedLogger.warning("Unknown notification type: \(notificationType ?? "nil")")
        }
        
        completionHandler()
    }
    
    // MARK: - Notification Tap Handlers
    
    /**
     * Handles taps on nearby alert notifications
     */
    nonisolated private func handleNearbyAlertTap(userInfo: [AnyHashable: Any]) {
        guard let spotName = userInfo["spotName"] as? String else { return }
        nonisolatedLogger.info("User tapped nearby alert for spot: \(spotName)")
        
        // TODO: Navigate to spot detail view
        // This would typically involve posting a notification or using a coordinator
    }
    
    /**
     * Handles taps on community update notifications
     */
    nonisolated private func handleCommunityUpdateTap(userInfo: [AnyHashable: Any]) {
        guard let spotName = userInfo["spotName"] as? String,
              let activityType = userInfo["activityType"] as? String else { return }
        
        nonisolatedLogger.info("User tapped community update for spot: \(spotName), activity: \(activityType)")
        
        // TODO: Navigate to spot detail view with specific section
        // This would typically involve posting a notification or using a coordinator
    }
}

// MARK: - Error Types

extension NotificationManager {
    
    /**
     * Custom error types for notification management
     */
    public enum NotificationError: LocalizedError {
        case notAuthorized
        case invalidSpot
        case cloudKitError(String)
        case schedulingError(String)
        
        public var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Notification permissions are required"
            case .invalidSpot:
                return "Invalid spot for notification"
            case .cloudKitError(let message):
                return "CloudKit error: \(message)"
            case .schedulingError(let message):
                return "Scheduling error: \(message)"
            }
        }
    }
}
