//
//  DeleteAccountPresenter.swift
//  xabber_test_xmpp
//
//  Created by Igor Boldin on 05/06/2019.
//  Copyright © 2019 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

struct QuitAccountPresenter {
    let jid: String
    
    
    func present(in view: UIViewController, animated: Bool, completion: (()->Void)?) {
        let alert = UIAlertController(title: "Quit account", message: ["You are quitting", jid, "account. Account data will be deleted from this device. Your data on server will not be affected."].joined(separator: " "), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Quit", style: .destructive, handler: { (_) in
            completion?()
        }))
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = view.view
                popoverController.sourceRect = CGRect(x: view.view.bounds.midX, y: view.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        view.present(alert, animated:  animated, completion: nil)
    }
}
