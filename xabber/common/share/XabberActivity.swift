//
//  XabberActivity.swift
//  xabber
//
//  Created by Admin on 19.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class XabberActivity: UIActivity {
    var _activityTitle: String
    var _activityImage = UIImage(imageLiteralResourceName: "xabber_icon_call_kit").resize(targetSize: CGSize(square: 60))
    
    init(title: String, image: UIImage) {
        self._activityTitle = title
        self._activityImage = image
    }
    
    override var activityTitle: String? {
        return _activityTitle
    }
    
    override var activityImage: UIImage? {
        return _activityImage
    }
    
    override var activityType: UIActivity.ActivityType? {
        return UIActivity.ActivityType("com.xabber.ios.activity")
    }
    
    internal let vc: XabberActivityViewController = {
        let owner = AccountManager.shared.users.first?.jid
        
        let view = XabberActivityViewController()
        view.owner = owner ?? ""
        
        return view
    }()
    
    override var activityViewController: UIViewController? {
        let nvc = NavBarController(rootViewController: vc)
        nvc.modalPresentationStyle = .formSheet
        nvc.modalTransitionStyle = .coverVertical
        
        return nvc
    }
    
    override class var activityCategory: UIActivity.Category {
        return .share
    }
    
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        var hasImage = false
        var hasString = false
        var hasUrl = false
        
        for item in activityItems {
            if item is UIImage {
                hasImage = true
            } else if item is String {
                hasString = true
            } else if item is NSURL {
                hasUrl = true
            }
        }
        
        if hasImage && hasUrl {
            return true
        } else if hasImage && hasString {
            return true
        }
        
        return false
    }
    
    override func prepare(withActivityItems activityItems: [Any]) {
        vc.activityItems = activityItems
    }
}
