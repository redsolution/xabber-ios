////
////  OmemoManagerAxolotl.swift
////  clandestino
////
////  Created by Игорь Болдин on 23.03.2023.
////  Copyright © 2023 Igor Boldin. All rights reserved.
////
//
//import Foundation
//import XMPPFramework
//import SignalProtocolObjC
//import Curve25519Kit
//import RealmSwift
//import CocoaLumberjack
//
//class OmemoManagerAxolotl: AbstractXMPPManager {
//    let localStore: XabberAxolotlStorage
//
//    override init(withOwner owner: String) {
//        self.localStore = XabberAxolotlStorage(withOwner: owner)
//        super.init(withOwner: owner)
//    }
//    
//    public func encryptMessage(_ message: XMPPMessage, to jid: String) -> XMPPMessage? {
//        
//        return nil
//    }
//        
//    public func updateDevicesListNode(_ xmppStream: XMPPStream) {
//        
//    }
//    
//    public func requestDevicesList(_ xmppStream: XMPPStream, for jid: String? = nil) {
//        
//    }
//    
//    public func requestBundleInfo(_ xmppStream: XMPPStream, deviceId: Int, for jid: String? = nil) {
//        
//    }
//    
//    
//    
//}
