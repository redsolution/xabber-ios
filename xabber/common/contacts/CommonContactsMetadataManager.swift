//
//  CommonContactsMetadataManager.swift
//  xabber
//
//  Created by Игорь Болдин on 23.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import Contacts
import Intents

class CommonContactsMetadataManager: NSObject {
    open class var shared: CommonContactsMetadataManager {
        struct CommonContactsMetadataManagerSingleton {
            static let instance = CommonContactsMetadataManager()
        }
        return CommonContactsMetadataManagerSingleton.instance
    }
    
    struct Metadata {
        let jid: String
        let owner: String
        let username: String?
        let avatarUrl: String?
        let contactID: String?
    }
    
    let key: String = "contacts_metadata"
    
    public func clear(for owner: String) {
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            fatalError()
        }
        userDefaults.dictionaryRepresentation().keys.forEach {
            if $0.contains([key, owner].prp()) {
                userDefaults.removeObject(forKey: $0)
            }
        }
    }
    
    func saveFakeContact(jid: String, owner: String, name: String?, avatarUrl: String?) -> String? {
        let store = CNContactStore()
        
        let contact = CNMutableContact()
        contact.givenName = name ?? jid.components(separatedBy: "@").first ?? jid
        
        contact.note = "xabber:\(owner.lowercased()):\(jid.lowercased())"
        
        if let urlString = avatarUrl, let url = URL(string: urlString) {
            do {
                let data = try Data(contentsOf: url)
                contact.imageData = data
            } catch {
                print("Failed to load avatar", error)
            }
        }
        
        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)  // nil = default container
        
        do {
            try store.execute(saveRequest)
            
            let predicate = CNContact.predicateForContacts(matchingName: contact.givenName)
            let keys = [CNContactIdentifierKey, CNContactNoteKey] as [CNKeyDescriptor]
            
            if let found = try? store.unifiedContacts(matching: predicate, keysToFetch: keys),
               let matching = found.first(where: { $0.note == contact.note }) {
                let request = CNSaveRequest()
                return matching.identifier  // ← вот этот identifier отдаём в INPerson
            }
            return nil
        } catch {
            print("Cannot save contact", error)
            return nil
        }
    }
    
    public func update(owner: String, jid: String, username: String?, avatarUrl: String?) {
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            fatalError()
        }
        var metadata: [String: Any] = userDefaults.dictionary(forKey: [key, owner, jid].prp()) ?? ["username": username ?? "test", "avatarUrl": avatarUrl ?? ""]
        if let username = username {
            metadata["username"] = username
        }
        if let avatarUrl = avatarUrl {
            metadata["avatarUrl"] = avatarUrl
        }
//        if let contactId = saveFakeContact(jid: jid, owner: owner, name: username, avatarUrl: avatarUrl) {
//            metadata["contactId"] = contactId
//        }
        userDefaults.setValue(metadata, forKey: [key, owner, jid].prp())
    }
    
    public func getItem(owner: String, jid: String) -> Metadata {
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            fatalError()
        }
        if let metadata: [String: Any] = userDefaults.dictionary(forKey: ["contacts_metadata", owner, jid].prp()) {
            return Metadata(
                jid: jid,
                owner: owner,
                username: metadata["username"] as? String,
                avatarUrl: metadata["avatarUrl"] as? String,
                contactID: metadata["contactId"] as? String
            )
        }
        return Metadata(jid: jid, owner: owner, username: nil, avatarUrl: nil, contactID: nil)
    }
}
