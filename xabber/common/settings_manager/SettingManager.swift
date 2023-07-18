//
//  SettingManagerTest.swift
//  xabber_test_xmpp
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
//import Coco

open class SettingManager: NSObject {
    
    open class var shared: SettingManager {
        struct SettingsManagerSingleton {
            static let instance = SettingManager()
        }
        return SettingsManagerSingleton.instance
    }

    public enum KeyScope: String {
        case globalIndex = "gc"
        case httpUploader = "http_upl"
        case reliableMessageDelivery = "rel_msg_del"
        case messageDeleteRewrite = "trust_cert_policy"
        case trustCertificatePolicy = "msg_del_rewr"
        case clientSynchronization = "client_sync"
        case roster = "roster"
        case messageArchive = "mam"
        case xabberUploadManager = "xabber_uploader"
        case avatarUploadManager = "avatar_uploader"
        case avatarMasks = "avatar_masks"
        case languages = "languages"
        case security = "security"
        case products = "products"
    }
    
    enum DatasourceKind {
        case title
        case group
        case bool
        case selector
        
    }
    
    open class Datasource: NSCopying {
        var key: String = ""
        var label: String = ""
        var kind: DatasourceKind = .title
        var childs: [Datasource] = []
        var values: [String] = []
        var value: Any = ""
        
        init() {
            
        }
        
        init(key: String, label: String, kind: DatasourceKind, childs: [Datasource], values: [String], value: Any) {
            self.key = key
            self.label = label
            self.kind = kind
            self.childs.reserveCapacity(childs.count)
            self.childs = childs
            self.values = values
            self.value = value
        }
        
        public func copy(with zone: NSZone? = nil) -> Any {
            let copy = Datasource(key: self.key,
                                  label: self.label,
                                  kind: self.kind,
                                  childs: self.childs,
                                  values: self.values,
                                  value: self.value)
            return copy
        }
    }
    
    private var isLogEnabled: Bool? = nil
    
    static var logEnabled: Bool {
        get {
            guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
                return false
            }
            return userDefaults.bool(forKey: "developer_logEnabled")
        }
    }
//    open var logEnabled: Bool {
//        get {
//            if let value = isLogEnabled {
//                return value
//            } else {
//                isLogEnabled = SettingManager.shared.get(bool: "developer_logEnabled")
//                return isLogEnabled ?? false
//            }
//        }
//    }
    
    open var chatSettings: Datasource = Datasource()
    open var rosterSettings: Datasource = Datasource()
    open var languageSettings: Datasource = Datasource()
    open var notificationSettings: Datasource = Datasource()
    open var privacySettings: Datasource = Datasource()
    open var developerSettings: Datasource = Datasource()
    
    override init() {
        super.init()
        loadSettings()
    }
    
    public final func loadSettings() {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            fatalError()
        }
        writeDefault()
        let dict = userDefaults.dictionaryRepresentation()
        self.chatSettings = Datasource(key: "chat", //EXC BAD ACCESS FAIL!!!!
                                       label: "Chat".localizeString(id: "account_settings_chat", arguments: []),
                                       kind: .title,
                                       childs: [Datasource(key: "chat_background",
                                                           label: "Background".localizeString(id: "account_settings_background", arguments: []),
                                                           kind: .group,
                                                           childs: [Datasource(key: "chat_chooseBackground",
                                                                               label: "Choose background".localizeString(id: "account_settings_choose_background", arguments: []),
                                                                               kind: .selector,
                                                                               childs: [],
                                                                               values: ["Aliens",
                                                                                        "Summer",
                                                                                        "Cats",
                                                                                        "Flowers",
                                                                                        "Flowers-daisy",
                                                                                        "Hearts"],
                                                                               value: dict["chat_chooseBackground"] ?? "Aliens")
                                                                   ],
                                                           values: [],
                                                           value: ""),
                                                Datasource(key: "chat_design",
                                                           label: "Display".localizeString(id: "account_settings_display", arguments: []),
                                                           kind: .group,
                                                           childs: [Datasource(key: "chat_showBackground",
                                                                               label: "Show background".localizeString(id: "account_settings_show_background", arguments: []),
                                                                               kind: .bool,
                                                                               childs: [],
                                                                               values: [],
                                                                               value: dict["chat_showBackground"] ?? true)],
                                                           values: [],
                                                           value: "Chat items display settings".localizeString(id: "account_settings_chat_display_settings", arguments: [])),
                                                Datasource(key: "chat_behaviour",
                                                           label: "Messaging".localizeString(id: "account_settings_messaging", arguments: []),
                                                           kind: .group,
                                                           childs: [Datasource(key: "chat_sendByEnter",
                                                                               label: "Send by enter".localizeString(id: "account_settings_send_by_enter", arguments: []),
                                                                               kind: .bool,
                                                                               childs: [],
                                                                               values: [],
                                                                               value: dict["chat_sendByEnter"] ?? false)],
                                                           values: [],
                                                           value: "Choose type of message sending options".localizeString(id: "account_settings_message_sending_options", arguments: []))
                                                ],
                                       values: [],
                                       value: false)
        self.rosterSettings = Datasource(key: "roster",
                                         label: "Contact list".localizeString(id: "account_settings_contact_list", arguments: []),
                                         kind: .title,
                                         childs: [Datasource(key: "roster_display",
                                                             label: "Display options".localizeString(id: "account_settings_display_options", arguments: []),
                                                             kind: .group,
                                                             childs: [
                                                                      Datasource(key: "roster_showOfflineContacts",
                                                                                 label: "Show offline contacts".localizeString(id: "account_settings_offline_contacts", arguments: []),
                                                                                 kind: .bool,
                                                                                 childs: [],
                                                                                 values: [],
                                                                                 value: dict["roster_showOfflineContacts"] ?? true),
                                                                      Datasource(key: "roster_showAvatars",
                                                                                 label: "Show avatars".localizeString(id: "account_settings_show_avatars", arguments: []),
                                                                                 kind: .bool,
                                                                                 childs: [],
                                                                                 values: [],
                                                                                 value: dict["roster_showAvatars"] ?? true),
                                                                      Datasource(key: "roster_showGroups",
                                                                                 label: "Show circles".localizeString(id: "account_settings_show_circles", arguments: []),
                                                                                 kind: .bool,
                                                                                 childs: [],
                                                                                 values: [],
                                                                                 value: dict["roster_showGroups"] ?? true),
                                                    ],
                                                             values: [],
                                                             value: "")
                                                  ],
                                         values: [],
                                         value: false)
        
        self.notificationSettings = Datasource(key: "notification",
                                               label: "Notifications".localizeString(id: "account_settings_notificaions", arguments: []),
                                               kind: .title,
                                               childs: [Datasource(key: "notification_in_app",
                                                                   label: "In-App notifications".localizeString(id: "account_settings_in_app_notifications", arguments: []),
                                                                   kind: .group,
                                                                   childs: [Datasource(key: "notification_in_app_alert_last_chats",
                                                                                       label: "On chats screen message preview".localizeString(id: "account_settings_chat_message_preview", arguments: []),
                                                                                       kind: .bool,
                                                                                       childs: [],
                                                                                       values: [],
                                                                                       value: dict["notification_in_app_alert_last_chats"] ?? false),
                                                                           Datasource(key: "notification_in_app_sound",
                                                                                      label: "In-App sounds".localizeString(id: "account_settings_in_app_sounds", arguments: []),
                                                                                       kind: .bool,
                                                                                       childs: [],
                                                                                       values: [],
                                                                                       value: dict["notification_in_app_sound"] ?? true)],
                                                                   values: [],
                                                                   value: "Notification settings for application".localizeString(id: "account_settings_notification_application_settings", arguments: [])),
//                                                        Datasource(key: "notification_chat",
//                                                                   label: "Chat notifications",
//                                                                   kind: .group,
//                                                                   childs: [Datasource(key: "notification_chat_sound",
//                                                                                       label: "Sound",
//                                                                                       kind: .bool,
//                                                                                       childs: [],
//                                                                                       values: [],
//                                                                                       value: dict["notification_chat_sound"] ?? true),
//                                                                            Datasource(key: "notification_chat_vibration",
//                                                                                       label: "Vibration",
//                                                                                       kind: .bool,
//                                                                                       childs: [],
//                                                                                       values: [],
//                                                                                       value: dict["notification_chat_vibration"] ?? true),
//                                                                            Datasource(key: "notification_chat_showPreviews",
//                                                                                       label: "Show previews",
//                                                                                       kind: .bool,
//                                                                                       childs: [],
//                                                                                       values: [],
//                                                                                       value: dict["notification_chat_showPreviews"] ?? true)
//                                                                            ],
//                                                                   values: [],
//                                                                   value: "Manage settings for notifications in private chat"),
//                                                        Datasource(key: "notification_groupchat",
//                                                                   label: "Groupchat notifications",
//                                                                   kind: .group,
//                                                                   childs: [Datasource(key: "notification_groupchat_sound",
//                                                                                       label: "Sound",
//                                                                                       kind: .bool,
//                                                                                       childs: [],
//                                                                                       values: [],
//                                                                                       value: dict["notification_groupchat_sound"] ?? true),
//                                                                            Datasource(key: "notification_groupchat_vibration",
//                                                                                       label: "Vibration",
//                                                                                       kind: .bool,
//                                                                                       childs: [],
//                                                                                       values: [],
//                                                                                       value: dict["notification_groupchat_vibration"] ?? true),
//                                                                            Datasource(key: "notification_groupchat_showPreviews",
//                                                                                       label: "Show previews",
//                                                                                       kind: .bool,
//                                                                                       childs: [],
//                                                                                       values: [],
//                                                                                       value: dict["notification_groupchat_showPreviews"] ?? true)],
//                                                                   values: [],
//                                                                   value: "Manage settings for notifications in groupchats"),
                                                        ],
                                               values: [],
                                               value: false)
        self.privacySettings = Datasource(key: "privacy",
                                          label: "Privacy".localizeString(id: "account_settings_privacy", arguments: []),
                                          kind: .title,
                                          childs: [Datasource(key: "privacy",
                                                              label: "Privacy settings".localizeString(id: "account_settings_privacy_settings", arguments: []),
                                                              kind: .group,
                                                              childs: [Datasource(key: "privacy_textInputNotify",
                                                                                  label: "Send typing notification"
                                                        .localizeString(id: "account_settings_typing_notification", arguments: []),
                                                                                  kind: .bool,
                                                                                  childs: [],
                                                                                  values: [],
                                                                                  value: dict["privacy_textInputNotify"] ?? true),
                                            ],
                                                              values: [],
                                                              value: "")],
                                          values: [],
                                          value: false)
        
        self.languageSettings = Datasource(key: "languages",
                                           label: "Choose language".localizeString(id: "settings_choose_language", arguments: []),
                                           kind: .group,
                                           childs: [Datasource(key: "system_language",
                                                               label: "Default",
                                                               kind: .selector,
                                                               childs: [],
                                                               values: ["Default"],
                                                               value: TranslationsManager.shared.currentLang ?? "Default")],
                                           values: [],
                                           value: "")
        
        TranslationsManager.Languages.allCases.forEach({
            self.languageSettings.childs.first?.values.append($0.rawValue)
        })
        
        self.developerSettings = Datasource(key: "developer",
                                            label: "Developer".localizeString(id: "account_settings_developer", arguments: []),
                                            kind: .title,
                                            childs: [Datasource(key: "developer",
                                                                label: "Developer mode".localizeString(id: "account_settings_developer_mode", arguments: []),
                                                                kind: .group,
                                                                childs: [Datasource(key: "developer_logEnabled",
                                                                                    label: "Write log"
                                                        .localizeString(id: "account_settings_write_log", arguments: []),
                                                                                    kind: .bool,
                                                                                    childs: [],
                                                                                    values: [],
                                                                                    value: dict["developer_logEnabled"] ?? true)],
                                                                values: [],
                                                                value: "")],
                                            values: [],
                                            value: false)
    }
    
    public final func updateValue(key: String, value: Any) {
        
        func updateItem(in settings: Datasource) -> Bool {
            for item in settings.childs.enumerated() {
                if item.element.key == key {
                    settings.childs[item.offset].value = value
                    return true
                }
                for childItem in item.element.childs.enumerated() {
                    if childItem.element.key == key {
                        settings.childs[item.offset].childs[childItem.offset].value = value
                        return true
                    }
                }
            }
            return false
        }
        switch true {
        case updateItem(in: chatSettings): return
        case updateItem(in: rosterSettings): return
        case updateItem(in: notificationSettings): return
        case updateItem(in: languageSettings): return
        case updateItem(in: privacySettings): return
        case updateItem(in: developerSettings): return
        default: break
        }
    }
    
    public final func writeDefault() {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            fatalError()
        }
        if userDefaults.value(forKey: "default_settingsCached") != nil {
            return
        }
        let defaults: NSDictionary = [
            "default_settingsCached": true,
            "chat_fontSize":"regular",
            "chat_showStatus": true,
            "chat_showBackground": true,
            "chat_sendByEnter": false,
            "chat_chooseBackground": "Flowers",
            "roster_sorting": "by_status",
            "roster_showAvatars": true,
            "roster_showOfflineContacts": true,
            "roster_showGroups": true,
            "roster_divideByAccounts": true,
            "roster_showOfflineContacts": true,
            "roster_showEmptyGroups": true,
            "notification_in_app_alert_last_chats": false,
            "notification_in_app_sound": true,
            "notification_chat_sound": true,
            "notification_chat_vibration": true,
            "notification_chat_badge": "full",
            "notification_groupchat_sound": true,
            "notification_groupchat_vibration": true,
            "notification_groupchat_badge": "full",
            "privacy_textInputNotify": true,
            "privacy_checkServerCertificate": true,
            "developer_logEnabled": false,
            "avatar_masks_current_avatar_mask_": "rounded",
        ]
        defaults.forEach { (item) in
            userDefaults.set(item.value, forKey: item.key as! String)
        }
    }
    
    public final func getDatasource(by key: String) -> Datasource? {
        switch key {
        case "chat": return chatSettings
        case "roster": return rosterSettings
        case "languages": return languageSettings
        case "notification": return notificationSettings
        case "privacy": return privacySettings
        case "developer": return developerSettings
        default: return nil
        }
    }
    
    public final func saveItem(key: String, value: Int) {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            fatalError()
        }
        userDefaults.set(value, forKey: key)
    }
    
    public final func saveItem(key: String, bool: Bool) {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            fatalError()
        }
        userDefaults.set(bool, forKey: key)
        if chatSettings.childs.isEmpty {
            loadSettings()
        } else {
            updateValue(key: key, value: bool)
        }
    }
    
    public final func saveItem(key: String, string: String) {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            fatalError()
        }
        userDefaults.set(string, forKey: key)
        if chatSettings.childs.isEmpty {
            loadSettings()
        } else {
            updateValue(key: key, value: string)
        }
    }
    
    public final func removeItem(for jid: String, scope: KeyScope, key: String) {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            fatalError()
        }
        let computedKey: String = [scope.rawValue, key, jid].prp()
        userDefaults.removeObject(forKey: computedKey)
    }
    
    public final func saveItem(for jid: String, scope: KeyScope, key: String, value: Int) {
        let computedKey: String = [scope.rawValue, key, jid].prp()
        saveItem(key: computedKey, value: value)
    }
    
    public final func saveItem(for jid: String, scope: KeyScope, key: String, value: String) {
        let computedKey: String = [scope.rawValue, key, jid].prp()
        saveItem(key: computedKey, string: value)
    }
    
    public final func saveItem(for jid: String, scope: KeyScope, key: String, value: Bool) {
        let computedKey: String = [scope.rawValue, key, jid].prp()
        saveItem(key: computedKey, bool: value)
    }
    
    public final func getKey(for jid: String, scope: KeyScope, key: String) -> String? {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            print("SettingsManager: \(#function). Can`t load UserDefaults")
            return nil
        }
        let computedKey: String = [scope.rawValue, key, jid].prp()
        return userDefaults.string(forKey: computedKey)
    }
    
    public final func getInt(for jid: String, scope: KeyScope, key: String) -> Int {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            print("SettingsManager: \(#function). Can`t load UserDefaults")
            return 0
        }
        let computedKey: String = [scope.rawValue, key, jid].prp()
        return userDefaults.integer(forKey: computedKey)
    }
    
    public final func getKeyBool(for jid: String, scope: KeyScope, key: String) -> Bool? {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            print("SettingsManager: \(#function). Can`t load UserDefaults")
            return nil
        }
        let computedKey: String = [scope.rawValue, key, jid].prp()
        return userDefaults.bool(forKey: computedKey)
    }
    
    public final func get(bool key: String) -> Bool {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            fatalError()
        }
        return userDefaults.bool(forKey: key)
    }
    
    public final func getString(for key: String) -> String? {
        guard let userDefaults = UserDefaults.init(suiteName: "com.xabber.ios.settings.common") else {
            fatalError()
        }
        return userDefaults.string(forKey: key)
    }
    
    public final func clear(for jid: String) {
        removeItem(for: jid, scope: .clientSynchronization, key: "version")
        removeItem(for: jid, scope: .trustCertificatePolicy, key: "allowed")
        removeItem(for: jid, scope: .roster, key: "version")
        removeItem(for: jid, scope: .messageArchive, key: "version")
        removeItem(for: jid, scope: .messageArchive, key: "initial")
        removeItem(for: jid, scope: .xabberUploadManager, key: "node")
        removeItem(for: jid, scope: .avatarUploadManager, key: "node")
        removeItem(for: jid, scope: .httpUploader, key: "node")
    }
    
}
