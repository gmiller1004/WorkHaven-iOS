//
//  Spot+CommunityRating.swift
//  WorkHaven
//

import Foundation

extension Spot {

  /// True when at least one community review includes an overall star rating.
  var hasCommunityStarRating: Bool {
    communityStarRating != nil
  }

  /// Average of user-submitted 1–5 star ratings (not derived from WiFi/noise/outlets).
  var communityStarRating: Double? {
    guard let ratings = userRatings?.allObjects as? [UserRating], !ratings.isEmpty else {
      return nil
    }
    let scored = ratings.filter { $0.stars >= 1 }
    guard !scored.isEmpty else { return nil }
    let sum = scored.reduce(0.0) { $0 + Double($1.stars) }
    let average = sum / Double(scored.count)
    return round(min(5.0, average) * 2.0) / 2.0
  }

  var communityRatingCount: Int {
    guard let ratings = userRatings?.allObjects as? [UserRating] else { return 0 }
    return ratings.filter { $0.stars >= 1 }.count
  }

  /// WiFi shown only after web research or community aggregation.
  var wifiKnown: Bool {
    switch enrichmentSource {
    case "web_search", "community_reviews":
      return true
    default:
      return false
    }
  }

  /// Noise shown only after web research or community aggregation.
  var noiseKnown: Bool {
    wifiKnown
  }
}
