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
import XMPPFramework
import CocoaLumberjack

extension MessageManager {
        
    public func checkTemporaryMessages() {
//        DispatchQueue(
//            label: "com.xabber.temporary.receiver.\(self.owner).\(UUID().uuidString)",
//            qos: .utility,
//            attributes: [],
//            autoreleaseFrequency: .workItem,
//            target: nil
//        )
        // -------------
//        DispatchQueue.global(qos: .default)
//            .asyncAfter(deadline: .now() + 0.4) {
//            let defaults  = UserDefaults.init(suiteName: PushNotificationsManager.suitName)
//            let collection: [String] = defaults?.object(forKey: "com.xabber.messages.temporary.\(self.owner)") as? [String] ?? []
//            let items = collection
//                .compactMap { return try? DDXMLDocument(xmlString: $0, options: 0) }
//                .compactMap { return $0.rootElement() }
//                .compactMap { return XMPPMessage(from: $0) }
//                .compactMap {
//                    if isArchivedMessage($0),
//                       let bareMessage = getArchivedMessageContainer($0) {
//                        if AccountManager.shared.find(for: self.owner)?.groupchats.readInvite(in: bareMessage, date: getDelayedDate($0) ?? Date(), isRead: false, commit: true) ?? false {
//                            return nil
//                        } else if AccountManager.shared.find(for: self.owner)?.groupchats.readMessage(withMessage: $0) ?? false {
//                            return nil
//                        } else {
//                            if let message = AccountManager.shared.find(for: self.owner)?.omemo.didReceiveOmemoMessageFromPush($0) {
//                                return message
//                            }
//                            return  $0
//                        }
//                    } else {
//                        if let message = AccountManager.shared.find(for: self.owner)?.omemo.didReceiveOmemoMessageFromPush($0) {
//                            return message
//                        }
//                        return $0
//                    }
//
//
//
//                }
//                .compactMap { return self.receiveTemporary($0) }
//
//
////            let array = SynchronizedArray<MessageQueueItem>()
////
////            array.append(items)
//
//            self.processQueue(Set(items)) {
//                if let results = $0 {
//                    self.save(results, silentNotifications: true)
//                }
//            }
            // --------------
//        UserDefaults.init(suiteName: PushNotificationsManager.suitName)?.set([], forKey: "com.xabber.messages.temporary.\(self.owner)")
//        }
    }
}
