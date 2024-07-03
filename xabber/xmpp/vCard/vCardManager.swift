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
import XMPPFramework
import RealmSwift
//import Haneke


class VCardManager: AbstractXMPPManager {
    
    class VCardMetaItem {
        var title: String
        var value: String
        var key: String
        var childs: [VCardMetaItem]
        
        init(title: String, value: String, key: String, childs: [VCardMetaItem] = []) {
            self.title = title
            self.value = value
            self.key = key
            self.childs = childs
        }
    }
    
    internal var queue: SynchronizedArray<String> = SynchronizedArray<String>()
    
    override func namespaces() -> [String] {
        return [
            "vcard-temp"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    static public func getVcardStructure(_ vcard: vCardStorageItem, jid: String) -> [VCardMetaItem] {
        var out: [VCardMetaItem] = []
        
        func addSection(_ title: String, items: [VCardMetaItem]) {
            let item = VCardMetaItem(title: title, value: "", key: "", childs: items)
            if out.isEmpty {
                out = [item]
            } else {
                out.append(item)
            }
        }
        
        addSection("Nickname".localizeString(id: "vcard_nick_name", arguments: []), items: [
            VCardMetaItem(title: "\(jid.split(separator: "@").first!)", value: vcard.nickname, key: "ci_nickname"),
            VCardMetaItem(title: "Full name".localizeString(id: "vcard_full_name", arguments: []),
                          value: vcard.fn, key: "ci_full_name"),
            VCardMetaItem(title: "Given name".localizeString(id: "vcard_given_name", arguments: []),
                          value: vcard.given, key: "ci_given_name"),
            VCardMetaItem(title: "Middle name".localizeString(id: "vcard_middle_name", arguments: []),
                          value: vcard.middle, key: "ci_middle_name"),
            VCardMetaItem(title: "Family name".localizeString(id: "vcard_family_name", arguments: []),
                          value: vcard.family, key: "ci_family_name"),
            ])
        
        addSection("Birthday".localizeString(id: "vcard_birth_date", arguments: []), items: [
            VCardMetaItem(title: "YYYY-MM-DD".localizeString(id: "vcard_birth_date_placeholder", arguments: []),
                          value: vcard.birthdayString, key: "ci_birthday")])
        
        addSection("Job".localizeString(id: "vcard_job", arguments: []), items: [
            VCardMetaItem(title: "Company".localizeString(id: "vcard_company", arguments: []),
                          value: vcard.orgname, key: "wp_orgname"),
            VCardMetaItem(title: "Job title".localizeString(id: "vcard_title", arguments: []),
                          value: vcard.title, key: "wp_title"),
            VCardMetaItem(title: "Role".localizeString(id: "vcard_role", arguments: []),
                          value: vcard.role, key: "wp_role"),
            VCardMetaItem(title: "Unit".localizeString(id: "vcard_organization_unit", arguments: []),
                          value: vcard.orgunit, key: "wp_orgunit")
            ])
        
        addSection("Website".localizeString(id: "vcard_website", arguments: []), items: [
            VCardMetaItem(title: "URL".localizeString(id: "vcard_url", arguments: []),
                          value: vcard.url, key: "desc_url")])
        
        addSection("Description".localizeString(id: "vcard_decsription", arguments: []), items: [
            VCardMetaItem(title: "Bio".localizeString(id: "vcard_bio", arguments: []),
                          value: vcard.descr, key: "desc_descr")])
        
        addSection("Phone".localizeString(id: "vcard_telephone", arguments: []), items: [
            VCardMetaItem(title: "Work".localizeString(id: "vcard_type_work", arguments: []),
                          value: vcard.telWorkVoice, key: "ph_workPhone"),
            VCardMetaItem(title: "Home".localizeString(id: "vcard_type_home", arguments: []),
                          value: vcard.telHomeVoice, key: "ph_homePhone"),
            VCardMetaItem(title: "Mobile".localizeString(id: "vcard_type_mobile", arguments: []),
                          value: vcard.telHomeMsg, key: "ph_homeMsg")
            ])
        
        addSection("Email".localizeString(id: "vcard_email", arguments: []), items: [
            VCardMetaItem(title: "Work".localizeString(id: "vcard_type_work", arguments: []),
                          value: vcard.emailWork, key: "desc_email_work"),
            VCardMetaItem(title: "Personal".localizeString(id: "vcard_type_personal", arguments: []),
                          value: vcard.emailHome, key: "desc_email_home"),
            ])
        
        addSection("Home address".localizeString(id: "vcard_home_address", arguments: []), items: [
            VCardMetaItem(title: "PO box".localizeString(id: "vcard_address_pobox", arguments: []),
                          value: vcard.adrHomePoBox, key: "ha_pobox"),
            VCardMetaItem(title: "Extended address".localizeString(id: "vcard_address_extadr", arguments: []),
                          value: vcard.adrHomeExtadd, key: "ha_address"),
            VCardMetaItem(title: "Street".localizeString(id: "vcard_address_street", arguments: []),
                          value: vcard.adrHomeStreet, key: "ha_street"),
            VCardMetaItem(title: "Locality".localizeString(id: "vcard_address_locality", arguments: []),
                          value: vcard.adrHomeLocality, key: "ha_locality"),
            VCardMetaItem(title: "Region".localizeString(id: "vcard_address_region", arguments: []),
                          value: vcard.adrHomeRegion, key: "ha_region"),
            VCardMetaItem(title: "Postal code".localizeString(id: "vcard_address_pcode", arguments: []),
                          value: vcard.adrHomePCode, key: "ha_pcode"),
            VCardMetaItem(title: "Country name".localizeString(id: "vcard_address_ctry", arguments: []),
                          value: vcard.adrHomeCountry, key: "ha_country")
            ])
        
        addSection("Work address".localizeString(id: "vcard_work_address", arguments: []), items: [
            VCardMetaItem(title: "PO box".localizeString(id: "vcard_address_pobox", arguments: []),
                          value: vcard.adrWorkPoBox, key: "wa_pobox"),
            VCardMetaItem(title: "Extended address".localizeString(id: "vcard_address_extadr", arguments: []),
                          value: vcard.adrWorkExtadd, key: "wa_address"),
            VCardMetaItem(title: "Street".localizeString(id: "vcard_address_street", arguments: []),
                          value: vcard.adrWorkStreet, key: "wa_street"),
            VCardMetaItem(title: "Locality".localizeString(id: "vcard_address_locality", arguments: []),
                          value: vcard.adrWorkLocality, key: "wa_locality"),
            VCardMetaItem(title: "Region".localizeString(id: "vcard_address_region", arguments: []),
                          value: vcard.adrWorkRegion, key: "wa_region"),
            VCardMetaItem(title: "Postal code".localizeString(id: "vcard_address_pcode", arguments: []),
                          value: vcard.adrWorkPCode, key: "wa_pcode"),
            VCardMetaItem(title: "Country name".localizeString(id: "vcard_address_ctry", arguments: []),
                          value: vcard.adrWorkCountry, key: "wa_country")
            ])
        return out
    }
        
    internal func actualizeAccountUsername() {
        do {
            var result: String = "\(owner.split(separator: "@").first ?? "")"
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: vCardStorageItem.self,
                                           forPrimaryKey: owner) {
                result = instance.generatedNickname
            }
            AccountManager.shared.find(for: owner)?.username = result
            if !realm.isInWriteTransaction {
                try realm.write {
                    realm
                        .object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?
                        .username = result
                }
            }
        } catch {
            DDLogDebug("cant actualize username for account \(owner)")
        }
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let elementID = iq.elementID,
            let from = iq.from?.bare,
            let query = iq.element(forName: "vCard", xmlns: getPrimaryNamespace()) else {
                return false
        }
        if elementID == self.addContactVcardCheckId {
            self.addContactVcardCheckCallback?(from, iq.iqType != .error)
        }
        if iq.element(forName: "error") != nil || iq.iqType == .error {
            do {
                let realm = try  WRealm.safe()
                if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: from) {
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.lastUpdateDate = Date()
                        instance.isLastUpdateErrorOccured = true
                    }
                } else {
                    let instance = vCardStorageItem()
                    instance.jid = from
                    instance.lastUpdateDate = Date()
                    instance.isLastUpdateErrorOccured = true
                    try realm.write {
                        realm.add(instance, update: .modified)
                    }
                }
            } catch {
                DDLogDebug("VCardManager: \(#function). \(error.localizedDescription)")
            }
            return true
        }
        
        self.getOrCreate(for: from) { instance in
            instance.lastUpdateDate = Date()
            instance.isLastUpdateErrorOccured = false
            instance.fn = self.getEscapingElementValue(element: query.element(forName: "FN"))
            instance.family = self.getEscapingElementValue(element: query.element(forName: "N")?.element(forName: "FAMILY"))
            instance.given = self.getEscapingElementValue(element: query.element(forName: "N")?.element(forName: "GIVEN"))
            instance.middle = self.getEscapingElementValue(element: query.element(forName: "N")?.element(forName: "MIDDLE"))
            instance.nickname = self.getEscapingElementValue(element: query.element(forName: "NICKNAME"))
            instance.url = self.getEscapingElementValue(element: query.element(forName: "URL"))
            instance.birthday = Date()
            instance.birthdayString = self.getEscapingElementValue(element: query.element(forName: "BDAY"))
            instance.orgname = self.getEscapingElementValue(element: query.element(forName: "ORG")?.element(forName: "ORGNAME"))
            instance.orgunit = self.getEscapingElementValue(element: query.element(forName: "ORG")?.element(forName: "ORGUNIT"))
            instance.title = self.getEscapingElementValue(element: query.element(forName: "TITLE"))
            instance.role = self.getEscapingElementValue(element: query.element(forName: "ROLE"))
            let tels = query.elements(forName: "TEL")
            for tel in tels {
                if tel.element(forName: "WORK") != nil {
                    instance.telWorkVoice = self.getEscapingElementValue(element: tel.element(forName: "NUMBER"))
                } else if tel.element(forName: "HOME") != nil {
                    instance.telHomeVoice = self.getEscapingElementValue(element: tel.element(forName: "NUMBER"))
                } else if tel.element(forName: "MOBILE") != nil {
                    instance.telHomeMsg = self.getEscapingElementValue(element: tel.element(forName: "NUMBER"))
                }
            }
            let adrs = query.elements(forName: "ADR")
            for adr in adrs {
                if adr.element(forName: "WORK") != nil {
                    instance.adrWorkPoBox = self.getEscapingElementValue(element: adr.element(forName: "POBOX"))
                    instance.adrWorkExtadd = self.getEscapingElementValue(element: adr.element(forName: "EXTADD"))
                    instance.adrWorkStreet = self.getEscapingElementValue(element: adr.element(forName: "STREET"))
                    instance.adrWorkLocality = self.getEscapingElementValue(element: adr.element(forName: "LOCALITY"))
                    instance.adrWorkRegion = self.getEscapingElementValue(element: adr.element(forName: "REGION"))
                    instance.adrWorkPCode = self.getEscapingElementValue(element: adr.element(forName: "PCODE"))
                    instance.adrWorkCountry = self.getEscapingElementValue(element: adr.element(forName: "CTRY"))
                } else if adr.element(forName: "HOME") != nil {
                    instance.adrHomePoBox = self.getEscapingElementValue(element: adr.element(forName: "POBOX"))
                    instance.adrHomeExtadd = self.getEscapingElementValue(element: adr.element(forName: "EXTADD"))
                    instance.adrHomeStreet = self.getEscapingElementValue(element: adr.element(forName: "STREET"))
                    instance.adrHomeLocality = self.getEscapingElementValue(element: adr.element(forName: "LOCALITY"))
                    instance.adrHomeRegion = self.getEscapingElementValue(element: adr.element(forName: "REGION"))
                    instance.adrHomePCode = self.getEscapingElementValue(element: adr.element(forName: "PCODE"))
                    instance.adrHomeCountry = self.getEscapingElementValue(element: adr.element(forName: "CTRY"))
                }
            }
            for emailElement in query.elements(forName: "EMAIL") {
                if emailElement.element(forName: "WORK") != nil {
                    instance.emailWork = self.getEscapingElementValue(element: emailElement.element(forName: "USERID"))
                }
                if emailElement.element(forName: "HOME") != nil {
                    instance.emailHome = self.getEscapingElementValue(element: emailElement.element(forName: "USERID"))
                }
            }
            
            
            
            instance.jabberId = self.getEscapingElementValue(element: query.element(forName: "JABBERID"))
            instance.descr = self.getEscapingElementValue(element: query.element(forName: "DESC"))
            
        }
        
        if let privacy = query.element(forName: "X-PRIVACY")?.stringValue,
            let index = query.element(forName: "X-INDEX")?.stringValue,
            let desc = query.element(forName: "DESC")?.stringValue,
            let status = query.element(forName: "X-STATUS")?.stringValue,
            let membership = query.element(forName: "X-MEMBERSHIP")?.stringValue {
            do {
                let realm = try  WRealm.safe()
                try realm.write {
                    if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [from, owner].prp()) {
                        instance.membership_ = membership
                        instance.descr = desc
                        instance.index_ = index
                        instance.privacy_ = privacy
                        instance.status = status
                        if let members = query.element(forName: "X-MEMBERS")?.stringValueAsNSInteger() {
                            instance.members = members
                        }
                    }
                    realm
                        .objects(ResourceStorageItem.self)
                        .filter("owner == %@ AND jid == %@", owner, from)
                        .forEach { $0.statusMessage = status }
                }
            } catch {
                DDLogDebug("vCardAvatarManager: \(#function). \(error.localizedDescription)")
            }
        }
        return true
    }
    
    private final func getEscapingElementValue(element: DDXMLElement?) -> String {
        return element?.stringValue ?? ""
    }
    
    public final func setSelfNickname(_ stream: XMPPStream, nickname: String) {
        let vcard = DDXMLElement(name: "vCard", xmlns: "vcard-temp")
        vcard.addChild(DDXMLElement(name: "NICKNAME", stringValue: nickname))
        stream.send(XMPPIQ(iqType: .set, to: nil, elementID: stream.generateUUID, child: vcard))
    }
    
    func getOrCreate(for jid: String, callback: ((vCardStorageItem)->Void)?) {
        RunLoop.main.perform {
            do {
                let realm = try  WRealm.safe()
                if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) {
                    realm.writeAsync {
                        callback?(instance)
                        let username = instance.generatedNickname
                        if jid == self.owner {
                            realm.object(ofType: AccountStorageItem.self,
                                         forPrimaryKey: self.owner)?.username = username
                        } else {
                            realm.object(ofType: RosterStorageItem.self,
                                         forPrimaryKey: [jid, self.owner].prp())?
                                .username = username
                        }
                    }
                } else {
                    let instance = vCardStorageItem()
                    instance.jid = jid
                    callback?(instance)
                    realm.writeAsync {
                        realm.add(instance, update: .modified)
                    
                        let newUsername = instance.generatedNickname

                        if jid == self.owner {
                            realm.object(ofType: AccountStorageItem.self,
                                         forPrimaryKey: self.owner)?.username = newUsername
                            
                        } else {
                            realm.object(ofType: RosterStorageItem.self,
                                         forPrimaryKey: [jid, self.owner].prp())?.username = newUsername
                            if let displayName = realm
                                .object(ofType: RosterStorageItem.self,
                                        forPrimaryKey: [jid, self.owner].prp())?
                                .displayName {
                                RosterDisplayNameStorageItem.createOrUpdate(
                                    jid: jid,
                                    owner: self.owner,
                                    displayName: displayName,
                                    commitTransaction: false
                                )
                            }
                        }
                    }
                }
                if jid == self.owner {
                    self.actualizeAccountUsername()
                }
            } catch {
                DDLogDebug("cant save vcard instance for \(jid)")
            }
        }

    }
    
    func createFromDatasource(items: [VCardMetaItem]) {
        func fill(_ instance: vCardStorageItem) {
            items.forEach { (item) in
                switch item.key {
                case "ci_nickname":     instance.nickname = item.value
                case "ci_full_name":    instance.fn = item.value
                case "ci_given_name":   instance.given = item.value
                case "ci_middle_name":  instance.middle = item.value
                case "ci_family_name":  instance.family = item.value
                case "ci_birthday":     instance.birthdayString = item.value
                case "wp_title":        instance.title = item.value
                case "wp_role":         instance.role = item.value
                case "wp_orgname":      instance.orgname = item.value
                case "wp_orgunit":      instance.orgunit = item.value
                case "ph_workPhone":    instance.telWorkVoice = item.value
                case "ph_workFax":      instance.telWorkFax = item.value
                case "ph_workMsg":      instance.telWorkMsg = item.value
                case "ph_homePhone":    instance.telHomeVoice = item.value
                case "ph_homeFax":      instance.telHomeFax = item.value
                case "ph_homeMsg":      instance.telHomeMsg = item.value
                case "wa_pobox":        instance.adrWorkPoBox = item.value
                case "wa_address":      instance.adrWorkExtadd = item.value
                case "wa_street":       instance.adrWorkStreet = item.value
                case "wa_locality":     instance.adrWorkLocality = item.value
                case "wa_region":       instance.adrWorkRegion = item.value
                case "wa_pcode":        instance.adrWorkPCode = item.value
                case "wa_country":      instance.adrWorkCountry = item.value
                case "ha_pobox":        instance.adrHomePoBox = item.value
                case "ha_address":      instance.adrHomeExtadd = item.value
                case "ha_street":       instance.adrHomeStreet = item.value
                case "ha_locality":     instance.adrHomeLocality = item.value
                case "ha_region":       instance.adrHomeRegion = item.value
                case "ha_pcode":        instance.adrHomePCode = item.value
                case "ha_country":      instance.adrHomeCountry = item.value
                case "desc_email_work": instance.emailWork = item.value
                case "desc_email_home": instance.emailHome = item.value
                case "desc_xmppId":     instance.jabberId = item.value
                case "desc_descr":      instance.descr = item.value
                case "desc_url":        instance.url = item.value
                default:                break
                }
            }
            AccountManager.shared.find(for: owner)?.updateUsername(instance.generatedNickname)
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: self.owner) {
                if !realm.isInWriteTransaction{
                    try realm.write {
                        if instance.isInvalidated { return }
                        fill(instance)
                    }
                }
            } else {
                let instance = vCardStorageItem()
                instance.jid = owner
                fill(instance)
                if !realm.isInWriteTransaction{
                    try realm.write {
                        if instance.isInvalidated { return }
                        realm.add(instance, update: .modified)
                        if instance.nickname.isNotEmpty {
                            realm.object(ofType: AccountStorageItem.self,
                                         forPrimaryKey: self.owner)?.username = instance.nickname
                        }
                    }
                }
            }
        } catch {
            DDLogDebug(["cant update instance of user vcard", owner, #function].joined(separator: ". "))
        }
    }
    
    open var addContactVcardCheckCallback: ((String, Bool) -> Void)? = nil
    open var addContactVcardCheckId: String? = nil
    
    public final func requestItem(_ xmppStream: XMPPStream, jid: String, addContactVcardCheckCallback: ((String, Bool) -> Void)? = nil) {
        let elementId = "vCard: \(NanoID.new(8))"
        let iq = XMPPIQ(
            iqType: .get,
            to: jid == self.owner ? nil : XMPPJID(string: jid),
            elementID: elementId,
            child: DDXMLElement(name: "vCard", xmlns: getPrimaryNamespace())
        )
        if addContactVcardCheckCallback != nil {
            self.addContactVcardCheckCallback = addContactVcardCheckCallback
            self.addContactVcardCheckId = elementId
        }
        xmppStream.send(iq)
    }
    
    public final func requestIfMissed(_ stream: XMPPStream, jid: String) {
        do {
            let realm = try WRealm.safe()
            if realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) == nil {
                self.requestItem(stream, jid: jid)
            }
        } catch {
            DDLogDebug("VCardManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func update(_ xmppStream: XMPPStream) {
        
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: self.owner) {
                let elementId = xmppStream.generateUUID
                let iq = XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: instance.getXMLData())
                xmppStream.send(iq)
            }
        } catch {
            DDLogDebug("cant update vcard instance")
        }
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try  WRealm.safe()
            var collection: [vCardStorageItem] = []
            realm.objects(RosterStorageItem.self)
                .filter("owner == %@", owner)
                .map({ return $0.jid })
                .forEach({
                    if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: $0) {
                        collection.append(instance)
                    }
                })
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                }
            } else {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("cant save vcard instance")
        }
    }
    
}
