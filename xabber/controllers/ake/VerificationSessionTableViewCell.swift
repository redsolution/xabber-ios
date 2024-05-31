//
//  VerificationSessionTableViewCell.swift
//  xabber
//
//  Created by Admin on 08.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

//class VerificationSessionTableViewCell: UITableViewCell {
//    static let cellName = "VerificationSessionTableViewCell"
//
//    var text: String
//    var secondaryText: String?
//    var buttonTitle: String?
//    var buttonKey: String?
//    
//    func configure(verificationState: VerificationSessionStorageItem.VerififcationState) {
//        switch verificationState {
//        case .sentRequest:
//            text = "Outgoing verification request"
//            secondaryText = "Verification request has been sent to the contact."
//            buttonTitle = "Cancel"
//            buttonKey = "cancel_verification"
//        case .receivedRequest:
//            text = "Incoming verification request"
//            secondaryText = "Contact want's to establish a trusted connection with you."
//            buttonTitle = "Accept"
//            buttonKey = "accept_verification"
//        case .acceptedRequest:
//            text = "Incoming verification request"
//            secondaryText = "You have accepted the verification request."
//            buttonTitle = "Show code"
//            buttonKey = "show_verification_code"
//        case .trusted:
//            text = "Verification successful"
//            secondaryText = "The verification session was completed successfully. Now you trust this contact's devices."
//            buttonTitle = "Close"
//            buttonKey = "hide_session"
//        case .rejected:
//            text = "Verification rejected"
//            secondaryText = "The verification session rejected."
//            buttonTitle = "Close"
//            buttonKey = "hide_session"
//        case .failed:
//            text = "Verification failed"
//            secondaryText = "The verification session failed."
//            buttonTitle = "Close"
//            buttonKey = "hide_session"
//        case .receivedRequestAccept:
//            text = "Outgoing verification request"
//            secondaryText = "The contact accepted the verification request."
//            buttonTitle = "Enter the code"
//            buttonKey = "enter_verification_code"
//        default:
//            text = "In process..."
//            secondaryText = nil
//            buttonTitle = nil
//            buttonKey = nil
//        }
//        
//        var cellConfig = self.defaultContentConfiguration()
//        cellConfig.image = UIImage(systemName: "lock.circle.fill")?.upscale(dimension: 40).withTintColor(.systemBlue)
//        cellConfig.text = text
//        cellConfig.secondaryText = secondaryText
//        
//        self.contentConfiguration = cellConfig
//        
//    }
//    
//    override func prepareForReuse() {
//        super.prepareForReuse()
//        
//        self.text = ""
//        self.secondaryText = nil
//        self.buttonTitle = nil
//        self.buttonKey = nil
//    }
//    
//    override open func layoutSubviews() {
//        super.layoutSubviews()
//    }
//    
//    required init?(coder aDecoder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
//    }
//}
