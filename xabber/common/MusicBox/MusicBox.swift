//
//  MusicBox.swift
//  clandestino
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
import UserNotifications
import AudioUnit

class MusicBox: NSObject {
    
    var fileURLs: [URL] = []
    
    open class var shared: MusicBox {
        struct MusicBoxSingleton {
            static let instance = MusicBox()
        }
        return MusicBoxSingleton.instance
    }
    
    override private init() {
        super.init()
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "caf", subdirectory: nil) else {
            return
        }
        fileURLs = urls
//        fileURLs.forEach {
//            print($0.absoluteString)
//        }
    }
    
    private final func createSound(url: URL) -> SystemSoundID {
        
        var sysSound: SystemSoundID = .zero
        
        let osstatus = AudioServicesCreateSystemSoundID(url as CFURL, &sysSound)
//        if osstatus != kAudioServicesNoError {
//            print("Could not create system sound")
//            print("osstatus: \(osstatus)")
//        }
        
        return sysSound
    }
    
    public final func playSound(path: String) {
        
        guard let url = URL(string: path) else {
            return
        }
        
        let sound = createSound(url: url)
        AudioServicesPlaySystemSound(sound)
    }
    
    public final func getNotificationSound(for event: NotifyType = .newMessage) -> UNNotificationSound {
    
        var key: SettingsViewController.Datasource.Keys?

        switch event {
        case .newMessage:
            key = .chatChooseMessageSound
            break
        case .subscription:
            key = .chatChooseSubscriptionSound
            break
        default:
            break
        }
        
        guard let key = key,
              let fileName = SettingManager.shared.getString(for: key.rawValue) else {
            return UNNotificationSound.default
        }
        
        let soundName = UNNotificationSoundName(rawValue: fileName)
        let notifySound = UNNotificationSound(named: soundName)
        
        return notifySound
    }
    
    public final func prepare() {
        
    }
}
