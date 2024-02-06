//
//  CommonConfigManager.swift
//  clandestino
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

class CommonConfigManager: NSObject {
    open class var shared: CommonConfigManager {
        struct CommonConfigManagerSingleton {
            static let instance = CommonConfigManager()
        }
        return CommonConfigManagerSingleton.instance
    }
    
    public struct CommonConfig: Codable {
        var locked_conversation_type: String
        var allowed_hosts: [String]
        var avatar_masks: [String]
        var locked_avatar_mask: String
        var supports_multiaccounts: Bool
        var required_touch_id_or_password: Bool
        var onboarding_subtitle_text: String
        var app_name: String
        var bundle_id: String
        var push_bundle_id: String
        var domain: String
        var allow_registration: Bool
        var locked_host: String
        var support_calls: Bool
        var support_groupchats: Bool
        var allow_conversations_from_all_hosts: Bool
        var application_color: String
        var launch_screen_color: String
        var required_time_signature_for_messages: Bool
        var time_signature_for_messages_period: Int
        var motivating: Bool
        var use_file_enryption_by_default: Bool
        var support_jid: String
        var should_block_application_when_subscribtion_end: Bool
        var use_yubikey: Bool
        var afterburn_at_default: Bool
        var afterburn_default_interval: Int
        var server_registration_url: String
        var show_server_features: Bool
        var blur_screen_when_enter_background: Bool
        var support_subscribtions: Bool
        var show_text_logo: Bool
        var default_privacy_level: String
    }
    
    var config: CommonConfig
    
    override init() {
        guard let path = Bundle.main.path(forResource: "common_config", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let config = try? PropertyListDecoder().decode(CommonConfig.self, from: xml) else {
              fatalError()
          }
        self.config = config
        super.init()
    }
    
    func get() -> CommonConfig {
       return config
    }
    
}
