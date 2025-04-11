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
import AVFoundation
import AudioUnit
import CocoaLumberjack
import Cache

protocol MulticastAVAudioPlayerDelegate {
    func staticMulticastId() -> String
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?)
    func audioPlayerBeginInterruption(_ player: AVAudioPlayer)
    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int)
}

class AudioManager: NSObject {
    
    enum AudioManagerError: Error {
        case fileNotFound
    }
    
    open class var shared: AudioManager {
        struct AudioManagerSingleton {
            static let instance = AudioManager()
        }
        return AudioManagerSingleton.instance
    }
    
    //    audio
    var player: AVAudioPlayer? = nil {
        didSet {
            if player == nil {
                self.currentPlayingTitle = nil
                self.currentPlayingSubtitle = nil
                self.messagePrimary = nil
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setActive(false)
                    UIDevice.current.isProximityMonitoringEnabled = false
                } catch {
                    DDLogDebug("AudioManager: \(#function). \(error.localizedDescription)")
                }
            } else {
                self.player?.delegate = self
                do {
                    UIDevice.current.isProximityMonitoringEnabled = true
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .voiceChat, policy: .longFormAudio, options: [.duckOthers, .allowAirPlay, .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
                    try session.setActive(true)
                    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                    try session.overrideOutputAudioPort(.speaker)
                } catch {
                    DDLogDebug("AudioManager: \(#function). \(error.localizedDescription)")
                }
            }
        }
    }
    
    open var multicastAudioDelegate: [MulticastAVAudioPlayerDelegate?] = []
    
    open func addMulticastDelegate(_ delegate: MulticastAVAudioPlayerDelegate?) {
        if !self.multicastAudioDelegate.contains(where: { $0?.staticMulticastId() == delegate?.staticMulticastId() }) {
            self.multicastAudioDelegate.append(delegate)
        }
    }
    
    open func removeMulticastDelegate(_ delegate: MulticastAVAudioPlayerDelegate?) {
        self.multicastAudioDelegate.removeAll(where: { $0?.staticMulticastId() == delegate?.staticMulticastId() })
    }
    
    var currentPlayingTitle: String? = nil
    var currentPlayingSubtitle: String? = nil
    var messagePrimary: String? = nil
    //    cache
    let diskConfig = DiskConfig(
        name: "xabber.ios.storage",
        expiry: .never,
        maxSize: 65353,
        directory: nil,
        protectionType: .completeUnlessOpen
    )
    
    let memoryConfig = MemoryConfig(
        expiry: .seconds(600),
        countLimit: 200,
        totalCostLimit: 0
    )
    
    lazy var storage: Storage? = try? Storage<String, Data>(
        diskConfig: self.diskConfig,
        memoryConfig: self.memoryConfig,
        fileManager: FileManager.default,
        transformer: TransformerFactory.forData()
    )
    //    params
    private let numberOfChannels: UInt8 = 1
    private let sampleRate: Int = 48000
    private let bitsPerSample: UInt8 = 16
    private var frameSize: Int {
        return 480 / (48000 / sampleRate)
    }
    
    override init() {
        super.init()
        player = nil
    }
    
    public final func loadMetadata(reference primary: String?) {
        guard let primary = primary else {
            return
        }
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary) {
                
                
                self.currentPlayingSubtitle = instance.name
                self.messagePrimary = instance.messageId
                let primary = instance.messageId
                let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
                if message?.outgoing ?? false {
                    if let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: message?.owner) {
                        self.currentPlayingTitle = account.username
                    } else {
                        self.currentPlayingTitle = message?.owner
                    }
                } else {
                    if let rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: message?.opponent ?? instance.jid, owner: instance.owner)) {
                        self.currentPlayingTitle = rosterItem.displayName
                    } else {
                        self.currentPlayingTitle = instance.jid
                    }
                }
                
            }
        } catch {
            DDLogDebug("AudioManager: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    
    
    func cache(_ url: URL, data: Data) {
        do {
            try storage?.setObject(data, forKey: url.absoluteString)
            //            (data as NSData).write(toFile: [url.absoluteString, "_file_",ext].joined(), atomically: true
//            url    Foundation.URL    "file:///var/mobile/Containers/Data/Application/CEEEF194-47E6-4669-AF0C-DD493F47D94C/Library/Caches/BkaUwUclIw"    
        } catch {
            DDLogDebug("cant set cache data for url \(url.absoluteString): \(error.localizedDescription)")
        }
    }
    
    func isCached(_ url: URL) -> Bool {
        do {
            guard let result = try storage?.existsObject(forKey: url.absoluteString) else { return false }
            return result
        } catch {
            return false
        }
    }
    
    func load(_ url: URL) throws -> Data? {
        return try storage?.object(forKey: url.absoluteString)
    }
    
    func remove(_ url: URL) {
        do {
            try storage?.removeObject(forKey: url.absoluteString)
        } catch {
            DDLogDebug("cant clear cache data for url \(url.absoluteString): \(error.localizedDescription)")
        }
    }
    
}

extension AudioManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.multicastAudioDelegate.forEach {
            delegate in
            delegate?.audioPlayerDidFinishPlaying(player, successfully: flag)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        self.multicastAudioDelegate.forEach {
            delegate in
            delegate?.audioPlayerDecodeErrorDidOccur(player, error: error)
        }
    }

    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        self.multicastAudioDelegate.forEach {
            delegate in
            delegate?.audioPlayerBeginInterruption(player)
        }
    }

    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
        self.multicastAudioDelegate.forEach {
            delegate in
            delegate?.audioPlayerEndInterruption(player, withOptions: flags)
        }
    }
}
