////
////  GroupchatSettingsRestrictUserViewController.swift
////  xabber
////
////  Created by Игорь Болдин on 13.11.2025.
////  Copyright © 2025 Igor Boldin. All rights reserved.
////
//
import Foundation
import UIKit

class GroupchatSettingsRestrictUserViewController: GroupchatSettingsPromoteAdminViewController {
    override var permissionsScope: String {
        get {
            return "member"
        }
    }
}
