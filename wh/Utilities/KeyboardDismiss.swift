//
//  KeyboardDismiss.swift
//  WorkHaven
//

import SwiftUI
import UIKit

enum KeyboardDismiss {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

/// Dismisses the keyboard when the user taps outside a text field (does not block buttons).
struct DismissKeyboardOnTapModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture().onEnded { _ in
                KeyboardDismiss.dismiss()
            }
        )
    }
}

extension View {
    func dismissKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTapModifier())
    }
}
