//
//  XMPPActionManager+XMPPStreamDelegate.swift
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

extension XMPPActionManager: XMPPStreamDelegate {
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
            DDLogDebug("XMPPActionManager: \(#function). \(error)")
        }
    }
    
    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        stanzaQueue.forEach {
            sender.send($0)
        }
        sender.disconnectAfterSending()
        sender.myJID = nil
        self.jid = nil
        self.password = nil
        self.stanzaQueue = []
        self.endBackgroundUpdateTask()
//        self.stream.removeDelegate(self)
//        self.stream = XMPPStream()
    }
}
