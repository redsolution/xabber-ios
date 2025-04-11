//
//  ToastPresenter.swift
//  clandestino
//
//  Created by Игорь Болдин on 27.04.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
struct ToastPresenter {
       
    func present(message: String, image: UIImage? = nil, danger: Bool = false) {
        UIApplication.shared.keyWindow?.rootViewController?.view.makeToast(
            message,
            duration: 2.0,
            title: nil,
            image: image,
            danger: danger) { tap in
                if tap {
                    UIApplication.shared.keyWindow?.rootViewController?.view.hideToast()
                }
            }
    }
    
    func presentSuccess(message: String) {
        UIApplication.shared.keyWindow?.rootViewController?.view.makeToast(
            message,
            duration: 2.0,
            title: nil,
            image: imageLiteral("checkmark")) { tap in
                if tap {
                    UIApplication.shared.keyWindow?.rootViewController?.view.hideToast()
                }
            }
    }
    
    func presentError(message: String) {
        UIApplication.shared.keyWindow?.rootViewController?.view.makeToast(
            message,
            duration: 2.0,
            title: nil,
            image: imageLiteral("exclamationmark.circle"),
            danger: true) { tap in
                if tap {
                    UIApplication.shared.keyWindow?.rootViewController?.view.hideToast()
                }
            }
    }
}
