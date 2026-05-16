//
//  Spot+Outlets.swift
//  WorkHaven
//

import Foundation

extension Spot {

  /// Whether we have a confident answer for outlet availability.
  var outletsKnown: Bool {
    switch enrichmentSource {
    case "community_reviews", "web_search":
      return outlets != nil
    case "baseline":
      return false
    default:
      return outlets != nil
    }
  }

  var hasOutlets: Bool {
    outletsKnown && outlets?.boolValue == true
  }

  /// Outlets value used in overall rating (nil when unknown).
  var outletsForRating: NSNumber? {
    outletsKnown ? outlets : nil
  }

  var outletsDisplayLabel: String {
    guard outletsKnown else { return "Unknown" }
    guard let outlets else { return "Unknown" }
    return outlets.boolValue ? "Available" : "Not Available"
  }

  /// Clears legacy false outlet flags for unrated baseline spots.
  func normalizeOutletUnknownState() {
    if enrichmentSource == "baseline" || enrichmentSource == nil {
      outlets = nil
    }
  }
}
