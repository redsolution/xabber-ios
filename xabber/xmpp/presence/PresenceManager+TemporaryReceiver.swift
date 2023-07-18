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

extension PresenceManager {
    
    public final func checkTemporarySubscribtions() {
        DispatchQueue(
            label: "com.xabber.temporary.receiver.\(UUID().uuidString)",
            qos: .background,
            attributes: .concurrent,
            autoreleaseFrequency: .workItem,
            target: nil
        ).asyncAfter(deadline: .now() + 0.3) {
            
            let defaults  = UserDefaults.init(suiteName: PushNotificationsManager.suitName)
            let collection: [String] = defaults?.object(forKey: "com.xabber.presences.temporary.\(self.owner)") as? [String] ?? []
            collection
                .compactMap { return try? DDXMLDocument(xmlString: $0, options: 0) }
                .compactMap { return $0.rootElement() }
                .compactMap { return XMPPPresence(from: $0) }
                .forEach { _ = self.read(withPresence: $0) }
            
            defaults?.set([], forKey: "com.xabber.presences.temporary.\(self.owner)")
        }
    }
}
