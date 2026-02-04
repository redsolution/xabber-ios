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
import PushKit
import CocoaLumberjack
import CallKit


extension AppDelegate: PKPushRegistryDelegate {
    
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { data -> String in
            return String(format: "%02.2hhx", data)
            }.joined()
//        print("voip \(token)")
//        print("********* TOKEN VOIP\(token)")
        APNSManager.shared.receive(voipToken: token)
        
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
//        print("pushkit receive invalid token")
        registry.pushToken(for: type)
        
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        DDLogDebug("pushkit push payload \(payload.dictionaryPayload)")
        self.isPushKit = true
//        print("receive push for completion \(payload.dictionaryPayload)")
        VoIPManager.shared.receiveCall(payload: payload.dictionaryPayload, completion: completion)
//        completion()
    }
}

extension Data {
    var token: String? {
        get {
            return self.map { data -> String in
                return String(format: "%02.2hhx", data)
            }.joined()
        }
    }
}
