//
//  SpotProblemCategory.swift
//  WorkHaven
//

import Foundation

enum SpotProblemCategory: String, CaseIterable, Identifiable, Sendable {
    case outOfBusiness = "out_of_business"
    case outletsListedButNone = "outlets_listed_but_none"
    case outletsMissingButListed = "outlets_missing_but_listed"
    case wifiListedButNone = "wifi_listed_but_none"
    case wifiOverrated = "wifi_overrated"
    case noiseInaccurate = "noise_inaccurate"
    case wrongAddress = "wrong_address"
    case other = "other"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outOfBusiness:
            return "Place is closed or out of business"
        case .outletsListedButNone:
            return "Listing says outlets, but there aren't any"
        case .outletsMissingButListed:
            return "Outlets available, but listing says there aren't"
        case .wifiListedButNone:
            return "Listing says WiFi, but there isn't usable WiFi"
        case .wifiOverrated:
            return "WiFi quality is worse than listed"
        case .noiseInaccurate:
            return "Noise level is wrong"
        case .wrongAddress:
            return "Wrong address or location"
        case .other:
            return "Something else"
        }
    }
}
