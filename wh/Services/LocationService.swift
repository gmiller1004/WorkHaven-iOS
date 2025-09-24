//
//  LocationService.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import CoreLocation
import SwiftUI
import OSLog

/**
 * LocationService manages user location permissions and tracking for WorkHaven.
 * Provides real-time location updates and handles permission requests with async/await.
 * Supports both when-in-use and always location access for geofencing features.
 */
@MainActor
class LocationService: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    /// Current user location, nil if not available
    @Published var currentLocation: CLLocation?
    
    /// Location authorization status
    @Published var isAuthorized: Bool = false
    
    /// Location permission status for detailed UI feedback
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    // MARK: - Private Properties
    
    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "LocationService")
    
    /// UserDefaults key for geofencing preference
    private let geofencingEnabledKey = "GeofencingEnabled"
    
    // MARK: - Singleton
    
    static let shared = LocationService()
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setupLocationManager()
        updateAuthorizationStatus()
    }
    
    // MARK: - Setup
    
    /**
     * Configures the CLLocationManager with appropriate settings
     */
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10.0 // Update every 10 meters
        
        // Check if location services are available
        guard CLLocationManager.locationServicesEnabled() else {
            logger.warning("Location services are not enabled on this device")
            return
        }
        
        logger.info("LocationService initialized successfully")
    }
    
    // MARK: - Permission Management
    
    /**
     * Requests when-in-use location permission
     * - Returns: True if permission is granted, false otherwise
     */
    func requestWhenInUsePermission() async -> Bool {
        logger.info("Requesting when-in-use location permission")
        
        return await withCheckedContinuation { continuation in
            // Check current status first
            let currentStatus = locationManager.authorizationStatus
            if currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways {
                logger.info("Location permission already granted")
                continuation.resume(returning: true)
                return
            }
            
            if currentStatus == .denied || currentStatus == .restricted {
                logger.warning("Location permission denied or restricted")
                continuation.resume(returning: false)
                return
            }
            
            // Request permission
            locationManager.requestWhenInUseAuthorization()
            
            // Store continuation for delegate callback
            self.pendingPermissionContinuation = continuation
        }
    }
    
    /**
     * Requests always location permission for geofencing
     * - Returns: True if permission is granted, false otherwise
     */
    func requestAlwaysPermission() async -> Bool {
        logger.info("Requesting always location permission for geofencing")
        
        return await withCheckedContinuation { continuation in
            // Check current status first
            let currentStatus = locationManager.authorizationStatus
            if currentStatus == .authorizedAlways {
                logger.info("Always location permission already granted")
                continuation.resume(returning: true)
                return
            }
            
            if currentStatus == .denied || currentStatus == .restricted {
                logger.warning("Location permission denied or restricted")
                continuation.resume(returning: false)
                return
            }
            
            // Request permission
            locationManager.requestAlwaysAuthorization()
            
            // Store continuation for delegate callback
            self.pendingPermissionContinuation = continuation
        }
    }
    
    /**
     * Requests appropriate permission based on geofencing preference
     * - Returns: True if permission is granted, false otherwise
     */
    func requestLocationPermission() async -> Bool {
        let geofencingEnabled = UserDefaults.standard.bool(forKey: geofencingEnabledKey)
        
        if geofencingEnabled {
            logger.info("Geofencing enabled, requesting always permission")
            return await requestAlwaysPermission()
        } else {
            logger.info("Geofencing disabled, requesting when-in-use permission")
            return await requestWhenInUsePermission()
        }
    }
    
    // MARK: - Location Tracking
    
    /**
     * Starts location tracking
     */
    func startLocationUpdates() {
        guard isAuthorized else {
            logger.warning("Cannot start location updates: not authorized")
            return
        }
        
        guard CLLocationManager.locationServicesEnabled() else {
            logger.error("Location services are not enabled")
            return
        }
        
        locationManager.startUpdatingLocation()
        logger.info("Started location updates")
    }
    
    /**
     * Stops location tracking
     */
    func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        logger.info("Stopped location updates")
    }
    
    /**
     * Gets current location if available
     * - Returns: Current location or nil if not available
     */
    func getCurrentLocation() -> CLLocation? {
        return currentLocation
    }
    
    // MARK: - Geofencing Management
    
    /**
     * Enables or disables geofencing preference
     * - Parameter enabled: Whether geofencing should be enabled
     */
    func setGeofencingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: geofencingEnabledKey)
        logger.info("Geofencing preference set to: \(enabled)")
        
        // If enabling geofencing and we only have when-in-use permission, request always
        if enabled && authorizationStatus == .authorizedWhenInUse {
            Task {
                await requestAlwaysPermission()
            }
        }
    }
    
    /**
     * Checks if geofencing is enabled
     * - Returns: True if geofencing is enabled, false otherwise
     */
    func isGeofencingEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: geofencingEnabledKey)
    }
    
    // MARK: - Helper Methods
    
    /**
     * Updates authorization status and published properties
     */
    private func updateAuthorizationStatus() {
        authorizationStatus = locationManager.authorizationStatus
        
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            isAuthorized = true
            logger.info("Location permission granted: \(self.authorizationStatus.rawValue)")
        case .denied:
            isAuthorized = false
            logger.warning("Location access denied by user")
        case .restricted:
            isAuthorized = false
            logger.warning("Location access restricted by system")
        case .notDetermined:
            isAuthorized = false
            logger.info("Location permission not yet determined")
        @unknown default:
            isAuthorized = false
            logger.warning("Unknown location authorization status: \(self.authorizationStatus.rawValue)")
        }
    }
    
    /**
     * Handles location permission result
     * - Parameter granted: Whether permission was granted
     */
    private func handlePermissionResult(granted: Bool) {
        if granted {
            logger.info("Location permission granted successfully")
            startLocationUpdates()
        } else {
            logger.warning("Location permission denied")
        }
        
            // Resume any pending permission request
            if pendingPermissionContinuation != nil {
                let continuation = pendingPermissionContinuation!
                pendingPermissionContinuation = nil
                continuation.resume(returning: granted)
            }
    }
    
    // MARK: - Private Properties for Async Handling
    
    /// Continuation for pending permission requests
    private var pendingPermissionContinuation: CheckedContinuation<Bool, Never>?
}

// MARK: - CLLocationManagerDelegate

extension LocationService: @preconcurrency CLLocationManagerDelegate {
    
    /**
     * Handles location authorization changes
     */
    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            logger.info("Location authorization changed to: \(status.rawValue)")
            updateAuthorizationStatus()
            
            // Handle permission request result
            if let continuation = pendingPermissionContinuation {
                let granted = (status == .authorizedWhenInUse || status == .authorizedAlways)
                handlePermissionResult(granted: granted)
            }
        }
    }
    
    /**
     * Handles successful location updates
     */
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else { return }
            
            // Update current location
            currentLocation = location
            
            logger.info("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            
            // Log accuracy and timestamp
            logger.debug("Location accuracy: \(location.horizontalAccuracy)m, timestamp: \(location.timestamp)")
        }
    }
    
    /**
     * Handles location update errors
     */
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let clError = error as? CLError {
                switch clError.code {
                case .locationUnknown:
                    logger.warning("Location unknown: \(error.localizedDescription)")
                case .denied:
                    logger.warning("Location access denied: \(error.localizedDescription)")
                    isAuthorized = false
                case .network:
                    logger.error("Location network error: \(error.localizedDescription)")
                default:
                    logger.error("Location error: \(error.localizedDescription)")
                }
            } else {
                logger.error("Location manager failed with error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Error Handling

extension LocationService {
    
    /**
     * Handles location service errors with appropriate logging
     * - Parameter error: The error that occurred
     */
    private func handleLocationError(_ error: Error) {
        if let clError = error as? CLError {
            switch clError.code {
            case .locationUnknown:
                logger.warning("Location unknown: \(error.localizedDescription)")
            case .denied:
                logger.warning("Location access denied: \(error.localizedDescription)")
                isAuthorized = false
            case .network:
                logger.error("Location network error: \(error.localizedDescription)")
            case .headingFailure:
                logger.warning("Heading failure: \(error.localizedDescription)")
            case .regionMonitoringDenied:
                logger.warning("Region monitoring denied: \(error.localizedDescription)")
            case .regionMonitoringFailure:
                logger.error("Region monitoring failure: \(error.localizedDescription)")
            case .regionMonitoringSetupDelayed:
                logger.info("Region monitoring setup delayed: \(error.localizedDescription)")
            case .regionMonitoringResponseDelayed:
                logger.info("Region monitoring response delayed: \(error.localizedDescription)")
            case .geocodeFoundNoResult:
                logger.warning("Geocode found no result: \(error.localizedDescription)")
            case .geocodeFoundPartialResult:
                logger.warning("Geocode found partial result: \(error.localizedDescription)")
            case .geocodeCanceled:
                logger.info("Geocode canceled: \(error.localizedDescription)")
            case .deferredFailed:
                logger.error("Deferred location update failed: \(error.localizedDescription)")
            case .deferredNotUpdatingLocation:
                logger.warning("Deferred location update not updating: \(error.localizedDescription)")
            case .deferredAccuracyTooLow:
                logger.warning("Deferred location update accuracy too low: \(error.localizedDescription)")
            case .deferredDistanceFiltered:
                logger.info("Deferred location update distance filtered: \(error.localizedDescription)")
            case .rangingUnavailable:
                logger.warning("Ranging unavailable: \(error.localizedDescription)")
            case .rangingFailure:
                logger.error("Ranging failure: \(error.localizedDescription)")
            case .deferredCanceled:
                logger.info("Deferred location update canceled: \(error.localizedDescription)")
            case .promptDeclined:
                logger.warning("Location prompt declined: \(error.localizedDescription)")
            case .historicalLocationError:
                logger.error("Historical location error: \(error.localizedDescription)")
            @unknown default:
                logger.error("Unknown Core Location error: \(error.localizedDescription)")
            }
        } else {
            logger.error("Location service error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension LocationService {
    
    /**
     * Debug method to simulate location updates
     * - Parameter coordinate: The coordinate to simulate
     */
    func simulateLocationUpdate(at coordinate: CLLocationCoordinate2D) {
        let simulatedLocation = CLLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        currentLocation = simulatedLocation
        logger.debug("Simulated location update: \(coordinate.latitude), \(coordinate.longitude)")
    }
    
    /**
     * Debug method to reset location service state
     */
    func resetForTesting() {
        currentLocation = nil
        isAuthorized = false
        authorizationStatus = .notDetermined
        stopLocationUpdates()
        logger.debug("LocationService reset for testing")
    }
}
#endif