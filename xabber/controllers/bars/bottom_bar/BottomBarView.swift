//
//  BottomBarView.swift
//  xabber
//
//  Created by Игорь Болдин on 23.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class BottomBarView: UIView {
    
    enum ApplicationConnectionState {
        case connecting
        case normal
        case offline
    }
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .center
        
        return stack
    }()
    
    let blurredEffectView: UIVisualEffectView = {
        let blurEffect = UIBlurEffect(style: .systemMaterial)
        let blurredEffectView = UIVisualEffectView(effect: blurEffect)
        
        return blurredEffectView
    }()
    
    let leftButton: UIButton = {
        let button = UIButton()
        
        button.setImage(UIImage(systemName: "line.3.horizontal.decrease.circle")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = .systemBlue
        
        return button
    }()
    
    let rightButton: UIButton = {
        let button = UIButton()
        
        button.setImage(UIImage(systemName: "plus")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = .systemBlue
        
        return button
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.text = "Xabber"
        label.textAlignment = .center
        
        return label
    }()
    
    private var currentConnectionState: ApplicationConnectionState = .offline
    
    open var connectionState: ApplicationConnectionState {
        set {
            switch newValue {
                case .connecting:
                    self.titleLabel.text = "Connecting..."
                case .normal:
                    self.titleLabel.text = CommonConfigManager.shared.config.app_name
                case .offline:
                    self.titleLabel.text = "Offline"
            }
            self.titleLabel.sizeToFit()
            self.titleLabel.layoutIfNeeded()
            self.currentConnectionState = newValue
        } get {
            return currentConnectionState
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(blurredEffectView)
        self.addSubview(stack)
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            stack.fillSuperviewWithOffset(top: 0, bottom: bottomInset, left: 8, right: 8)
        } else {
            stack.fillSuperviewWithOffset(top: 0, bottom: 0, left: 8, right: 8)
        }
        
        stack.addArrangedSubview(leftButton)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(rightButton)
        NSLayoutConstraint.activate([
            leftButton.widthAnchor.constraint(equalToConstant: 44),
            rightButton.widthAnchor.constraint(equalToConstant: 44),
            leftButton.heightAnchor.constraint(equalToConstant: 36),
            rightButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        rightButton.addTarget(self, action: #selector(onRightButtonTouchUp), for: .touchUpInside)
        leftButton.addTarget(self, action: #selector(onLeftButtonTouchUp), for: .touchUpInside)
    }
    
    func updateFrame(to frame: CGRect) {
        self.frame = frame
        self.blurredEffectView.frame = CGRect(origin: .zero, size: frame.size)
    }
    
    var splitViewController: UISplitViewController?
    
    @objc
    func onRightButtonTouchUp(_ sender: UIButton) {
        let vc = NewEntityViewController()
        if let splitVc = self.splitViewController {
            showModal(vc, from: splitVc)
        }
    }
    
    open var leftCallback: (() -> Void)? = nil
    
    @objc
    func onLeftButtonTouchUp(_ sender: UIButton) {
        leftCallback?()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
}
