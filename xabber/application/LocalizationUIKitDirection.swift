//
//  LocalizationUIKitDirection.swift
//  xabber
//

import UIKit

enum LocalizationUIKitDirection {
    static func semanticAttribute(
        for direction: LocalizationLayoutDirection
    ) -> UISemanticContentAttribute {
        switch direction {
        case .leftToRight:
            return .forceLeftToRight
        case .rightToLeft:
            return .forceRightToLeft
        }
    }

    static func apply(_ context: LocalizationContext, to window: UIWindow) {
        let semanticAttribute = semanticAttribute(for: context.layoutDirection)
        window.semanticContentAttribute = semanticAttribute
        window.rootViewController?.view.semanticContentAttribute = semanticAttribute
    }
}
