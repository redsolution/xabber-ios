//
//  GroupchatRightsDelegateProtocol.swift
//  xabber
//
//  Created by Игорь Болдин on 29.10.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//
import Foundation

struct GroupchatPermission: Codable {
    let role: String
    let name: String
    let status: Bool
    let displayName: String
    let expires: Double?
}

protocol GroupchatPermissionsDelegate {
    func groupchatPermissionsList(default permissions: [GroupchatPermission], elementId: String)
    func groupchatPermissionsList(user userId: String,  permissions: [GroupchatPermission], elementId: String)
//    func receigroupchatRights
}
