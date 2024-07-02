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
import CryptoSwift
import RealmSwift
//import Haneke
import CocoaLumberjack


class vCardStorageItem: Object {
    override static func primaryKey() -> String? {
        return "jid"
    }
    
    override static func indexedProperties() -> [String] {
        return ["jid"]
    }
    
    @objc dynamic var jid: String = ""
    //avatar
    @objc dynamic var avatarHash: String = ""
    //common
    @objc dynamic var fn: String = ""
    @objc dynamic var family: String = ""
    @objc dynamic var given: String = ""
    @objc dynamic var middle: String = ""
    @objc dynamic var nickname: String = ""
    @objc dynamic var birthday: Date = Date()
    @objc dynamic var birthdayString: String = ""
    //work
    @objc dynamic var orgname: String = ""
    @objc dynamic var orgunit: String = ""
    @objc dynamic var title: String = ""
    @objc dynamic var role: String = ""
    //work tel
    @objc dynamic var telWorkVoice: String = ""
    @objc dynamic var telWorkFax: String = ""
    @objc dynamic var telWorkMsg: String = ""
    //home tel
    @objc dynamic var telHomeVoice: String = ""
    @objc dynamic var telHomeFax: String = ""
    @objc dynamic var telHomeMsg: String = ""
    //work adr
    @objc dynamic var adrWorkPoBox: String = ""
    @objc dynamic var adrWorkExtadd: String = ""
    @objc dynamic var adrWorkStreet: String = ""
    @objc dynamic var adrWorkLocality: String = ""
    @objc dynamic var adrWorkRegion: String = ""
    @objc dynamic var adrWorkPCode: String = ""
    @objc dynamic var adrWorkCountry: String = ""
    //home adr
    @objc dynamic var adrHomePoBox: String = ""
    @objc dynamic var adrHomeExtadd: String = ""
    @objc dynamic var adrHomeStreet: String = ""
    @objc dynamic var adrHomeLocality: String = ""
    @objc dynamic var adrHomeRegion: String = ""
    @objc dynamic var adrHomePCode: String = ""
    @objc dynamic var adrHomeCountry: String = ""
    //other
//    @objc dynamic var emailInternet: String = ""
    @objc dynamic var emailWork: String = ""
    @objc dynamic var emailHome: String = ""
    @objc dynamic var jabberId: String = ""
    @objc dynamic var descr: String = ""
    @objc dynamic var url: String = ""
    
    @objc dynamic var lastUpdateDate: Date = Date(timeIntervalSince1970: 1)
    @objc dynamic var isLastUpdateErrorOccured: Bool = false
    
    var generatedNickname: String {
        get {
            if nickname.isNotEmpty { return nickname }
            let combinedNickname = [given, family]
                .compactMap { (item) -> String? in
                    return item.isNotEmpty ? item : nil
                }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if combinedNickname.isNotEmpty { return combinedNickname }
            if fn.isNotEmpty { return fn }
            return JidManager.shared.prepareJid(jid: jid)
        }
    }
    
    var unsafeGeneratedNickname: String? {
        get {
            if nickname.isNotEmpty { return nickname }
            let combinedNickname = [given, family]
                .compactMap { (item) -> String? in
                    return item.isNotEmpty ? item : nil
                }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if combinedNickname.isNotEmpty { return combinedNickname }
            if fn.isNotEmpty { return fn }
            return nil
        }
    }
    
    func getXMLData() -> DDXMLElement {
        let vCard = DDXMLElement.element(withName: "vCard") as! DDXMLElement
        vCard.setXmlns("vcard-temp")
        vCard.addChild(DDXMLElement.element(withName: "FN", stringValue: self.fn) as! DDXMLElement)
        
        let n = DDXMLElement.element(withName: "N") as! DDXMLElement
        n.addChild(DDXMLElement.element(withName: "FAMILY", stringValue: self.family) as! DDXMLElement)
        n.addChild(DDXMLElement.element(withName: "GIVEN", stringValue: self.given) as! DDXMLElement)
        n.addChild(DDXMLElement.element(withName: "MIDDLE", stringValue: self.middle) as! DDXMLElement)
        vCard.addChild(n)
        
        vCard.addChild(DDXMLElement.element(withName: "NICKNAME", stringValue: self.nickname) as! DDXMLElement)
        
        vCard.addChild(DDXMLElement.element(withName: "URL", stringValue: self.url) as! DDXMLElement)
        
        vCard.addChild(DDXMLElement.element(withName: "BDAY", stringValue: self.birthdayString) as! DDXMLElement)
        
        let org = DDXMLElement.element(withName: "ORG") as! DDXMLElement
        org.addChild(DDXMLElement.element(withName: "ORGNAME", stringValue: self.orgname) as! DDXMLElement)
        org.addChild(DDXMLElement.element(withName: "ORGUNIT", stringValue: self.orgunit) as! DDXMLElement)
        vCard.addChild(org)
        
        vCard.addChild(DDXMLElement.element(withName: "TITLE", stringValue: self.title) as! DDXMLElement)
        
        vCard.addChild(DDXMLElement.element(withName: "ROLE", stringValue: self.role) as! DDXMLElement)
        
        let telWorkVoice = DDXMLElement.element(withName: "TEL") as! DDXMLElement
        telWorkVoice.addChild(DDXMLElement.element(withName: "WORK") as! DDXMLElement)
        telWorkVoice.addChild(DDXMLElement.element(withName: "NUMBER", stringValue: self.telWorkVoice) as! DDXMLElement)
        vCard.addChild(telWorkVoice)
        
        
        let telHomeVoice = DDXMLElement.element(withName: "TEL") as! DDXMLElement
        telHomeVoice.addChild(DDXMLElement.element(withName: "HOME") as! DDXMLElement)
        telHomeVoice.addChild(DDXMLElement.element(withName: "NUMBER", stringValue: self.telHomeVoice) as! DDXMLElement)
        vCard.addChild(telHomeVoice)
        
        let telHomeMsg = DDXMLElement.element(withName: "TEL") as! DDXMLElement
        telHomeMsg.addChild(DDXMLElement.element(withName: "MOBILE") as! DDXMLElement)
        telHomeMsg.addChild(DDXMLElement.element(withName: "NUMBER", stringValue: self.telHomeMsg) as! DDXMLElement)
        vCard.addChild(telHomeMsg)
        
        let adrWork = DDXMLElement.element(withName: "ADR") as! DDXMLElement
        adrWork.addChild(DDXMLElement.element(withName: "WORK") as! DDXMLElement)
        adrWork.addChild(DDXMLElement(name: "POBOX", stringValue: self.adrWorkPoBox))
        adrWork.addChild(DDXMLElement.element(withName: "EXTADR", stringValue: self.adrWorkExtadd) as! DDXMLElement)
        adrWork.addChild(DDXMLElement.element(withName: "STREET", stringValue: self.adrWorkStreet) as! DDXMLElement)
        adrWork.addChild(DDXMLElement.element(withName: "LOCALITY", stringValue: self.adrWorkLocality) as! DDXMLElement)
        adrWork.addChild(DDXMLElement.element(withName: "REGION", stringValue: self.adrWorkRegion) as! DDXMLElement)
        adrWork.addChild(DDXMLElement.element(withName: "PCODE", stringValue: self.adrWorkPCode) as! DDXMLElement)
        adrWork.addChild(DDXMLElement.element(withName: "CTRY", stringValue: self.adrWorkCountry) as! DDXMLElement)
        vCard.addChild(adrWork)
        
        let adrHome = DDXMLElement.element(withName: "ADR") as! DDXMLElement
        adrHome.addChild(DDXMLElement.element(withName: "HOME") as! DDXMLElement)
        adrHome.addChild(DDXMLElement(name: "POBOX", stringValue: self.adrHomePoBox))
        adrHome.addChild(DDXMLElement.element(withName: "EXTADR", stringValue: self.adrHomeExtadd) as! DDXMLElement)
        adrHome.addChild(DDXMLElement.element(withName: "STREET", stringValue: self.adrHomeStreet) as! DDXMLElement)
        adrHome.addChild(DDXMLElement.element(withName: "LOCALITY", stringValue: self.adrHomeLocality) as! DDXMLElement)
        adrHome.addChild(DDXMLElement.element(withName: "REGION", stringValue: self.adrHomeRegion) as! DDXMLElement)
        adrHome.addChild(DDXMLElement.element(withName: "PCODE", stringValue: self.adrHomePCode) as! DDXMLElement)
        adrHome.addChild(DDXMLElement.element(withName: "CTRY", stringValue: self.adrHomeCountry) as! DDXMLElement)
        vCard.addChild(adrHome)
        
        let emailWork = DDXMLElement.element(withName: "EMAIL") as! DDXMLElement
        emailWork.addChild(DDXMLElement.element(withName: "WORK") as! DDXMLElement)
        emailWork.addChild(DDXMLElement.element(withName: "USERID", stringValue: self.emailWork) as! DDXMLElement)
        vCard.addChild(emailWork)
        
        let emailHome = DDXMLElement.element(withName: "EMAIL") as! DDXMLElement
        emailHome.addChild(DDXMLElement.element(withName: "HOME") as! DDXMLElement)
        emailHome.addChild(DDXMLElement.element(withName: "USERID", stringValue: self.emailHome) as! DDXMLElement)
        vCard.addChild(emailHome)
        
        vCard.addChild(DDXMLElement.element(withName: "DESC", stringValue: self.descr) as! DDXMLElement)
        
        return vCard
    }
}
