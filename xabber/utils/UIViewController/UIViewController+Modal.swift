//
//  UIViewController+Modal.swift
//  xabber
//
//  Created by Игорь Болдин on 27.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

func showModal(_ vc: UIViewController, parent parentVc: UIViewController? = nil, replaceParent: Bool = true) {
    var parent: UIViewController? = parentVc
//    if (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc != nil {
//        parent = (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc
//    } else {
    switch CommonConfigManager.shared.interfaceType {
        case .tabs:
            parent = (UIApplication.shared.delegate as? AppDelegate)?.tabController
        case .split:
            parent = (UIApplication.shared.delegate as? AppDelegate)?.splitController
    }
    
    if replaceParent {
        (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc = vc
    }
//    }
    let nvc = UINavigationController(rootViewController: vc)
    nvc.modalPresentationStyle = .formSheet
    nvc.modalTransitionStyle = .coverVertical
    if UIDevice.current.userInterfaceIdiom == .pad {
        if let popoverController = nvc.popoverPresentationController {
            popoverController.sourceView = parent?.view
            popoverController.sourceRect = CGRect(x: parent?.view.bounds.midX ?? 0, y: parent?.view.bounds.midY ?? 0, width: 0, height: 0)
            popoverController.permittedArrowDirections = [.any]
        }
    }
    
    if let adaptiveDelegate = parentVc as? UIAdaptivePresentationControllerDelegate {
        nvc.presentationController?.delegate = adaptiveDelegate
    }
    
    parent?.definesPresentationContext = true
    if parent?.presentedViewController != nil {
        parent?.presentedViewController?.present(nvc, animated: true)
    } else {
        parent?.present(nvc, animated: true, completion: nil)
    }
}

public func showStacked(_ vc: UIViewController, in presenter: UIViewController) {
    switch CommonConfigManager.shared.interfaceType {
        case .tabs:
//            presenter.splitViewController?.showDetailViewController(NavBarController(rootViewController: vc), sender: presenter)
            presenter.navigationController?.pushViewController(vc, animated: true)
        case .split:
//            presenter.splitViewController?.showDetailViewController(vc, sender: presenter)
            let nvc = UINavigationController(rootViewController: vc)
//            nvc.setNavigationBarHidden(false, animated: false)
//            nvc.setToolbarHidden(false, animated: false)
            
            
            presenter.splitViewController?.showDetailViewController(nvc, sender: presenter)
            presenter.splitViewController?.hide(.primary)
    }
}

public func showDetail(_ vc: UIViewController, currentVc: UIViewController?) {
    switch CommonConfigManager.shared.interfaceType {
        case .tabs:
            break
        case .split:
            if let currentVc = currentVc {
                currentVc.dismiss(animated: true) {
                    (UIApplication.shared.delegate as? AppDelegate)?.splitController?.showDetailViewController(NavBarController(rootViewController: vc), sender: currentVc)
                    (UIApplication.shared.delegate as? AppDelegate)?.splitController?.hide(.primary)
                }
            } else {
                (UIApplication.shared.delegate as? AppDelegate)?.splitController?.showDetailViewController(NavBarController(rootViewController: vc), sender: currentVc)
                (UIApplication.shared.delegate as? AppDelegate)?.splitController?.hide(.primary)
            }
    }
}
