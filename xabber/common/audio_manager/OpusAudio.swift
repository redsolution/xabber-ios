////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
///
import Foundation
import AVFAudio
import AVFoundation
import SwiftOGG
import CocoaLumberjack
import Cache

public class CommonCacheStorage: NSObject {
    open class var shared: CommonCacheStorage {
        struct CommonCacheStorageSingleton {
            static let instance = CommonCacheStorage()
        }
        return CommonCacheStorageSingleton.instance
    }
    
    let diskConfig = DiskConfig(
        name: "xabber.ios.storage",
        expiry: .never,
        maxSize: 65353,
        directory: nil,
        protectionType: .completeUnlessOpen
    )
    
    let memoryConfig = MemoryConfig(
        expiry: .seconds(360),
        countLimit: 20,
        totalCostLimit: 0
    )
    
    lazy var storage: Storage? = try? Storage<String, Data>(
        diskConfig: self.diskConfig,
        memoryConfig: self.memoryConfig,
        fileManager: FileManager.default,
        transformer: TransformerFactory.forData()
    )
    

    
    public func store(data: Data, url: URL) {
        
    }
}

enum DecodeError: Error {
    case fileNotFound
}

enum AudioMessageReceiverError: Error {
    case referenceNotFound
    case referenceAlreadyPrepared
    case urlNotFound
}

public class AudioMessageReceiver: NSObject {
    open class var shared: AudioMessageReceiver {
        struct AudioMessageReceiverSingleton {
            static let instance = AudioMessageReceiver()
        }
        return AudioMessageReceiverSingleton.instance
    }
    
    public func decode(url: URL) throws -> URL {
        guard let filepath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let fullUrl = URL(string: "\(filepath.absoluteString)\(NanoID.new(10))") else {
            throw DecodeError.fileNotFound
        }
        try OGGConverter.convertOpusOGGToM4aFile(src: url, dest: fullUrl)
        let data = try Data(contentsOf: fullUrl)
        AudioManager.shared.cache(fullUrl, data: data)
        return fullUrl
    }
    
    public func encode(url: URL) throws -> URL {
        guard let filepath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let fullUrl = URL(string: "\(filepath.absoluteString)\(NanoID.new(10)).ogg") else {
            throw DecodeError.fileNotFound
        }
        try OGGConverter.convertM4aFileToOpusOGG(src: url, dest: fullUrl)
        return fullUrl
    }
    
    public func receive(primary: String) throws -> URL {
        let realm = try WRealm.safe()
        guard let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary) else {
            throw AudioMessageReceiverError.referenceNotFound
        }
        guard !instance.isDownloaded  else {
            throw AudioMessageReceiverError.referenceAlreadyPrepared
        }
        guard let uri = instance.url,
              let url = URL(string: uri) else {
            throw AudioMessageReceiverError.urlNotFound
        }
        let decodedUrl = try self.decode(url: url)
        let pcm = try self.getPCM(decoded: decodedUrl)
        
        
        print(pcm)
        print(1)
        
        try realm.write {
            instance.decodedUrl = decodedUrl
            instance.meteringLevels = pcm
        }
        return decodedUrl
    }
    
    public func getDuration(decoded urlDecoded: URL) throws -> Int {
        return Int(try OGGConverter.getDuration(src: urlDecoded))
    }
    
    public func getPCM(decoded urlDecoded: URL) throws -> [Float] {
        return try OGGConverter.getPCM(src: urlDecoded)
//        let data = try Data(contentsOf: urlEncoded)
//        let file = try AVAudioFile(forReading: urlDecoded)
//        let decoder = try OGGDecoder(audioData: data)
//        
//        
//        let format = file.fileFormat
//        guard let buffer = decoder.pcmData.toPCMBuffer(format: format) else { throw OGGConverterError.failedToCreatePCMBuffer }
//        
//        
//        var buffer: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: file.fileFormat., frameCapacity: UInt32(data.count))!
//        try file.read(into: buffer)
//        
////        buffer.
//        
//        let rawdBFS: [Int]
//        switch true {
//            case buffer.int16ChannelData?[0] != nil:
//                rawdBFS = Array(UnsafeBufferPointer(start:buffer.int16ChannelData![0], count: data.count / MemoryLayout<Int16>.size - MemoryLayout<Int16>.size)).map({ return Int($0) })
//                break
//            case buffer.int32ChannelData?[0] != nil:
//                rawdBFS = Array(UnsafeBufferPointer(start:buffer.int32ChannelData![0], count: data.count / MemoryLayout<Int32>.size - MemoryLayout<Int32>.size)).map({ return Int($0) })
//                break
//            default: return []
//        }
//        print(rawdBFS)
//        print(1)
//        
//        return []
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
////        
//        return []
    }
}


//
//import Foundation
//import AVFoundation
//import AudioUnit
//import CocoaLumberjack
//import Cache
//
//class OpusAudio {
//    
//    struct QueueItem: Hashable {
//        static func == (lhs: OpusAudio.QueueItem, rhs: OpusAudio.QueueItem) -> Bool {
//            return lhs.url == rhs.url
//        }
//        
//        let url: URL
//        let callback: ((Bool, [Float], Double)->Void)
//        
//        func hash(into hasher: inout Hasher) {
//            hasher.combine(url.absoluteString)
//        }
//    }
//    
//    open class var shared: OpusAudio {
//        struct OpusAduioSingleton {
//            static let instance = OpusAudio()
//        }
//        return OpusAduioSingleton.instance
//    }
////    params
//    internal let numberOfChannels: UInt8 = 1
//    internal let sampleRate: Int = 48000
//    internal let bitsPerSample: UInt8 = 16
//    internal var frameSize: Int {
//        return 480 / (48000 / sampleRate)
//    }
////    opus
//    internal var opusHelper: OpusHelper
////    ogg
//    internal var oggHelper: OggHelper
////    audio
//    open var player: AVAudioPlayer? = nil
//    internal var currentPlayedFileUri: String? = nil
////    cache
//    internal var storage: Storage<String, Data>? = nil
////    record
//    internal var micPermission: Bool = false
//    internal var isSessionActive: Bool = false
//    internal var isRecording: Bool = false
//    
//    internal var audioUnit: AudioUnit? = nil
//    
//    
//    internal let outputBus: UInt32 = 0
//    internal let inputBus: UInt32 = 1
//    
//    internal var decodeQueue: Array<QueueItem> = Array<QueueItem>()
//    
//    internal var isInDecodeProcess: Bool = false
//    
//    
//    internal let queue = DispatchQueue(
//        label: "com.xabber.opus.decoder",
//        qos: .background,
//        attributes: [],
//        autoreleaseFrequency: .workItem,
//        target: nil
//    )
//    
//    init() {
//        opusHelper = OpusHelper.init()
//        oggHelper = OggHelper.init()
//        
//        player = nil
//        
//        do {
//            storage = try Storage(diskConfig: DiskConfig(name: "VoicesStorage",
//                                                         expiry: Expiry.seconds(TimeInterval(exactly: 6*60*60)!), // 6h
//                maxSize: 25 * 1024 * 1024, // 25mb
//                directory: nil,
//                protectionType: nil),
//                                  memoryConfig: MemoryConfig(expiry: Expiry.seconds(5*60),
//                                                             countLimit: 0,
//                                                             totalCostLimit: 0), transformer: Transformer<Data>(toData: { (data) -> Data in
//                                                                return data
//                                                             }, fromData: { (data) -> Data in
//                                                                return data
//                                                             }))
//        } catch {
//            DDLogDebug("cant invoke storage")
//        }
//        
//    }
//    
//    open func add(_ url: URL, callback: @escaping ((Bool, [Float], Double)->Void)) {
//        if decodeQueue.contains(where: {$0.url == url }) { return }
//        decodeQueue.append(OpusAudio.QueueItem(url: url, callback: callback))
//        self.processDecodeQueue()
//    }
//    
//    internal func processDecodeQueue() {
//        if isInDecodeProcess { return }
//        if decodeQueue.isEmpty {
//            isInDecodeProcess = false
//            return
//        }
//        isInDecodeProcess = true
//        let item = decodeQueue.removeFirst()
//        self.decode(for: item.url, success: { _, meters, duration in
//            item.callback(true, meters, duration)
//            self.isInDecodeProcess = false
//            self.processDecodeQueue()
//
//        }) {
//            item.callback(false, [], 0)
//            self.isInDecodeProcess = false
//            self.processDecodeQueue()
//        }
//    }
//    
//    open func getPlayer(for url: URL) {
//        do {
//            if let currentUrl = currentPlayedFileUri,
//                currentUrl == url.absoluteString {
//                return
//            }
//            guard let data = try storage?.object(forKey: url.absoluteString) else { return }
//            currentPlayedFileUri = url.absoluteString
//            player = try AVAudioPlayer(data: data, fileTypeHint: "wav")
////            try AVAudioSession.sharedInstance().setCategory(.playback)
//            player?.prepareToPlay()
//        } catch {
//            DDLogDebug("OpusAudio: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    
//    open func getPlayerForPreview(for url: URL) -> Bool {
//        do {
//            if let currentUrl = currentPlayedFileUri,
//                currentUrl == url.absoluteString {
//                return false
//            }
//            
//            let data: Data
//            if let cachedData = try storage?.object(forKey: url.absoluteString) {
//                data = cachedData
//            } else {
//                data = try Data(contentsOf: URL(string: "file://\(url.absoluteString)")!)
//            }
//            
//            currentPlayedFileUri = url.absoluteString
////            try AVAudioSession.sharedInstance().setCategory(.playback)
//            let result = addWAVHeader(data,
//                                      sampleRate: self.sampleRate,
//                                      channels: self.numberOfChannels,
//                                      bits: self.bitsPerSample)
//            
//            player = try AVAudioPlayer(data: result, fileTypeHint: "wav")
//            player?.prepareToPlay()
//            return true
//        } catch {
//            DDLogDebug("OpusAudio: \(#function). \(error.localizedDescription)")
//            return false
//        }
//    }
//    
//    open func resetPlayer() {
//        player?.stop()
////        do {
////            try AVAudioSession.sharedInstance().setCategory(.soloAmbient)
////        } catch {
////            DDLogDebug("OpusAudio: \(#function). \(error.localizedDescription)")
////        }
//        player = nil
//        currentPlayedFileUri = nil
//    }
//    
//    internal func decode(_ data: Data, sampleRate: Int) -> Data? {
//        opusHelper = OpusHelper.init()
//        return opusHelper.opus(toPCM: data, sampleRate: sampleRate)
//    }
//    
//    internal func encode(_ data: Data, frameSize: Int) -> Data? {
//        if data.isEmpty { return nil }
//        opusHelper = OpusHelper.init()
//        oggHelper = OggHelper.init()
//        let outBuf = NSMutableData()
//        let pointer = (data as NSData).bytes
//        opusHelper.createEncoder(Int32(sampleRate))
//        let length = data.count
//        let chunkSize = frameSize * 2
//        var offset: Int = 0
//        
//        let header = Header(
//            outputChannels: 1,
//            preskip: UInt16(frameSize) * 12,
//            inputSampleRate: UInt32(sampleRate),
//            outputGain: 0,
//            channelMappingFamily: .rtp
//        )
//        
//        if let newData = oggHelper.writeHeaderPacket(header.toData(), comment: false) {
//            outBuf.append(newData as Data)
//        }
//        
//        if let newData = oggHelper.writeHeaderPacket(CommentHeader().toData(), comment: true) {
//            outBuf.append(newData as Data)
//        }
//        repeat {
//            let isEndPage: Bool = length - offset < chunkSize
//            let currentChunkSize = !isEndPage ? chunkSize : length - offset
//            let chunk = NSData(bytes: pointer.advanced(by: offset), length: currentChunkSize)
//            if let compressed = opusHelper.encode(chunk as Data, frameSize: Int32(frameSize)) {
//                if let newData = oggHelper.writePacket(compressed, frameSize: Int32(frameSize), end: isEndPage) {
//                    outBuf.append(newData.bytes, length: newData.length)
//                }
//            }
//            offset += currentChunkSize
//        } while offset < length
//        return outBuf as Data
//    }
//    
//    open func meters(for url: URL, failure: ((Error?)->Void)?, completionHandler: (([Float], Double)->Void)?) {
//        do {
//            let data = try Data(contentsOf: URL(string: "file://\(url.absoluteString)")!)
//            let meters: [Float]
//            let duration: Double
//            (meters, duration) = self.buildMeterLevels(data)
//            completionHandler?(meters, duration)
//        } catch {
//            failure?(error)
//        }
//    }
//    
//    open func preparePreview(for url: URL) -> [Float] {
//        do {
//            let data = try Data(contentsOf: URL(string: "file://\(url.absoluteString)")!)
//            let meters: [Float]
//            (meters, _) = self.buildMeterLevels(data)
//            return meters
//        } catch {
//            DDLogDebug("OpusAudio: \(#function). \(error.localizedDescription)")
//            return [0.0]
//        }
//    }
//    
//    public final func encode(for url: URL, completionHandler: ((Data, [Float], Error?)->Void)?) {
//        DispatchQueue.global(qos: .default).async {
//            do{
//                let data = try Data(contentsOf: URL(string: "file://\(url.absoluteString)")!)
//                let meters: [Float]
//                (meters, _) = self.buildMeterLevels(data)
//                guard let encoded = self.encode(data, frameSize: self.frameSize) else {
//                    DDLogDebug("cant encode data")
//                    return
//                }
//                self.cache(url, data: encoded)
//                DispatchQueue.main.async {
//                    completionHandler?(encoded, meters, nil)
//                }
//            } catch {
//                DispatchQueue.main.async {
//                    completionHandler?(Data(), [], error)
//                }
//                DDLogDebug(error.localizedDescription)
//            }
//        }
//    }
//    
//    open func decode(for url: URL, success: ((Data, [Float], Double)->Void)? = nil, failure: (()->Void)? = nil) {
//        
//        self.queue.async {
//            guard let data = try? Data(contentsOf: url) else {
//                DDLogDebug("cant load data")
//                failure?()
//                return
//            }
//            guard let result = self.decode(data, sampleRate: self.sampleRate) else {
//                DDLogDebug("cant decode data")
//                print(url)
//                failure?()
//                return
//            }
//            let wavData = self.addWAVHeader(result, sampleRate: self.sampleRate, channels: self.numberOfChannels, bits: self.bitsPerSample)
//            let meters: [Float]
//            let duration: Double
//            (meters, duration) = self.buildMeterLevels(result)
//            self.cache(url, data: wavData)
//            success?(Data(), meters, duration)
//        }
//        
//    }
//    
//    open func buildMeterLevels(_ data: Data) -> ([Float], Double) {
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
//        let duration: Double = Double(rawdBFS.count) / Double(sampleRate)
//        let floatData = rawdBFS
//            .filter({$0 >= 0})
////            .map({ return Float(Float($0) / Float(maxSample))})
//        
//        let sampleSize = floatData.count / samplesCount
//        
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
//        var maxSample: Float = Float(max(approximated.max() ?? Int.max, 1))
//        if maxSample == 0 { maxSample = 0.075}
//        return (approximated.map({ return filter(Float(Float($0) / Float(maxSample)))}), duration)
//    }
//    
//    open func isCached(_ url: URL) -> Bool {
//        do {
//            guard let result = try storage?.existsObject(forKey: "\(url)") else { return false }
//            return result
//        } catch {
//            return false
//        }
//    }
//    
//    open func cacheAsWAV(_ url: URL) -> URL? {
//        do {
//            guard let data = try storage?.object(forKey: "\(url)") else { return nil }
//            if let newUrl = URL(string: [url.absoluteString, "_preview.wav"].joined()) {
//                self.cache(newUrl, data: self.addWAVHeader(data, sampleRate: self.sampleRate, channels: self.numberOfChannels, bits: self.bitsPerSample))
//                return newUrl
//            }
//        } catch {
//            DDLogDebug("OpusAduio: \(#function). \(error.localizedDescription)")
//        }
//        return nil
//    }
//    
//    open func cache(_ url: URL, data: Data) {
//        do {
//            try storage?.setObject(data, forKey: url.absoluteString)
////            (data as NSData).write(toFile: [url.absoluteString, "_file_",ext].joined(), atomically: true)
//        } catch {
//            DDLogDebug("cant set cache data for url \(url.absoluteString): \(error.localizedDescription)")
//        }
//    }
//    
//    open func remove(_ url: URL) {
//        do {
//            try storage?.removeObject(forKey: url.absoluteString)
//        } catch {
//            DDLogDebug("cant clear cache data for url \(url.absoluteString): \(error.localizedDescription)")
//        }
//    }
//    
//    internal func addWAVHeader(_ pcmData: Data, sampleRate: Int, channels: UInt8, bits: UInt8) -> Data {
//        let headerSize = 44
//        let totalDataLen = pcmData.count
//        let totalAudioLen = totalDataLen + headerSize - 8
//        let longSampleRate = sampleRate == 0 ? 48000 : sampleRate
//        let byteRate = Int(bits) * longSampleRate * Int(channels) / 8
//        
//        let header = UnsafeMutablePointer<UInt8>.allocate(capacity: headerSize)
//        
//        header[0]  = "R".ascii // R // RIFF/WAVE header
//        header[1]  = "I".ascii // I
//        header[2]  = "F".ascii // F
//        header[3]  = "F".ascii // F
//        header[4]  = UInt8 (totalDataLen & 0xff)
//        header[5]  = UInt8 ((totalDataLen >> 8) & 0xff)
//        header[6]  = UInt8 ((totalDataLen >> 16) & 0xff)
//        header[7]  = UInt8 ((totalDataLen >> 24) & 0xff)
//        header[8]  = "W".ascii // W
//        header[9]  = "A".ascii // A
//        header[10] = "V".ascii
//        header[11] = "E".ascii
//        header[12] = "f".ascii  // 'fmt ' chunk
//        header[13] = "m".ascii
//        header[14] = "t".ascii
//        header[15] = " ".ascii
//        header[16] = 16 // 4 bytes: size of 'fmt ' chunk
//        header[17] = 0
//        header[18] = 0
//        header[19] = 0
//        header[20] = 1  // format = 1
//        header[21] = 0
//        header[22] = channels
//        header[23] = 0
//        header[24] = UInt8 (longSampleRate & 0xff)
//        header[25] = UInt8 ((longSampleRate >> 8) & 0xff)
//        header[26] = UInt8 ((longSampleRate >> 16) & 0xff)
//        header[27] = UInt8 ((longSampleRate >> 24) & 0xff)
//        header[28] = UInt8 (byteRate & 0xff)
//        header[29] = UInt8 ((byteRate >> 8) & 0xff)
//        header[30] = UInt8 ((byteRate >> 16) & 0xff)
//        header[31] = UInt8 ((byteRate >> 24) & 0xff)
//        header[32] = UInt8 (2 * 8 / 8)  // block align
//        header[33] = 0
//        header[34] = bits  // bits per sample
//        header[35] = 0
//        header[36] = "d".ascii
//        header[37] = "a".ascii
//        header[38] = "t".ascii
//        header[39] = "a".ascii
//        header[40] = UInt8 (totalAudioLen & 0xff)
//        header[41] = UInt8 ((totalAudioLen >> 8) & 0xff)
//        header[42] = UInt8 ((totalAudioLen >> 16) & 0xff)
//        header[43] = UInt8 ((totalAudioLen >> 24) & 0xff)
//        
//        let outData: NSMutableData = NSMutableData(bytes: header, length: headerSize)
//        outData.append(pcmData)
//        free(header)
//        return outData as Data
//    }
//    
//}
//
//fileprivate class Header {
//    private(set) var magicSignature: [UInt8]
//    private(set) var version: UInt8
//    private(set) var outputChannels: UInt8
//    private(set) var preskip: UInt16
//    private(set) var inputSampleRate: UInt32
//    private(set) var outputGain: Int16
//    private(set) var channelMappingFamily: ChannelMappingFamily
//    
//    init(outputChannels: UInt8, preskip: UInt16, inputSampleRate: UInt32, outputGain: Int16, channelMappingFamily: ChannelMappingFamily) {
//        self.magicSignature = [ 0x4f, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64 ] // "OpusHead"
//        self.version = 1 // must always be `1` for this version of the encapsulation specification
//        self.outputChannels = outputChannels
//        self.preskip = preskip
//        self.inputSampleRate = inputSampleRate
//        self.outputGain = outputGain
//        self.channelMappingFamily = channelMappingFamily
//    }
//    
//    func toData() -> Data {
//        var data = Data()
//        data.append(magicSignature, count: magicSignature.count)
//        withUnsafePointer(to: &version) { ptr in data.append(ptr, count: MemoryLayout<UInt8>.size) }
//        withUnsafePointer(to: &outputChannels) { ptr in data.append(ptr, count: MemoryLayout<UInt8>.size) }
//        withUnsafePointer(to: &preskip) { ptr in ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { ptr in data.append(ptr, count: MemoryLayout<UInt16>.size) }}
//        withUnsafePointer(to: &inputSampleRate) { ptr in ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { ptr in data.append(ptr, count: MemoryLayout<UInt32>.size) }}
//        withUnsafePointer(to: &outputGain) { ptr in ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { ptr in data.append(ptr, count: MemoryLayout<UInt16>.size) }}
//        withUnsafePointer(to: &channelMappingFamily) { ptr in ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { ptr in data.append(ptr, count: MemoryLayout<ChannelMappingFamily>.size) }}
//        return data
//    }
//}
//
//fileprivate class CommentHeader {
//    private(set) var magicSignature: [UInt8]
//    private(set) var vendorStringLength: UInt32
//    private(set) var vendorString: String
//    private(set) var userCommentListLength: UInt32
//    private(set) var userComments: [Comment]
//    
//    init() {
//        magicSignature = [ 0x4f, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73 ] // "OpusTags"
//        vendorString = String(validatingUTF8: opus_get_version_string())!
//        vendorStringLength = UInt32(vendorString.count)
//        userComments = [Comment(tag: "ENCODER", value: "Clandestino OPUS encoder")]
//        userCommentListLength = UInt32(userComments.count)
//    }
//    
//    func toData() -> Data {
//        var data = Data()
//        data.append(magicSignature, count: magicSignature.count)
//        withUnsafePointer(to: &vendorStringLength) { ptr in ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { ptr in data.append(ptr, count: MemoryLayout<UInt32>.size) }}
//        data.append(vendorString.data(using: String.Encoding.utf8)!)
//        withUnsafePointer(to: &userCommentListLength) { ptr in ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { ptr in data.append(ptr, count: MemoryLayout<UInt32>.size) }}
//        for comment in userComments {
//            data.append(comment.toData())
//        }
//        return data
//    }
//}
//
//fileprivate class Comment {
//    private(set) var length: UInt32
//    private(set) var comment: String
//    
//    fileprivate init(tag: String, value: String) {
//        comment = "\(tag)=\(value)"
//        length = UInt32(comment.count)
//    }
//    
//    fileprivate func toData() -> Data {
//        var data = Data()
//        withUnsafePointer(to: &length) { ptr in ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { ptr in data.append(ptr, count: MemoryLayout<UInt32>.size) }}
//        data.append(comment.data(using: String.Encoding.utf8)!)
//        return data
//    }
//}
//
//enum ChannelMappingFamily: UInt8 {
//    case rtp = 0
//    case vorbis = 1
//    case undefined = 255
//}
//
//extension Data {
//    init(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
//        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
//        self.init(bytes: audioBuffer.mData!, count: Int(audioBuffer.mDataByteSize))
//    }
//    
//    func makePCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
//        let streamDesc = format.streamDescription.pointee
//        let frameCapacity = UInt32(count) / streamDesc.mBytesPerFrame
//        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
//        
//        buffer.frameLength = buffer.frameCapacity
//        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
//        
//        withUnsafeBytes { addr in
//            audioBuffer.mData?.copyMemory(from: addr, byteCount: Int(audioBuffer.mDataByteSize))
//        }
//        
//        return buffer
//    }
//}
