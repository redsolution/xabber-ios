//
//  ToastPresenter.swift
//  clandestino
//
//  Created by Игорь Болдин on 27.04.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import Toast_Swift
//import SPIndicator

struct ToastPresenter {
    
    let message: String
    
    func present(animated: Bool) {
//        let indicatorView = SPIndicatorView(title: "Debug", message: message, preset: .done)
//
//        indicatorView.presentSide = .bottom
//        indicatorView.dismissByDrag = true
//
//
//        indicatorView.present(duration: 5)
        
        UIApplication.shared.keyWindow?.rootViewController?.view.makeToast(message)
    }
}
