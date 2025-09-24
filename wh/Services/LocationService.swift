//
//  LocationService.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import CoreLocation
import OSLog

/**
 * LocationService manages user location permissions and tracking for WorkHaven.
 * 
 * This service provides:
 * - Location permission management (when-in-use and always)
 * - Real-time location updates
 * - Geofencing support (optional, controlled via UserDefaults)
 * - Authorization status monitoring
 * - Async/await permission request handling
 * 
 * Usage:
 * - Call requestLocationPermission() to request when-in-use access
 * - Enable geofencing via UserDefaults.standard.set(true, forKey: "GeofencingEnabled")
 * - Monitor currentLocation and isAuthorized via @Published properties
 */
@MainActor
class LocationService: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    /// Current user location, nil if not available
    @Published var currentLocation: CLLocation?
    
    /// Whether location access is authorized
    @Published var isAuthorized: Bool = false
    
    // MARK: - Private Properties
    
    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "com.nextsizzle.wh", category: "LocationService")
    
    /// UserDefaults key for geofencing preference
    private let geofencingKey = "GeofencingEnabled"
    
    /// Continuation for async permission requests
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setupLocationManager()
        updateAuthorizationStatus()
    }
    
    // MARK: - Public Methods
    
    /**
     * Requests when-in-use location permission
     * 
     * - Returns: Boolean indicating if permission was granted
     */
    func requestLocationPermission() async -> Bool {
        logger.info("Requesting location permission...")
        
        // Check current status first
        let currentStatus = locationManager.authorizationStatus
        if currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways {
            logger.info("Location permission already granted")
            isAuthorized = true
            return true
        }
        
        if currentStatus == .denied || currentStatus == .restricted {
            logger.warning("Location access denied or restricted")
            isAuthorized = false
            return false
        }
        
        // Request permission asynchronously
        return await withCheckedContinuation { continuation in
            self.permissionContinuation = continuation
            locationManager.requestWhenInUseAuthorization()
        }
    }
    
    /**
     * Requests always location permission (for geofencing)
     * 
     * - Returns: Boolean indicating if permission was granted
     */
    func requestAlwaysLocationPermission() async -> Bool {
        logger.info("Requesting always location permission for geofencing...")
        
        // Check if geofencing is enabled
        guard UserDefaults.standard.bool(forKey: geofencingKey) else {
            logger.info("Geofencing not enabled, skipping always permission request")
            return false
        }
        
        // Check current status first
        let currentStatus = locationManager.authorizationStatus
        if currentStatus == .authorizedAlways {
            logger.info("Always location permission already granted")
            isAuthorized = true
            return true
        }
        
        if currentStatus == .denied || currentStatus == .restricted {
            logger.warning("Location access denied or restricted")
            isAuthorized = false
            return false
        }
        
        // Request always permission asynchronously
        return await withCheckedContinuation { continuation in
            self.permissionContinuation = continuation
            locationManager.requestAlwaysAuthorization()
        }
    }
    
    /**
     * Starts location updates
     * 
     * - Parameter accuracy: Desired location accuracy (default: .best)
     */
    func startLocationUpdates(accuracy: CLLocationAccuracy = kCLLocationAccuracyBest) {
        guard isAuthorized else {
            logger.warning("Cannot start location updates: not authorized")
            return
        }
        
        logger.info("Starting location updates with accuracy: \(accuracy)")
        locationManager.desiredAccuracy = accuracy
        locationManager.startUpdatingLocation()
    }
    
    /**
     * Stops location updates
     */
    func stopLocationUpdates() {
        logger.info("Stopping location updates")
        locationManager.stopUpdatingLocation()
    }
    
    /**
     * Gets the current location synchronously
     * 
     * - Returns: Current location if available, nil otherwise
     */
    func getCurrentLocation() -> CLLocation? {
        return currentLocation
    }
    
    /**
     * Checks if geofencing is enabled
     * 
     * - Returns: Boolean indicating if geofencing is enabled
     */
    func isGeofencingEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: geofencingKey)
    }
    
    /**
     * Enables or disables geofencing
     * 
     * - Parameter enabled: Whether to enable geofencing
     */
    func setGeofencingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: geofencingKey)
        logger.info("Geofencing \(enabled ? "enabled" : "disabled")")
        
        // If enabling geofencing, request always permission
        if enabled {
            Task {
                await requestAlwaysLocationPermission()
            }
        }
    }
    
    // MARK: - Private Methods
    
    /**
     * Sets up the location manager with proper configuration
     */
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10 // Update every 10 meters
    }
    
    /**
     * Updates the authorization status based on current permission state
     */
    private func updateAuthorizationStatus() {
        let status = locationManager.authorizationStatus
        isAuthorized = (status == .authorizedWhenInUse || status == .authorizedAlways)
        
        logger.info("Location authorization status: \(status.rawValue), authorized: \(self.isAuthorized)")
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: @preconcurrency CLLocationManagerDelegate {
    
    /**
     * Handles location manager authorization changes
     */
    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        logger.info("Location authorization changed to: \(status.rawValue)")
        
        Task { @MainActor in
            updateAuthorizationStatus()
            
            // Resume permission continuation if waiting
            if let continuation = permissionContinuation {
                permissionContinuation = nil
                continuation.resume(returning: isAuthorized)
            }
        }
        
        // Handle specific authorization states
        switch status {
        case .authorizedWhenInUse:
            logger.info("Location access granted (when-in-use)")
            // Start location updates if not already running
            if !CLLocationManager.locationServicesEnabled() {
                logger.warning("Location services not enabled on device")
            }
            
        case .authorizedAlways:
            logger.info("Location access granted (always)")
            // Start location updates if not already running
            if !CLLocationManager.locationServicesEnabled() {
                logger.warning("Location services not enabled on device")
            }
            
        case .denied:
            logger.error("Location access denied by user")
            Task { @MainActor in
                currentLocation = nil
            }
            
        case .restricted:
            logger.error("Location access restricted (parental controls, etc.)")
            Task { @MainActor in
                currentLocation = nil
            }
            
        case .notDetermined:
            logger.info("Location permission not yet determined")
            
        @unknown default:
            logger.warning("Unknown location authorization status: \(status.rawValue)")
        }
    }
    
    /**
     * Handles successful location updates
     */
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Validate location accuracy and age
        let locationAge = -location.timestamp.timeIntervalSinceNow
        if locationAge > 5.0 { // Ignore locations older than 5 seconds
            logger.debug("Ignoring stale location (age: \(locationAge)s)")
            return
        }
        
        if location.horizontalAccuracy < 0 {
            logger.debug("Ignoring invalid location (negative accuracy)")
            return
        }
        
        // Update current location
        Task { @MainActor in
            currentLocation = location
        }
        logger.debug("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude) (accuracy: \(location.horizontalAccuracy)m)")
    }
    
    /**
     * Handles location update errors
     */
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location update failed: \(error.localizedDescription)")
        
        // Handle specific error types
        if let clError = error as? CLError {
            switch clError.code {
            case .locationUnknown:
                logger.warning("Location unknown - continuing to try")
                
            case .denied:
                logger.error("Location access denied")
                Task { @MainActor in
                    isAuthorized = false
                    currentLocation = nil
                }
                
            case .network:
                logger.error("Network error while getting location")
                
            case .headingFailure:
                logger.warning("Heading update failed")
                
            default:
                logger.error("Location error: \(clError.localizedDescription)")
            }
        } else {
            logger.error("Unknown location error: \(error.localizedDescription)")
        }
    }
    
    /**
     * Handles location manager entering region (for geofencing)
     */
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        logger.info("Entered region: \(region.identifier)")
        // Geofencing implementation would go here
    }
    
    /**
     * Handles location manager exiting region (for geofencing)
     */
    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        logger.info("Exited region: \(region.identifier)")
        // Geofencing implementation would go here
    }
}

// MARK: - Convenience Extensions

extension LocationService {
    
    /**
     * Gets the distance between current location and a target location
     * 
     * - Parameter targetLocation: The target location to measure distance to
     * - Returns: Distance in meters, nil if current location unavailable
     */
    func distanceTo(_ targetLocation: CLLocation) -> CLLocationDistance? {
        guard let current = currentLocation else { return nil }
        return current.distance(from: targetLocation)
    }
    
    /**
     * Gets the distance between current location and coordinates
     * 
     * - Parameter latitude: Target latitude
     * - Parameter longitude: Target longitude
     * - Returns: Distance in meters, nil if current location unavailable
     */
    func distanceTo(latitude: Double, longitude: Double) -> CLLocationDistance? {
        let targetLocation = CLLocation(latitude: latitude, longitude: longitude)
        return distanceTo(targetLocation)
    }
    
    /**
     * Checks if current location is within a specified radius of target coordinates
     * 
     * - Parameter latitude: Target latitude
     * - Parameter longitude: Target longitude
     * - Parameter radius: Radius in meters
     * - Returns: Boolean indicating if within radius
     */
    func isWithinRadius(latitude: Double, longitude: Double, radius: Double) -> Bool {
        guard let distance = distanceTo(latitude: latitude, longitude: longitude) else { return false }
        return distance <= radius
    }
}
