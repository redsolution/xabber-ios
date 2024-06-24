//
//  UIViewController+Modal.swift
//  xabber
//
//  Created by Игорь Болдин on 27.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

func showModal(_ vc: UIViewController, replaceParent: Bool = true) {
    let parent: UIViewController?
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
            popoverController.permittedArrowDirections = []
        }
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
            presenter.navigationController?.pushViewController(vc, animated: true)
        case .split:
            presenter.splitViewController?.showDetailViewController(UINavigationController(rootViewController: vc), sender: presenter)
            presenter.splitViewController?.hide(.primary)
    }
}
