//
//  ThemeManager.swift
//  WorkHaven
//
//  Created by WorkHaven Team on 2024
//  Copyright © 2024 WorkHaven. All rights reserved.
//

import UIKit
import SwiftUI

/**
 * ThemeManager provides centralized UI styling for the WorkHaven app.
 * Manages colors, fonts, spacing, and other design tokens to ensure
 * consistent visual design throughout the application.
 */
class ThemeManager {
    
    // MARK: - Singleton
    static let shared = ThemeManager()
    
    // MARK: - Private Initialization
    private init() {}
    
    // MARK: - Colors
    
    /**
     * WorkHaven color palette with warm, coffee-inspired tones
     */
    struct Colors {
        /// Warm brown color for primary elements - Mocha (#8B5E3C)
        static let mocha = UIColor(hex: "#8B5E3C")
        
        /// Light cream color for backgrounds - Latte (#FFF8E7)
        static let latte = UIColor(hex: "#FFF8E7")
        
        /// Vibrant orange color for accents - Coral (#F28C38)
        static let coral = UIColor(hex: "#F28C38")
        
        /// Additional semantic colors for better UX
        static let success = UIColor(hex: "#28A745")
        static let warning = UIColor(hex: "#FFC107")
        static let error = UIColor(hex: "#DC3545")
        static let info = UIColor(hex: "#17A2B8")
        
        /// Neutral colors for text and UI elements
        static let darkGray = UIColor(hex: "#343A40")
        static let mediumGray = UIColor(hex: "#6C757D")
        static let lightGray = UIColor(hex: "#F8F9FA")
        static let white = UIColor(hex: "#FFFFFF")
        static let black = UIColor(hex: "#000000")
    }
    
    // MARK: - Fonts
    
    /**
     * Typography system using Avenir Next font family
     */
    struct Fonts {
        /// Regular weight font for body text
        static func regular(size: CGFloat) -> UIFont {
            return UIFont(name: "AvenirNext-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
        }
        
        /// Bold weight font for headings and emphasis
        static func bold(size: CGFloat) -> UIFont {
            return UIFont(name: "AvenirNext-Bold", size: size) ?? UIFont.boldSystemFont(ofSize: size)
        }
        
        /// Medium weight font for subheadings
        static func medium(size: CGFloat) -> UIFont {
            return UIFont(name: "AvenirNext-Medium", size: size) ?? UIFont.systemFont(ofSize: size, weight: .medium)
        }
        
        /// Demi bold weight font for buttons and labels
        static func demiBold(size: CGFloat) -> UIFont {
            return UIFont(name: "AvenirNext-DemiBold", size: size) ?? UIFont.systemFont(ofSize: size, weight: .semibold)
        }
        
        // MARK: - Predefined Font Sizes
        
        /// Large title font (34pt)
        static var largeTitle: UIFont { bold(size: 34) }
        
        /// Title font (28pt)
        static var title: UIFont { bold(size: 28) }
        
        /// Headline font (17pt, bold)
        static var headline: UIFont { bold(size: 17) }
        
        /// Body font (17pt, regular)
        static var body: UIFont { regular(size: 17) }
        
        /// Callout font (16pt, regular)
        static var callout: UIFont { regular(size: 16) }
        
        /// Subheadline font (15pt, regular)
        static var subheadline: UIFont { regular(size: 15) }
        
        /// Footnote font (13pt, regular)
        static var footnote: UIFont { regular(size: 13) }
        
        /// Caption font (12pt, regular)
        static var caption: UIFont { regular(size: 12) }
        
        /// Button font (17pt, medium)
        static var button: UIFont { medium(size: 17) }
    }
    
    // MARK: - Spacing
    
    /**
     * Consistent spacing system for layout and margins
     */
    struct Spacing {
        /// Small spacing (8pt) - for tight layouts
        static let small: CGFloat = 8.0
        
        /// Medium spacing (16pt) - standard spacing
        static let medium: CGFloat = 16.0
        
        /// Large spacing (24pt) - for section separation
        static let large: CGFloat = 24.0
        
        /// Extra large spacing (32pt) - for major sections
        static let extraLarge: CGFloat = 32.0
        
        /// Additional spacing options
        static let xs: CGFloat = 4.0      // Extra small
        static let sm: CGFloat = 8.0      // Small (alias for small)
        static let md: CGFloat = 16.0     // Medium (alias for medium)
        static let lg: CGFloat = 24.0     // Large (alias for large)
        static let xl: CGFloat = 32.0     // Extra large (alias for extraLarge)
        static let xxl: CGFloat = 48.0    // Extra extra large
    }
    
    // MARK: - Corner Radius
    
    /**
     * Consistent corner radius values for UI elements
     */
    struct CornerRadius {
        static let small: CGFloat = 4.0
        static let medium: CGFloat = 8.0
        static let large: CGFloat = 12.0
        static let extraLarge: CGFloat = 16.0
        static let circular: CGFloat = 999.0 // For circular elements
    }
    
    // MARK: - Shadows
    
    /**
     * Shadow configurations for elevation and depth
     */
    struct Shadows {
        static let light = ShadowConfig(
            color: Colors.black.withAlphaComponent(0.1),
            offset: CGSize(width: 0, height: 1),
            radius: 3,
            opacity: 0.1
        )
        
        static let medium = ShadowConfig(
            color: Colors.black.withAlphaComponent(0.15),
            offset: CGSize(width: 0, height: 2),
            radius: 6,
            opacity: 0.15
        )
        
        static let heavy = ShadowConfig(
            color: Colors.black.withAlphaComponent(0.2),
            offset: CGSize(width: 0, height: 4),
            radius: 12,
            opacity: 0.2
        )
    }
    
    // MARK: - SwiftUI Color Equivalents
    
    /**
     * SwiftUI Color equivalents for all theme colors
     */
    struct SwiftUIColors {
        /// Warm brown color for primary elements - Mocha
        static let mocha = Color(Colors.mocha)
        
        /// Light cream color for backgrounds - Latte
        static let latte = Color(Colors.latte)
        
        /// Vibrant orange color for accents - Coral
        static let coral = Color(Colors.coral)
        
        /// Semantic colors
        static let success = Color(Colors.success)
        static let warning = Color(Colors.warning)
        static let error = Color(Colors.error)
        static let info = Color(Colors.info)
        
        /// Neutral colors
        static let darkGray = Color(Colors.darkGray)
        static let mediumGray = Color(Colors.mediumGray)
        static let lightGray = Color(Colors.lightGray)
        static let white = Color(Colors.white)
        static let black = Color(Colors.black)
    }
    
    // MARK: - SwiftUI Font Equivalents
    
    /**
     * SwiftUI Font equivalents for all theme fonts
     */
    struct SwiftUIFonts {
        static var largeTitle: Font { Font(Fonts.largeTitle) }
        static var title: Font { Font(Fonts.title) }
        static var headline: Font { Font(Fonts.headline) }
        static var body: Font { Font(Fonts.body) }
        static var callout: Font { Font(Fonts.callout) }
        static var subheadline: Font { Font(Fonts.subheadline) }
        static var footnote: Font { Font(Fonts.footnote) }
        static var caption: Font { Font(Fonts.caption) }
        static var button: Font { Font(Fonts.button) }
    }
    
    // MARK: - Animation Durations
    
    /**
     * Consistent animation timing for smooth transitions
     */
    struct Animation {
        static let fast: TimeInterval = 0.2
        static let normal: TimeInterval = 0.3
        static let slow: TimeInterval = 0.5
        static let verySlow: TimeInterval = 0.8
    }
    
    // MARK: - Helper Methods
    
    /**
     * Applies the theme to the app's appearance
     */
    func applyTheme() {
        // Configure navigation bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Colors.latte
        appearance.titleTextAttributes = [
            .foregroundColor: Colors.mocha,
            .font: Fonts.bold(size: 18)
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: Colors.mocha,
            .font: Fonts.bold(size: 34)
        ]
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        
        // Configure tab bar appearance
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = Colors.latte
        tabBarAppearance.selectionIndicatorTintColor = Colors.coral
        
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }
}

// MARK: - Shadow Configuration

/**
 * Configuration structure for shadow properties
 */
struct ShadowConfig {
    let color: UIColor
    let offset: CGSize
    let radius: CGFloat
    let opacity: Float
}

// MARK: - UIColor Extension

extension UIColor {
    
    /**
     * Initialize UIColor from a hex string
     * Supports formats: "#RRGGBB", "#AARRGGBB", "RRGGBB", "AARRGGBB"
     */
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
    
    /**
     * Returns the hex string representation of the color
     */
    var hexString: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        
        getRed(&r, green: &g, blue: &b, alpha: &a)
        
        let rgb: Int = (Int)(r * 255) << 16 | (Int)(g * 255) << 8 | (Int)(b * 255) << 0
        
        return String(format: "#%06x", rgb)
    }
    
    /**
     * Returns the hex string with alpha component
     */
    var hexStringWithAlpha: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        
        getRed(&r, green: &g, blue: &b, alpha: &a)
        
        let rgba: Int = (Int)(a * 255) << 24 | (Int)(r * 255) << 16 | (Int)(g * 255) << 8 | (Int)(b * 255) << 0
        
        return String(format: "#%08x", rgba)
    }
}

// MARK: - SwiftUI Extensions

extension Color {
    
    /**
     * Initialize SwiftUI Color from a hex string
     */
    init(hex: String) {
        self.init(UIColor(hex: hex))
    }
}

// MARK: - View Extensions for Easy Theme Application

extension View {
    
    /**
     * Apply WorkHaven theme colors to SwiftUI views
     */
    func workHavenBackground() -> some View {
        self.background(ThemeManager.SwiftUIColors.latte)
    }
    
    /**
     * Apply WorkHaven primary color
     */
    func workHavenPrimary() -> some View {
        self.foregroundColor(ThemeManager.SwiftUIColors.mocha)
    }
    
    /**
     * Apply WorkHaven accent color
     */
    func workHavenAccent() -> some View {
        self.foregroundColor(ThemeManager.SwiftUIColors.coral)
    }
}
