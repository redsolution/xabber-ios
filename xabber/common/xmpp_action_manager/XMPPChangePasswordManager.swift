//
//  XMPPActionManager.swift
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
import XMPPFramework
import SwiftKeychainWrapper
import SwiftUI

protocol XMPPChangePasswordManagerDelegate {
    func didReceiveResponse(title: String, description: String)
}

class XMPPChangePasswordManager: NSObject {
    open class var shared: XMPPChangePasswordManager {
        struct XMPPChangePasswordManagerSingleton {
            static let instance = XMPPChangePasswordManager()
        }
        return XMPPChangePasswordManagerSingleton.instance
    }
    
    var jid: String? = nil
    var password: String? = nil
    var newPassword: String? = nil
    var stream: XMPPStream = XMPPStream()
    var queue: DispatchQueue
    var backgroundUpdateTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    var delegate: XMPPChangePasswordManagerDelegate?
    
    override init() {
        queue = DispatchQueue(
            label: "com.xabber.action.manager.\(UUID().uuidString)",
            qos: .background,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        super.init()
    }

    func endBackgroundUpdateTask() {
        UIApplication.shared.endBackgroundTask(self.backgroundUpdateTask)
       self.backgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
    }
    
    public final func changePassword(jid: String, oldPassword: String, newPassword: String, delegate: XMPPChangePasswordManagerDelegate?) {
        self.jid = jid
        self.password = oldPassword
        self.newPassword = newPassword
        self.delegate = delegate
        
        queue.async {
            self.backgroundUpdateTask = UIApplication.shared.beginBackgroundTask(withName: UUID().uuidString, expirationHandler: {
                self.endBackgroundUpdateTask()
            })
            self.stream.myJID = XMPPJID(string: jid, resource: AccountManager.defaultResource + "fast_send")
            self.stream.startTLSPolicy = XMPPStreamStartTLSPolicy.allowed
            self.stream.keepAliveInterval = 60
            self.stream.addDelegate(self, delegateQueue: self.queue)
            do {
                try self.stream.connect(withTimeout: 3)
            } catch {
                DDLogDebug("XMPPChangePasswordManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    public func makeNewPasswordIq() -> XMPPElement? {
        guard let jid = self.jid,
              let username = jid.split(separator: "@").first,
              let domain = jid.split(separator: "@").last else {
            return nil
        }
        let elementId = self.stream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: "jabber:iq:register")
        let usernameChild = DDXMLElement(name: "username", stringValue: String(username))
        let passwordChild = DDXMLElement(name: "password", stringValue: newPassword)
        let key = DDXMLElement(name: "key", stringValue: "dde89e4b361zljrv")
        query.addChild(usernameChild)
        query.addChild(passwordChild)
        //query.addChild(key)
        let iq = XMPPIQ(iqType: .set, to: XMPPJID(string: String(domain)), elementID: elementId, child: query)
        return iq
    }
    
    private func close(_ sender: XMPPStream) {
        sender.disconnect()
        sender.myJID = nil
        self.jid = nil
        self.password = nil
        self.endBackgroundUpdateTask()
        self.stream.removeDelegate(self)
        self.stream = XMPPStream()
    }
}

extension XMPPChangePasswordManager: XMPPStreamDelegate {
    func xmppStreamDidConnect(_ sender: XMPPStream) {
        guard let password = password else {
            self.stream.disconnect()
            self.stream.myJID = nil
            self.jid = nil
            self.password = nil
            return
        }
        do {
            try sender.authenticate(withPassword: password)
        } catch {
            DDLogDebug("XMPPChangePasswordManager: \(#function). \(error)")
        }
    }
    
    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        guard let iq = makeNewPasswordIq() else {
            close(sender)
            return
        }
        sender.send(iq)
    }
    
    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        close(sender)
        guard let text = error.elements(forName: "text").first?.stringValue else {
            return
        }
        delegate?.didReceiveResponse(title: "Authorization error".localizeString(id: "AUTHENTICATION_FAILED", arguments: []), description: text)
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        
        switch iq.iqType {
        
        case .result:
            close(sender)
            delegate?.didReceiveResponse(title: "Success", description: "Password changed")
        
        case .error:
            close(sender)
            if let language = TranslationsManager.shared.currentLang { //выбран язык
                let code = TranslationsManager.shared.prepareLanCode(language: language)
                if let errorDescriptions = iq.element(forName: "error")?.elements(forName: "text") { //есть описания ошибок
                    if let errorLocalDescription = errorDescriptions.first(where: { $0.attributeStringValue(forName: "lang") == code })?.stringValue { //есть описание, соответствующее выбранному языку
                        delegate?.didReceiveResponse(title: "Error".localizeString(id: "error", arguments: []), description: errorLocalDescription)
                    } else if let errorEnDescription = errorDescriptions.first(where: { $0.attributeStringValue(forName: "lang") == "en" })?.stringValue { //или хотя бы на английском
                        delegate?.didReceiveResponse(title: "Error".localizeString(id: "error", arguments: []), description: errorEnDescription)
                    } else {
                        let errorOnlyDescription = errorDescriptions.first?.stringValue //или хоть какое есть первое попавшееся
                        delegate?.didReceiveResponse(title: "Error".localizeString(id: "error", arguments: []), description: errorOnlyDescription ?? "Unknown error")
                    }
                } else { //нет никаких описаний
                    delegate?.didReceiveResponse(title: "Error".localizeString(id: "error", arguments: []), description: "Unknown error")
                }
            } else if let errorDescriptions = iq.element(forName: "error")?.elements(forName: "text") { //не выбран язык, есть описания ошибок
                if let errorEnDescription = errorDescriptions.first(where: { $0.attributeStringValue(forName: "lang") == "en" })?.stringValue { //есть описание на английском
                    delegate?.didReceiveResponse(title: "Error", description: errorEnDescription)
                } else {
                    let errorOnlyDescription = errorDescriptions.first?.stringValue  //или хоть какое есть первое попавшееся
                    delegate?.didReceiveResponse(title: "Error", description: errorOnlyDescription ?? "Unknown error")
                }
            } else { //не выбран язык и нет никаких описаний
                delegate?.didReceiveResponse(title: "Error", description: "Unknown error")
            }
        
        default: return false
        }
        
        return true
    }
}
