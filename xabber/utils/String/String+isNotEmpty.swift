//
//  String+isNotEmpty.swift
//  xabber
//
//  Created by Игорь Болдин on 14.12.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation

extension String {
    
    var isNotEmpty: Bool {
        get {
            return !self.isEmpty
        }
    }
    
    func toBase64() -> String {
        return Data(self.utf8).base64EncodedString()
    }
    
    func fromBase64() -> String? {
//        guard let data = Data(base64Encoded: self) else { return nil }
//        return String(data: data, encoding: .utf8)
        
        guard let data = Data(base64Encoded: self, options: Data.Base64DecodingOptions(rawValue: 0)) else {
            return nil
        }
        
        return String(data: data as Data, encoding: String.Encoding.utf8)
        
    }
}

extension String {
    public static func randomString(length: Int, includeNumber: Bool) -> String {
        let letters: String
        if includeNumber {
            letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        } else {
            letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        }
        return String((0..<length).map{ _ in letters.randomElement()! })
    }
    
    public static func randomLenString(max: Int, includeNumber: Bool) -> String {
        let len = Int.random(in: 0..<max)
        return String.randomString(length: len, includeNumber: includeNumber)
    }
}
