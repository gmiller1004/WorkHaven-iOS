//
//  CommunitySpotNotifications.swift
//  WorkHaven
//

import Foundation

extension Notification.Name {
    /// Posted when a spot's community fields change (research, sync, review aggregation).
    static let communitySpotDidUpdate = Notification.Name("communitySpotDidUpdate")
}

enum CommunitySpotNotifications {
    static func postSpotUpdated(supabaseId: String?) {
        var userInfo: [String: Any] = [:]
        if let supabaseId {
            userInfo["supabaseId"] = supabaseId
        }
        NotificationCenter.default.post(
            name: .communitySpotDidUpdate,
            object: nil,
            userInfo: userInfo
        )
    }
}
