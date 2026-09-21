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
        let alert = UIAlertController(
            title: L10n.text(
                "settings_account__button_quit_account",
                fallback: "Quit account"
            ),
            message: L10n.format(
                "account__quit_dialog__message_format",
                fallback: "You are quitting %1$@ account. Account data will be deleted from this device. Your data on server will not be affected.",
                arguments: [jid]
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: L10n.text("common__action__cancel", fallback: "Cancel"),
            style: .cancel,
            handler: nil
        ))
        alert.addAction(UIAlertAction(
            title: L10n.text("common__action__quit", fallback: "Quit"),
            style: .destructive,
            handler: { (_) in
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
