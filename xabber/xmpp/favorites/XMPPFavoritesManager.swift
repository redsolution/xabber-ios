//
//  XMPPFavoritesManager.swift
//  xabber
//
//  Created by Admin on 14.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import RealmSwift
import CocoaLumberjack

class XMPPFavoritesManager: AbstractXMPPManager {
    enum ManagerErrorType: Error {
        case notAvailable
    }
    
    static let xmlns: String = "urn:xabber:favorites:0"
    
    open var node: String? = nil
    
    override func namespaces() -> [String] {
        return [
            XMPPFavoritesManager.xmlns
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return XMPPFavoritesManager.xmlns
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        loadLocal()
    }
    
    private func loadLocal() {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: XMPPFavoritesManagerStorageItem.self, forPrimaryKey: XMPPFavoritesManagerStorageItem.genPrimary(owner: self.owner)) {
                self.node = instance.node
            }
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func configure(for jid: String) {
        self.node = jid
        
        do {
            try createXMPPFavoritesManagerStorageItem()
            try createRosterStorageItem()
            try createLastChatsStorageItem()
            
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.favorites.update(stream)
        })
    }
    
    func createXMPPFavoritesManagerStorageItem() throws {
        guard let node = self.node else { throw ManagerErrorType.notAvailable }
        
        let realm = try WRealm.safe()
        
        let instance = XMPPFavoritesManagerStorageItem()
        instance.owner = self.owner
        instance.primary = XMPPFavoritesManagerStorageItem.genPrimary(owner: self.owner)
        instance.node = node
        
        try realm.write {
            realm.add(instance)
        }
    }
    
    func createRosterStorageItem() throws {
        guard let node = self.node else { throw ManagerErrorType.notAvailable }
        
        let realm = try WRealm.safe()
        
        let rosterItem = RosterStorageItem()
        rosterItem.owner = owner
        rosterItem.jid = node
        rosterItem.primary = RosterStorageItem.genPrimary(jid: node, owner: owner)
        rosterItem.username = "Saved messages"
        
        try realm.write {
            realm.add(rosterItem)
        }
    }
    
    func createLastChatsStorageItem(commitTransaction: Bool = true) throws {
        guard let node = self.node else { throw ManagerErrorType.notAvailable }
        
        let realm = try WRealm.safe()
        
        let instance = LastChatsStorageItem()
        instance.owner = self.owner
        instance.jid = node
        instance.isSynced = false
        instance.conversationType = .saved
        instance.primary = LastChatsStorageItem.genPrimary(jid: node, owner: self.owner, conversationType: .saved)
        
        let rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: node, owner: self.owner))
        
        instance.rosterItem = rosterItem
        
        if commitTransaction {
            try realm.write {
                realm.add(instance)
            }
        } else {
            realm.add(instance)
        }
    }
    
    public final func isAvailable() -> Bool {
        guard self.node != nil else {
            return false
        }
        
        return true
    }
    
    public func update(_ stream: XMPPStream) {
        guard isAvailable() else {
            return
        }
        
        updateArchive(stream)
    }
    
    func updateArchive(_ stream: XMPPStream) {
        guard let node = self.node else {
            return
        }
        
        var lastArchivedMessageDate: Date? = nil
        do {
            let realm = try WRealm.safe()
            lastArchivedMessageDate = realm
                .objects(MessageStorageItem.self)
                .filter("opponent == %@ AND owner == %@ AND conversationType_ == %@", node, self.owner, ClientSynchronizationManager.ConversationType.saved.rawValue)
                .sorted(byKeyPath: "date", ascending: false)
                .first?
                .date
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: self.owner)?.mam.requestArchive(stream, jid: node, isContinues: true, conversationType: .saved, start: lastArchivedMessageDate)
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(XMPPFavoritesManagerStorageItem.self).filter("owner == %@", owner)
            
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                }
            } else {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("XMPPFavoritesManager: \(#function). \(error.localizedDescription)")
        }
    }
}
