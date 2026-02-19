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
import UIKit.UIFont

class CommonConfigManager: NSObject {
    open class var shared: CommonConfigManager {
        struct CommonConfigManagerSingleton {
            static let instance = CommonConfigManager()
        }
        return CommonConfigManagerSingleton.instance
    }
    
    
    enum SymbolWeight: String {
        case ultraLight = "ultraLight"
        case thin = "thin"
        case light = "light"
        case regular = "regular"
        case medium = "medium"
        case semibold = "semibold"
        case bold = "bold"
        case heavy = "heavy"
        case black = "black"
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
        var auto_delete_messages_interval: Int
        var locked_account_color: String
        var locked_background: String
        var skip_vcard_nickname_onboarding_step: Bool
        var interface_type: String
        var symbol_weight: String
        var chat_avatar_size: Int
        var use_large_title: Bool
        var default_report_address: String
    }
    
    var interfaceType: InterfaceType {
        return InterfaceType(rawValue: CommonConfigManager.shared.config.interface_type) ?? .split
    }
    
    var symbolWeight: UIFont.Weight {
        switch SymbolWeight(rawValue: CommonConfigManager.shared.config.symbol_weight) ?? .regular {
            case .ultraLight: return .ultraLight
            case .thin: return .thin
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            case .black: return .black
        }
    }
    
    var config: CommonConfig
    var messageStyleConfig: MessageStyleConfig
    
    override init() {
        guard let path = Bundle.main.path(forResource: "common_config", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let config = try? PropertyListDecoder().decode(CommonConfig.self, from: xml) else {
              fatalError()
          }
        self.config = config
        let decoder = JSONDecoder()
        
//        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        guard let tpath = Bundle.main.path(forResource: "bubblecorners", ofType: "json") else { fatalError() }
        guard let tmessageConfigData = try? Data(contentsOf: URL(fileURLWithPath: tpath), options: .mappedIfSafe) else { fatalError() }
//        guard let tdecoded = try? decoder.decode(MessageStyleConfig.self, from: tmessageConfigData) else {  fatalError() }
        
        do {
            try decoder.decode(MessageStyleConfig.self, from: tmessageConfigData)
        } catch {
            print(error, error.localizedDescription)
            print(1)
        }
        
        guard let path = Bundle.main.path(forResource: "bubblecorners", ofType: "json"),
              let messageConfigData = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              let decoded = try? decoder.decode(MessageStyleConfig.self, from: messageConfigData) else {
            fatalError()
        }
        self.messageStyleConfig = decoded
        super.init()
    }
    
    func get() -> CommonConfig {
       return config
    }
    
    enum InterfaceType: String {
        case tabs = "tabs"
        case split = "split"
    }
}

struct MessageStyleConfig: Decodable {
    struct MessageRadius: Decodable {
        struct Radius {
            var items: [CGFloat]
            
            init(_ items: [Int]) {
                self.items = items.compactMap { CGFloat($0) }
            }
            
            var leftUpper: CGFloat {
                get {
                    return items[0]
                }
            }
            
            var rightUpper: CGFloat {
                get {
                    return items[1]
                }
            }
            
            var leftBottom: CGFloat {
                get {
                    return items[2]
                }
            }
            
            var rightBottom: CGFloat {
                get {
                    return items[3]
                }
            }
        }
        
        var r0 : [Int]
        var r1 : [Int]
        var r2 : [Int]
        var r3 : [Int]
        var r4 : [Int]
        var r5 : [Int]
        var r6 : [Int]
        var r7 : [Int]
        var r8 : [Int]
        var r9 : [Int]
        var r10: [Int]
        var r11: [Int]
        var r12: [Int]
        var r13: [Int]
        var r14: [Int]
        var r15: [Int]
        var r16: [Int]
        
        enum CodingKeys: String, CodingKey {
            case r0  = "0"
            case r1  = "1"
            case r2  = "2"
            case r3  = "3"
            case r4  = "4"
            case r5  = "5"
            case r6  = "6"
            case r7  = "7"
            case r8  = "8"
            case r9  = "9"
            case r10 = "10"
            case r11 = "11"
            case r12 = "12"
            case r13 = "13"
            case r14 = "14"
            case r15 = "15"
            case r16 = "16"
        }
        
//        static func radiusFor(index: String) -> Radius {
//            
//        }
        
        static func getRadiusList() -> [String] {
            return [
                "0",
                "1",
                "2",
                "3",
                "4",
                "5",
                "6",
                "7",
                "8",
                "9",
                "10",
                "11",
                "12",
                "13",
                "14",
                "15",
                "16"
            ]
        }
        
        func getRadiusFor(index: String) -> Radius {
            switch index {
                case "0" : return Radius(self.r0)
                case "1" : return Radius(self.r1)
                case "2" : return Radius(self.r2)
                case "3" : return Radius(self.r3)
                case "4" : return Radius(self.r4)
                case "5" : return Radius(self.r5)
                case "6" : return Radius(self.r6)
                case "7" : return Radius(self.r7)
                case "8" : return Radius(self.r8)
                case "9" : return Radius(self.r9)
                case "10": return Radius(self.r10)
                case "11": return Radius(self.r11)
                case "12": return Radius(self.r12)
                case "13": return Radius(self.r13)
                case "14": return Radius(self.r14)
                case "15": return Radius(self.r15)
                case "16": return Radius(self.r16)
                default: return   Radius(self.r0)
            }
        }
    }
    struct MessageBubble: Decodable {
        struct Image: Decodable {
            
            var bubble: MessageRadius
            var image: MessageRadius
            var timestamp: MessageRadius
            
            enum CodingKeys: String, CodingKey {
                case bubble = "bubble"
                case image = "image"
                case timestamp = "timestamp"
            }
        }
        
        struct Message: Decodable {
            
            var bubble: MessageRadius
            
            enum CodingKeys: String, CodingKey {
                case bubble = "bubble"
            }
        }
        
        var image: Image
        var message: Message
    }
    
    struct MessageBubbleContainer: Decodable {
        var noTail: MessageBubble
        var smooth: MessageBubble
        var bubble: MessageBubble
        var bubbles: MessageBubble
        var curvy: MessageBubble
        var stripes: MessageBubble
        var transparent: MessageBubble
        var wedge: MessageBubble
        
        enum CodingKeys: String, CodingKey {
            case noTail = "no_tail"
            case smooth = "smooth"
            case bubble = "bubble"
            case bubbles = "bubbles"
            case curvy = "curvy"
            case stripes = "stripes"
            case transparent = "transparent"
            case wedge = "wedge"
        }
        
        static func verboseNames() -> [String] {
            return [
                "No tail",
                "Smooth",
                "Bubble",
                "Bubbles",
                "Curvy",
                "Stripes",
                "Transparent",
                "Wedge"
            ]
        }
        
        static func nameFromVerbose(_ name: String) -> CodingKeys {
            switch name {
                case "No tail": return      .noTail
                case "Smooth": return       .smooth
                case "Bubble": return       .bubble
                case "Bubbles": return      .bubbles
                case "Curvy": return        .curvy
                case "Stripes": return      .stripes
                case "Transparent": return  .transparent
                case "Wedge": return        .wedge
                default: return             .noTail
            }
        }
    }
    struct Containers: Decodable {
        struct Container: Decodable {
            var border: MessageRadius
            var inner: MessageRadius
            
            enum CodingKeys: String, CodingKey {
                case border = "border"
                case inner = "inner"
            }
        }
        
        var level_1: Container
        var level_2: Container
        var level_3: Container
        
        enum CodingKeys: String, CodingKey {
            case level_1 = "container_l1"
            case level_2 = "container_l2"
            case level_3 = "container_l3"
        }
    }
    var messageBubbles: MessageBubbleContainer
    var containers: Containers
    
    enum CodingKeys: String, CodingKey {
        case messageBubbles = "message_bubbles"
        case containers = "containers"
    }
}
