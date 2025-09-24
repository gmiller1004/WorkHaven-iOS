//
//  UserRating+CoreDataClass.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import Foundation
import CoreData

/**
 * UserRating represents an individual user's rating and feedback for a work spot.
 * Each UserRating is associated with a specific Spot and contains detailed
 * feedback about WiFi quality, noise level, outlet availability, and tips.
 */
@objc(UserRating)
public class UserRating: NSManagedObject {
    
    // MARK: - Computed Properties
    
    /// Returns a formatted description of the WiFi rating
    public var wifiRatingDescription: String {
        switch wifi {
        case 1:
            return "Poor (1/5)"
        case 2:
            return "Fair (2/5)"
        case 3:
            return "Good (3/5)"
        case 4:
            return "Very Good (4/5)"
        case 5:
            return "Excellent (5/5)"
        default:
            return "Not Rated"
        }
    }
    
    /// Returns a formatted description of the noise level
    public var noiseLevelDescription: String {
        switch noise.lowercased() {
        case "quiet", "very quiet":
            return "🟢 \(noise)"
        case "moderate", "medium":
            return "🟡 \(noise)"
        case "loud", "very loud", "noisy":
            return "🔴 \(noise)"
        default:
            return "⚪ \(noise)"
        }
    }
    
    /// Returns a formatted description of outlet availability
    public var outletAvailabilityDescription: String {
        return plugs ? "✅ Outlets Available" : "❌ No Outlets"
    }
    
    /// Returns whether this rating has any tips or notes
    public var hasTips: Bool {
        return !tip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// Returns a summary of all rating aspects
    public var ratingSummary: String {
        var summary = "WiFi: \(wifiRatingDescription)"
        summary += " • Noise: \(noiseLevelDescription)"
        summary += " • Outlets: \(outletAvailabilityDescription)"
        
        if hasTips {
            summary += " • Has Tips"
        }
        
        return summary
    }
    
    // MARK: - Helper Methods
    
    /// Updates the rating with new values and validates input
    public func updateRating(
        wifi: Int16,
        noise: String,
        plugs: Bool,
        tip: String
    ) {
        self.wifi = max(1, min(5, wifi)) // Clamp between 1-5
        self.noise = noise.trimmingCharacters(in: .whitespacesAndNewlines)
        self.plugs = plugs
        self.tip = tip.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Returns a star rating string for WiFi quality
    public var wifiStarRating: String {
        let filledStars = String(repeating: "★", count: Int(wifi))
        let emptyStars = String(repeating: "☆", count: max(0, 5 - Int(wifi)))
        return filledStars + emptyStars
    }
    
    /// Returns an emoji representation of the noise level
    public var noiseEmoji: String {
        switch noise.lowercased() {
        case "very quiet", "silent":
            return "🔇"
        case "quiet":
            return "🔉"
        case "moderate", "medium":
            return "🔊"
        case "loud":
            return "📢"
        case "very loud", "noisy":
            return "📣"
        default:
            return "🔊"
        }
    }
    
    /// Returns an emoji representation of outlet availability
    public var outletEmoji: String {
        return plugs ? "🔌" : "🚫"
    }
    
    /// Formats the tip text with proper line breaks
    public var formattedTip: String {
        return tip.replacingOccurrences(of: "\\n", with: "\n")
    }
    
    /// Returns a concise one-line summary
    public var oneLineSummary: String {
        return "WiFi: \(wifi)/5 • Noise: \(noise) • \(plugs ? "Outlets" : "No Outlets")"
    }
    
    /// Returns a detailed multi-line summary
    public var detailedSummary: String {
        var summary = "📶 WiFi: \(wifiStarRating) (\(wifi)/5)\n"
        summary += "🔊 Noise: \(noiseEmoji) \(noise)\n"
        summary += "🔌 Outlets: \(outletEmoji) \(plugs ? "Available" : "Not Available")\n"
        
        if hasTips {
            summary += "💡 Tips: \(formattedTip)"
        }
        
        return summary
    }
    
    // MARK: - Validation
    
    /// Validates that the rating has valid data
    public var isValid: Bool {
        return wifi >= 1 && wifi <= 5 &&
               !noise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               spot != nil
    }
    
    /// Returns validation errors if any
    public var validationErrors: [String] {
        var errors: [String] = []
        
        if wifi < 1 || wifi > 5 {
            errors.append("WiFi rating must be between 1 and 5")
        }
        
        if noise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Noise level is required")
        }
        
        if spot == nil {
            errors.append("Associated spot is required")
        }
        
        return errors
    }
    
    /// Returns whether this rating is recent (within last 30 days)
    public var isRecent: Bool {
        guard let managedObjectContext = managedObjectContext else {
            return false
        }
        
        // Note: This assumes we have a timestamp field. If not available in the model,
        // you might want to add a createdDate field to track when ratings were created.
        // For now, we'll return true as we don't have this field in the current model.
        return true
    }
    
    // MARK: - Static Helper Methods
    
    /// Returns common noise level options
    public static var commonNoiseLevels: [String] {
        return [
            "Very Quiet",
            "Quiet", 
            "Moderate",
            "Loud",
            "Very Loud"
        ]
    }
    
    /// Returns WiFi rating options with descriptions
    public static var wifiRatingOptions: [(Int16, String)] {
        return [
            (1, "Poor - Very slow or unreliable"),
            (2, "Fair - Slow but usable"),
            (3, "Good - Decent speed and reliability"),
            (4, "Very Good - Fast and reliable"),
            (5, "Excellent - Very fast and always reliable")
        ]
    }
}
