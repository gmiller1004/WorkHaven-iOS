//
//  PersistenceController.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import CoreData
import CloudKit
import OSLog

/**
 * PersistenceController manages the Core Data stack with CloudKit synchronization
 * for WorkHaven app. Provides singleton access to NSPersistentCloudKitContainer
 * with error handling, history tracking, and remote notifications.
 */
class PersistenceController {
    
    // MARK: - Singleton
    static let shared = PersistenceController()
    
    // MARK: - Properties
    let container: NSPersistentCloudKitContainer
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "Persistence")
    
    // MARK: - Initialization
    private init() {
        container = NSPersistentCloudKitContainer(name: "WorkHaven")
        
        // Configure CloudKit container
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("Failed to retrieve persistent store description")
        }
        
        // Configure CloudKit
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        // CloudKit container identifier
        let cloudKitOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.nextsizzle.wh")
        description.cloudKitContainerOptions = cloudKitOptions
        
        // Async loading
        container.loadPersistentStores { [weak self] storeDescription, error in
            if let error = error as NSError? {
                self?.logger.error("Failed to load persistent store: \(error.localizedDescription)")
                self?.logger.error("Error details: \(error.userInfo)")
                
                // Handle CloudKit schema sync errors specifically
                if error.domain == NSCocoaErrorDomain && error.code == 134030 {
                    self?.logger.error("CloudKit schema sync error detected. This may require CloudKit schema migration.")
                }
                
                // For production, you might want to handle this more gracefully
                fatalError("Unresolved error \(error), \(error.userInfo)")
            } else {
                self?.logger.info("Successfully loaded persistent store: \(storeDescription.url?.lastPathComponent ?? "unknown")")
            }
        }
        
        // Enable automatic merging of changes from parent context
        container.viewContext.automaticallyMergesChangesFromParent = true
        
        // Configure view context for better performance
        container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        
        setupRemoteChangeNotifications()
    }
    
    // MARK: - Remote Change Notifications
    private func setupRemoteChangeNotifications() {
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("Remote change notification received")
            // Handle remote changes if needed
            // You can post additional notifications here for UI updates
        }
    }
    
    // MARK: - Context Management
    func save() {
        let context = container.viewContext
        
        if context.hasChanges {
            do {
                try context.save()
                logger.info("Successfully saved context")
            } catch {
                logger.error("Failed to save context: \(error.localizedDescription)")
                // Handle the error appropriately
            }
        }
    }
    
    func newBackgroundContext() -> NSManagedObjectContext {
        return container.newBackgroundContext()
    }
    
    // MARK: - Async Save
    func saveAsync() async {
        await container.performBackgroundTask { context in
            do {
                if context.hasChanges {
                    try context.save()
                    self.logger.info("Successfully saved background context")
                }
            } catch {
                self.logger.error("Failed to save background context: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - CloudKit Status
    func checkCloudKitStatus() {
        let container = CKContainer(identifier: "iCloud.com.nextsizzle.wh")
        
        container.accountStatus { [weak self] accountStatus, error in
            if let error = error {
                self?.logger.error("CloudKit account status error: \(error.localizedDescription)")
                return
            }
            
            switch accountStatus {
            case .available:
                self?.logger.info("CloudKit account is available")
            case .noAccount:
                self?.logger.warning("No CloudKit account found")
            case .restricted:
                self?.logger.warning("CloudKit account is restricted")
            case .couldNotDetermine:
                self?.logger.warning("Could not determine CloudKit account status")
            case .temporarilyUnavailable:
                self?.logger.warning("CloudKit account is temporarily unavailable")
            @unknown default:
                self?.logger.warning("Unknown CloudKit account status")
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Preview Support
extension PersistenceController {
    static var preview: PersistenceController = {
        let controller = PersistenceController()
        let context = controller.container.viewContext
        
        // Create sample data for previews
        let sampleSpot = Spot(context: context)
        sampleSpot.name = "Coffee Corner"
        sampleSpot.address = "123 Main St, City, State"
        sampleSpot.latitude = 37.7749
        sampleSpot.longitude = -122.4194
        sampleSpot.wifiRating = 4
        sampleSpot.noiseRating = "Quiet"
        sampleSpot.outlets = true
        sampleSpot.tips = "Great coffee and fast WiFi"
        sampleSpot.lastModified = Date()
        sampleSpot.cloudKitRecordID = "sample-record-id"
        
        let sampleRating = UserRating(context: context)
        sampleRating.wifi = 5
        sampleRating.noise = "Very Quiet"
        sampleRating.plugs = true
        sampleRating.tip = "Perfect for focused work"
        sampleRating.spot = sampleSpot
        
        do {
            try context.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        
        return controller
    }()
}
