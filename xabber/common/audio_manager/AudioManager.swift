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

class AudioManager {
    
    open class var shared: AudioManager {
        struct AudioManagerSingleton {
            static let instance = AudioManager()
        }
        return AudioManagerSingleton.instance
    }
    
    //    audio
    var player: AVAudioPlayer? = nil
    //    cache
    var storage: Storage<String, Data>? = nil
    //    params
    private let numberOfChannels: UInt8 = 1
    private let sampleRate: Int = 48000
    private let bitsPerSample: UInt8 = 16
    private var frameSize: Int {
        return 480 / (48000 / sampleRate)
    }
    
    init() {
        
        player = nil
        
        do {
            storage = try Storage(diskConfig: DiskConfig(name: "AudioStorage",
                                                         expiry: Expiry.seconds(TimeInterval(exactly: 6*60*60)!), // 6h
                maxSize: 50 * 1024 * 1024, // 50mb
                directory: nil,
                protectionType: nil),
                                  memoryConfig: MemoryConfig(expiry: Expiry.seconds(5*60),
                                                             countLimit: 0,
                                                             totalCostLimit: 0), transformer: Transformer<Data>(toData: { (data) -> Data in
                                                                return data
                                                             }, fromData: { (data) -> Data in
                                                                return data
                                                             }))
        } catch {
            DDLogDebug("cant invoke storage")
        }
    }
    
    func isCached(_ url: URL) -> Bool {
        do {
            guard let result = try storage?.existsObject(forKey: "\(url)") else { return false }
            return result
        } catch {
            return false
        }
    }
    
    func cache(_ url: URL, data: Data) {
        do {
            try storage?.setObject(data, forKey: url.absoluteString)
            //            (data as NSData).write(toFile: [url.absoluteString, "_file_",ext].joined(), atomically: true)
        } catch {
            DDLogDebug("cant set cache data for url \(url.absoluteString): \(error.localizedDescription)")
        }
    }
    
    func remove(_ url: URL) {
        do {
            try storage?.removeObject(forKey: url.absoluteString)
        } catch {
            DDLogDebug("cant clear cache data for url \(url.absoluteString): \(error.localizedDescription)")
        }
    }
    
    func buildMeters(_ data: Data) -> ([Float], Int){
        return ([], 0)
//        if data.isEmpty { return ([], 0) }
//        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(self.sampleRate), channels: 1, interleaved: false) else { return ([], 0) }
//        let buffer = data.makePCMBuffer(format: format)
//        let rawdBFS: [Int]
//        switch true {
//        case buffer?.int16ChannelData?[0] != nil:
//            rawdBFS = Array(UnsafeBufferPointer(start:buffer!.int16ChannelData![0], count: data.count / MemoryLayout<Int16>.size - MemoryLayout<Int16>.size)).map({ return Int($0) })
//            break
//        case buffer?.int32ChannelData?[0] != nil:
//            rawdBFS = Array(UnsafeBufferPointer(start:buffer!.int32ChannelData![0], count: data.count / MemoryLayout<Int32>.size - MemoryLayout<Int32>.size)).map({ return Int($0) })
//            break
//        default: return ([], 0)
//        }
//        
//        
//        let samplesCount = 54
//        let duration: Int = rawdBFS.count / sampleRate
//        let floatData = rawdBFS
//            .filter({$0 >= 0})
////            .map({ return Float(Float($0) / Float(maxSample))})
//        
//        let sampleSize = floatData.count / samplesCount
//        
//        var approximated: [Int] = []
//        
//        func filter(_ value: Float) -> Float {
//            if value < 0.075 { return 0}
//            return value
//        }
//        
//        var offset = 0
//        (0...samplesCount).forEach { sampleId in
//            if offset < floatData.count {
//                if offset + sampleSize >= floatData.count {
//                    approximated.append(Int(floatData.suffix(from: offset).max() ?? 0))
//                } else {
//                    approximated.append(Int(floatData.prefix(offset + sampleSize).suffix(from: offset).max() ?? 0))
//                }
//                offset += sampleSize
//            }
//        }
//        let maxSample = approximated.max() ?? Int.max
//        return (approximated.map({ return filter(Float(Float($0) / Float(maxSample)))}), duration)
    }
    
}
