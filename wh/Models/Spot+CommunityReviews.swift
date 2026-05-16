//
//  Spot+CommunityReviews.swift
//  WorkHaven
//

import Foundation

extension Spot {

  /// Reviews with a star rating, highest stars first.
  var sortedCommunityReviews: [UserRating] {
    guard let ratings = userRatings?.allObjects as? [UserRating] else { return [] }
    return ratings
      .filter { $0.stars >= 1 }
      .sorted { lhs, rhs in
        if lhs.stars != rhs.stars { return lhs.stars > rhs.stars }
        return lhs.hasTips && !rhs.hasTips
      }
  }

  var hasCommunityReviewNotes: Bool {
    sortedCommunityReviews.contains { $0.hasTips }
  }

  /// System-generated blurb (baseline placeholder, web research, or review aggregate).
  var showsSpotSummary: Bool {
    let text = tips.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text != "No tips available" else { return false }
    return true
  }
}
