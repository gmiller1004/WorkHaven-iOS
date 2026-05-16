//
//  SpotRatingCalculator.swift
//  WorkHaven
//

import Foundation
import CoreData

enum SpotRatingCalculator {

  /// Average of user-submitted star ratings only.
  static func communityStarRating(for spot: Spot) -> Double? {
    spot.communityStarRating
  }

  static func outletsDisplayLabel(outlets: NSNumber?) -> String {
    guard let outlets else { return "Unknown" }
    return outlets.boolValue ? "Available" : "Not Available"
  }
}
