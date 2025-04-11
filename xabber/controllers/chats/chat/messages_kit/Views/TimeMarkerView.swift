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
    
    func configure(text: NSAttributedString, indicator: IndicatorType, withBackplate: Bool) {
        if withBackplate {
            let timeMarkerString = NSAttributedString(
                string: text.string,
                attributes: [
                    NSAttributedString.Key.foregroundColor: UIColor.white,
                    NSAttributedString.Key.font: UIFont.systemFont(ofSize: 11, weight: .regular)
                ]
            )
            
            self.textLabel.attributedText = timeMarkerString
        } else {
            self.textLabel.attributedText = text
        }
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
    
    func update(frame: CGRect, indicator: IndicatorType, radius rad: CGFloat) {
        switch indicator {
            case .none:
                self.indicatorWidth = 0
            default:
                self.indicatorWidth = 12
        }
        self.frame = frame
        let radius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.smooth.image.timestamp.getRadiusFor(index: "16")
        self.layer.cornerRadius = radius.leftBottom
        self.layer.masksToBounds = true
        self.textLabel.textColor = UIColor.white
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
