//
//  AccountMasksManager.swift
//  xabber
//
//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation

class AccountMasksManager {
    open class var shared: AccountMasksManager {
        struct AccountMasksManagerSingleton {
            static let instance = AccountMasksManager()
        }
        return AccountMasksManagerSingleton.instance
    }
    
    var mask32pt: String = "circle_32pt"
    var mask48pt: String = "circle_48pt"
    var mask56pt: String = "circle_56pt"
    var mask128pt: String = "circle_128pt"
    var mask176pt: String = "circle_176pt"
    
    
    init() {
        guard let currentMask = load() else {
            let masks = masksList()
            if masks.first != nil {
                update(mask: masks.first!)
            }
            return
        }
        update(mask: currentMask)
    }
    
    
    public func masksList() -> [String] {
        guard let path = Bundle.main.path(forResource: "common_config", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let config = try? PropertyListDecoder().decode(CommonConfigManager.CommonConfig.self, from: xml) else {
                  return []
              }
        return config.avatar_masks
    }
    
    public func load() -> String? {
        guard let currentMask = SettingManager.shared.getKey(for: "", scope: .avatarMasks, key: "current_avatar_mask") else { return nil }
        return currentMask
    }
    
    public func update(mask: String) {
        mask32pt = mask + "_32pt"
        mask48pt = mask + "_48pt"
        mask56pt = mask + "_56pt"
        mask128pt = mask + "_128pt"
        mask176pt = mask + "_176pt"
    }
    
    public func save(mask: String) {
        SettingManager.shared.saveItem(for: "", scope: .avatarMasks, key: "current_avatar_mask", value: mask)
        update(mask: mask)
    }
}
