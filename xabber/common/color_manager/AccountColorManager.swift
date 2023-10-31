//
//  AccountColorManager.swift
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
import RealmSwift
import RxRealm
import RxSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack

class AccountColorManager: NSObject {
    
    class ColorItem {
        var key: String
        var title: String
        
        var palette: MDCPalette
        
        var primary: UIColor {
            get {
                return palette.tint700
            }
        }
        
        init(_ key: String, title: String, color palette: MDCPalette) {
            self.key = key
            self.title = title
            self.palette = palette
        }
    }
    
    class ColorForJid: Hashable {
        static func == (lhs: AccountColorManager.ColorForJid, rhs: AccountColorManager.ColorForJid) -> Bool {
            return lhs.jid == rhs.jid
        }
        
        var jid: String
        var color: ColorItem
        
        init(jid: String, color: ColorItem) {
            self.jid = jid
            self.color = color
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
        }

    }
    
    public static let colors: [ColorItem] = [
        ColorItem("green", title: "Green".localizeString(id: "account_color_name_green", arguments: []),
                  color: MDCPalette.green),
        ColorItem("orange", title: "Orange".localizeString(id: "account_color_name_orange", arguments: []),
                  color: MDCPalette.orange),
        ColorItem("red", title: "Red".localizeString(id: "account_color_name_red", arguments: []),
                  color: MDCPalette.red),
        ColorItem("blue", title: "Blue".localizeString(id: "account_color_name_blue", arguments: []),
                  color: MDCPalette.blue),
        ColorItem("indigo", title: "Indigo".localizeString(id: "account_color_name_indigo", arguments: []),
                  color: MDCPalette.indigo),
        ColorItem("greyblue", title: "Greyblue".localizeString(id: "account_color_name_blue_grey", arguments: []),
                  color: MDCPalette.blueGrey),
        ColorItem("cyan", title: "Cyan".localizeString(id: "account_color_name_cyan", arguments: []),
                  color: MDCPalette.cyan),
        ColorItem("emerald", title: "Emerald".localizeString(id: "account_color_name_emerald", arguments: []),
                  color: MDCPalette.green),
        ColorItem("purple", title: "Purple".localizeString(id: "account_color_name_purple", arguments: []),
                  color: MDCPalette.purple),
        ColorItem("lime", title: "Lime".localizeString(id: "account_color_name_lime", arguments: []),
                  color: MDCPalette.lime),
        ColorItem("pink", title: "Pink".localizeString(id: "account_color_name_pink", arguments: []),
                  color: MDCPalette.pink),
        ColorItem("lightblue", title: "Light blue".localizeString(id: "account_color_name_light_blue", arguments: []),
                  color: MDCPalette.lightBlue),
        ColorItem("lightgreen", title: "Light green".localizeString(id: "account_color_name_light_green", arguments: []),
                  color: MDCPalette.lightGreen),
        ColorItem("darkorange", title: "Dark orange".localizeString(id: "account_color_name_dark_orange", arguments: []),
                  color: MDCPalette.deepOrange),
        ColorItem("brown", title: "Brown".localizeString(id: "account_color_name_brown", arguments: []),
                  color: MDCPalette.brown),
        ColorItem("amber", title: "Amber".localizeString(id: "account_color_name_amber", arguments: []),
                  color: MDCPalette.amber)
    ]
    
    open class var shared: AccountColorManager {
        struct AccountColorManagerSingleton {
            static let instance = AccountColorManager()
        }
        return AccountColorManagerSingleton.instance
    }
    
    internal var accounts: Set<ColorForJid> = Set<ColorForJid>()
    internal var bag: DisposeBag = DisposeBag()
    internal var primaryPalette: MDCPalette? = nil
    
    override init() {
        super.init()
//        load()
    }
    
    open func load() {
        do {
            bag = DisposeBag()
            let realm = try WRealm.safe()
            let collection = realm.objects(AccountStorageItem.self).sorted(byKeyPath: "order", ascending: true)
            collection.forEach {
                self.accounts.insert(ColorForJid(jid: $0.jid, color: colorForKey($0.colorKey)))
            }
            if let primaryAccount = collection.first {
                primaryPalette = palette(for: primaryAccount.jid)
            }
            Observable
                .changeset(from: collection)
                .share()
//                .debug()
                .subscribe(onNext: { (result) in
                    guard let changeset = result.1 else { return }
                    if let primaryAccount = result.0.first {
                        self.primaryPalette = self.palette(for: primaryAccount.jid)
                    }
                    changeset.inserted.forEach {
                        let item = result.0[$0]
                        self.accounts.insert(ColorForJid(jid: item.jid, color: self.colorForKey(item.colorKey)))
                    }
                    changeset.updated.forEach {
                        let item = result.0[$0]
                        self.accounts.first(where: { $0.jid == item.jid })?.color = self.colorForKey(item.colorKey)
                    }
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("cant load colors for accounts")
        }
    }
    
    func colorForKey(_ key: String) -> ColorItem {
        return AccountColorManager.colors.first(where: { $0.key == key }) ?? AccountColorManager.colors.first!
    }
    
    func colorItem(for jid: String) -> ColorItem {
        return accounts.first(where: { $0.jid == jid })?.color ??  AccountColorManager.colors.randomElement()!
    }
    
    func palette(for jid: String) -> MDCPalette {
        return colorItem(for: jid).palette
    }
    
    func primaryColor(for jid: String) -> UIColor {
        return colorItem(for: jid).palette.tint700
    }
    
    func cgColor(for jid: String) -> CGColor {
        return primaryColor(for: jid).cgColor
    }
    
    func topPalette() -> MDCPalette {
        return primaryPalette ?? MDCPalette.blue
    }
    
    func topColor() -> UIColor {
        return (primaryPalette ?? MDCPalette.blue).tint700
    }
    
    func updateColor(_ key: String, for jid: String) {
        self.accounts.first(where: { $0.jid == jid })?.color = self.colorForKey(key)
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        instance.colorKey = key
                    }
                }
            }
            let collection = realm.objects(AccountStorageItem.self).sorted(byKeyPath: "order", ascending: true)
            if let primaryAccount = collection.first {
                primaryPalette = palette(for: primaryAccount.jid)
            }
        } catch {
            DDLogDebug("cant update color for \(jid). \(#function)")
        }
        DispatchQueue.main.async {
            getAppTabBar()?.tabBar.tintColor = self.topColor()
        }
    }
    
    public func randomPalette() -> MDCPalette {
        let index = Int.random(in: 0..<AccountColorManager.colors.count)
        return AccountColorManager.colors[index].palette
    }
    
    public func pairedPalette(jid: String) -> MDCPalette {
        guard let key = accounts.first(where: { $0.jid == jid })?.color.key,
            let index = AccountColorManager.colors.firstIndex(where: { $0.key == key }) else {
                return palette(for: jid)
        }
        let newIndex = index + 3
        let count =  AccountColorManager.colors.count
        return AccountColorManager.colors[newIndex >= count ? newIndex - count : newIndex ].palette
    }
}
