//
//  FeedbackManager.swift
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
import UIKit
import AudioToolbox
import CoreHaptics
import CocoaLumberjack

class FeedbackManager: NSObject {
    
    open class var shared: FeedbackManager {
        struct FeedbackManagerSingleton {
            static let instance = FeedbackManager()
        }
        return FeedbackManagerSingleton.instance
    }
    
    enum Feedback {
        case success
        case error
    }
    
    internal var hasHapticEngine: Bool = false
    var engine: CHHapticEngine?
    
    let hapticDict = [
        CHHapticPattern.Key.pattern: [
            [CHHapticPattern.Key.event: [
                CHHapticPattern.Key.eventType: CHHapticEvent.EventType.hapticTransient,
                CHHapticPattern.Key.time: CHHapticTimeImmediate,
                CHHapticPattern.Key.eventDuration: 1]
            ]
        ]
    ]
    
    override init() {
//        self.hasHapticEngine = UIDevice.isOldIPhonesFamily
        do {
            self.engine = try CHHapticEngine()
        } catch  {
            DDLogDebug("FeedbackManager: \(#function). \(error.localizedDescription)")
        }
        super.init()
        self.engine?.resetHandler = {
            do {
                try self.engine?.start()
            } catch {
                DDLogDebug("FeedbackManager: \(#function). \(error.localizedDescription)")
            }
        }
        self.engine?.stoppedHandler = { reason in
            print("Stop Handler: The engine stopped for reason: \(reason.rawValue)")
            switch reason {
                case .audioSessionInterrupt: print("Audio session interrupt")
                case .applicationSuspended: print("Application suspended")
                case .idleTimeout: print("Idle timeout")
                case .systemError: print("System error")
                case .notifyWhenFinished: print("notifyWhenFinished")
                case .engineDestroyed: print("engineDestroyed")
                case .gameControllerDisconnect: print("gameControllerDisconnect")
                @unknown default:
                    print("Unknown error")
            }
        }
    }
    

    
    open func generate(feedback: Feedback) {
        DispatchQueue.main.async {
            switch feedback {
            case .success:
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
            case .error:
                    let generator = UIImpactFeedbackGenerator(style: .rigid)
                    generator.impactOccurred()
            }
        }
    }
    
    public final func tap() {
        do {
            let pattern = try CHHapticPattern(dictionary: hapticDict)
            let player = try engine?.makePlayer(with: pattern)
            engine?.notifyWhenPlayersFinished { error in
                return .stopEngine
            }


            try engine?.start()
            try player?.start(atTime: 0)
        } catch {
            print(error.localizedDescription)
        }
        
//        if hasHapticEngine {
//            UINotificationFeedbackGenerator().notificationOccurred(.success)
//        } else {
//            AudioServicesPlaySystemSound(1519)
//        }
    }
    
    public func successFeedback() {
        if hasHapticEngine {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
//            var generator = UINotificationFeedbackGenerator()
//            generator.notificationOccurred(.success)
//            generator.impactOccurred()
        } else {
            AudioServicesPlaySystemSound(1519)
        }
    }
    
    public func errorFeedback() {
        if hasHapticEngine {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
    
}
