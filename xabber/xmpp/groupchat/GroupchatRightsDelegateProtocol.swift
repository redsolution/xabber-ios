//
//  GroupchatRightsDelegateProtocol.swift
//  xabber
//
//  Created by Игорь Болдин on 29.10.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//
import Foundation

class GroupchatPermission: Codable {
    var role: String
    var name: String
    var status: Bool
    var displayName: String
    var expires: Double?
    var seconds: Double?
    var fixed: Bool
    
    init(role: String, name: String, status: Bool, displayName: String, expires: Double? = nil, seconds: Double? = nil, fixed: Bool = false) {
        self.role = role
        self.name = name
        self.status = status
        self.displayName = displayName
        self.expires = expires
        self.seconds = seconds
        self.fixed = fixed
    }
}

extension Array where Element == GroupchatPermission {
    func findByPermissionName(_ name: String) -> GroupchatPermission? {
        first { $0.name == name }
    }
}
protocol GroupchatPermissionsDelegate {
    func groupchatPermissionsList(default permissions: [GroupchatPermission], elementId: String)
    func groupchatPermissionsList(user userId: String,  permissions: [GroupchatPermission], elementId: String)
//    func receigroupchatRights
}
