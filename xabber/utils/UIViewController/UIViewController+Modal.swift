//
//  UIViewController+Modal.swift
//  xabber
//
//  Created by Игорь Болдин on 27.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

@discardableResult
func showModal(_ vc: UIViewController, parent parentVc: UIViewController? = nil, replaceParent: Bool = true) -> Bool {
    var parent: UIViewController? = parentVc
//    if (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc != nil {
//        parent = (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc
//    } else {
    switch CommonConfigManager.shared.interfaceType {
        case .tabs:
            parent = AppRootCoordinator.active?.tabController
        case .split:
            parent = AppRootCoordinator.active?.splitController
    }
    parent = parent ?? SceneWindowProvider.presentationRootViewController
    guard let parent = parent else {
        return false
    }
    
    if replaceParent {
        AppRootCoordinator.active?.currentPresentedVc = vc
        (UIApplication.shared.delegate as? AppDelegate)?.currentPresentedVc = vc
    }
//    }
    let nvc = UINavigationController(rootViewController: vc)
    nvc.modalPresentationStyle = .formSheet
    nvc.modalTransitionStyle = .coverVertical
    if UIDevice.current.userInterfaceIdiom == .pad {
        if let popoverController = nvc.popoverPresentationController {
            popoverController.sourceView = parent.view
            popoverController.sourceRect = CGRect(x: parent.view.bounds.midX, y: parent.view.bounds.midY, width: 0, height: 0)
            popoverController.permittedArrowDirections = [.any]
        }
    }
    
    if let adaptiveDelegate = parentVc as? UIAdaptivePresentationControllerDelegate {
        nvc.presentationController?.delegate = adaptiveDelegate
    }
    
    parent.definesPresentationContext = true
    if let presentedViewController = parent.presentedViewController {
        presentedViewController.present(nvc, animated: true)
    } else {
        parent.present(nvc, animated: true, completion: nil)
    }
    return true
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
                    AppRootCoordinator.active?.splitController?.showDetailViewController(NavBarController(rootViewController: vc), sender: currentVc)
                    AppRootCoordinator.active?.splitController?.hide(.primary)
                }
            } else {
                AppRootCoordinator.active?.splitController?.showDetailViewController(NavBarController(rootViewController: vc), sender: currentVc)
                AppRootCoordinator.active?.splitController?.hide(.primary)
            }
    }
}
