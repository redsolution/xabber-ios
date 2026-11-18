//
//  TimeMarkerView.swift
//  xabber
//
//  Created by Игорь Болдин on 17.03.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class TimeMarkerView: UIView {
    
    internal var indicatorWidth: CGFloat = 0
    internal var withBackplate: Bool = false
    
    internal let indicatorView: UIButton = {
        let view = UIButton(frame: CGRect(square: 12))
        
        view.imageView?.contentMode = .scaleAspectFit
        
        return view
    }()
    
    internal let textLabel: MessageLabel = {
        let label = MessageLabel(frame: .zero)
        
        return label
    }()
    
    func setupSubviews() {
        addSubview(textLabel)
        addSubview(indicatorView)
    }

    nonisolated static func backplateText(_ text: NSAttributedString) -> NSAttributedString {
        NSAttributedString(
            string: text.string,
            attributes: [
                .foregroundColor: UIColor.white,
                .font: UIFont.systemFont(ofSize: 11, weight: .regular)
            ]
        )
    }
    
    func configure(text: NSAttributedString, indicator: IndicatorType, withBackplate: Bool) {
        self.textLabel.textColor = UIColor(red: 158.0 / 255.0, green: 158.0 / 255.0, blue: 158.0 / 255.0, alpha: 1)
        self.textLabel.attributedText = withBackplate ? Self.backplateText(text) : text
        switch indicator {
            case .none:
                self.indicatorView.setImage(nil, for: .normal)
            case .sending:
                self.indicatorView.setImage(imageLiteral("clock"), for: .normal)
                self.indicatorView.tintColor = MDCPalette.blue.tint500
            case .sended:
                self.indicatorView.setImage(imageLiteral("xabber.checkmark"), for: .normal)
                self.indicatorView.tintColor = MDCPalette.grey.tint500
            case .received:
                self.indicatorView.setImage(imageLiteral("xabber.checkmark"), for: .normal)
                self.indicatorView.tintColor = MDCPalette.green.tint500
            case .read:
                self.indicatorView.setImage(imageLiteral("xabber.checkmark.double"), for: .normal)
                self.indicatorView.tintColor = MDCPalette.green.tint500
            case .error:
                self.indicatorView.setImage(imageLiteral("exclamationmark.circle.fill"), for: .normal)
                self.indicatorView.tintColor = MDCPalette.red.tint500
        }
        if withBackplate {
            self.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        } else {
            self.backgroundColor = .clear
        }
    }

    func updateImageStyle(frame: CGRect, indicator: IndicatorType, tail: String, cornerRadius: String) {
        let bubbles = CommonConfigManager.shared.messageStyleConfig.messageBubbles
        let timestamp: MessageStyleConfig.MessageRadius
        switch MessageStyleConfig.MessageBubbleContainer.CodingKeys(rawValue: tail) {
        case .smooth: timestamp = bubbles.smooth.image.timestamp
        case .bubble: timestamp = bubbles.bubble.image.timestamp
        case .bubbles: timestamp = bubbles.bubbles.image.timestamp
        case .curvy: timestamp = bubbles.curvy.image.timestamp
        case .stripes: timestamp = bubbles.stripes.image.timestamp
        case .transparent: timestamp = bubbles.transparent.image.timestamp
        case .wedge: timestamp = bubbles.wedge.image.timestamp
        default: timestamp = bubbles.noTail.image.timestamp
        }
        update(frame: frame, indicator: indicator, radius: timestamp.getRadiusFor(index: cornerRadius).leftBottom)
    }
    
    func update(frame: CGRect, indicator: IndicatorType, radius rad: CGFloat) {
        switch indicator {
            case .none:
                self.indicatorWidth = 0
            default:
                self.indicatorWidth = 12
        }
        self.frame = frame
        self.layer.cornerRadius = rad
        self.layer.masksToBounds = true
//        self.textLabel.textColor = UIColor.white
        self.textLabel.frame = CGRect(
            origin: .zero.padding(x: 4, y: 0),
            size: CGSize(width: frame.width - self.indicatorWidth, height: frame.height).padding(width: 8, height: 0)
        )
        self.textLabel.baselineAdjustment = .alignCenters
        self.indicatorView.frame = CGRect(
            origin: CGPoint(x: frame.width - self.indicatorWidth - 4, y: 1),
            size: CGSize(width: frame.height, height: frame.height).padding(width: 2, height: 2)
        )
    }
}
