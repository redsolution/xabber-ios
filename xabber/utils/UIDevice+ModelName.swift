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

import SystemConfiguration
import UIKit

public extension UIDevice {
    
    static let modelIdentifier: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }()
    
    static let modelName: String = {

        func mapToDevice(identifier: String) -> String {
            #if os(iOS)
            switch identifier {
            case "iPhone1,1":   return "iPhone"
            case "iPhone1,2":   return "iPhone 3G"
            case "iPhone2,1":   return "iPhone 3GS"
            case "iPhone3,1":   return "iPhone 4"
            case "iPhone3,2":   return "iPhone 4 GSM Rev A"
            case "iPhone3,3":   return "iPhone 4 CDMA"
            case "iPhone4,1":   return "iPhone 4S"
            case "iPhone5,1":   return "iPhone 5 (GSM)"
            case "iPhone5,2":   return "iPhone 5 (GSM+CDMA)"
            case "iPhone5,3":   return "iPhone 5C (GSM)"
            case "iPhone5,4":   return "iPhone 5C (Global)"
            case "iPhone6,1":   return "iPhone 5S (GSM)"
            case "iPhone6,2":   return "iPhone 5S (Global)"
            case "iPhone7,1":   return "iPhone 6 Plus"
            case "iPhone7,2":   return "iPhone 6"
            case "iPhone8,1":   return "iPhone 6s"
            case "iPhone8,2":   return "iPhone 6s Plus"
            case "iPhone8,4":   return "iPhone SE (GSM)"
            case "iPhone9,1":   return "iPhone 7"
            case "iPhone9,2":   return "iPhone 7 Plus"
            case "iPhone9,3":   return "iPhone 7"
            case "iPhone9,4":   return "iPhone 7 Plus"
            case "iPhone10,1":  return "iPhone 8"
            case "iPhone10,2":  return "iPhone 8 Plus"
            case "iPhone10,3":  return "iPhone X Global"
            case "iPhone10,4":  return "iPhone 8"
            case "iPhone10,5":  return "iPhone 8 Plus"
            case "iPhone10,6":  return "iPhone X GSM"
            case "iPhone11,2":  return "iPhone XS"
            case "iPhone11,4":  return "iPhone XS Max"
            case "iPhone11,6":  return "iPhone XS Max Global"
            case "iPhone11,8":  return "iPhone XR"
            case "iPhone12,1":  return "iPhone 11"
            case "iPhone12,3":  return "iPhone 11 Pro"
            case "iPhone12,5":  return "iPhone 11 Pro Max"
            case "iPhone12,8":  return "iPhone SE 2nd Gen"
            case "iPhone13,1":  return "iPhone 12 Mini"
            case "iPhone13,2":  return "iPhone 12"
            case "iPhone13,3":  return "iPhone 12 Pro"
            case "iPhone13,4":  return "iPhone 12 Pro Max"
            case "iPhone14,2":  return "iPhone 13 Pro"
            case "iPhone14,3":  return "iPhone 13 Pro Max"
            case "iPhone14,4":  return "iPhone 13 Mini"
            case "iPhone14,5":  return "iPhone 13"
            case "iPhone14,6":  return "iPhone SE 3rd Gen"
            case "iPhone14,7":  return "iPhone 14"
            case "iPhone14,8":  return "iPhone 14 Plus"
            case "iPhone15,2":  return "iPhone 14 Pro"
            case "iPhone15,3":  return "iPhone 14 Pro Max"
            
            case "iPod1,1":     return "1st Gen iPod"
            case "iPod2,1":     return "2nd Gen iPod"
            case "iPod3,1":     return "3rd Gen iPod"
            case "iPod4,1":     return "4th Gen iPod"
            case "iPod5,1":     return "5th Gen iPod"
            case "iPod7,1":     return "6th Gen iPod"
            case "iPod9,1":     return "7th Gen iPod"
                
            case "iPad1,1":     return "iPad"
            case "iPad1,2":     return "iPad 3G"
            case "iPad2,1":     return "2nd Gen iPad"
            case "iPad2,2":     return "2nd Gen iPad GSM"
            case "iPad2,3":     return "2nd Gen iPad CDMA"
            case "iPad2,4":     return "2nd Gen iPad New Revision"
            case "iPad3,1":     return "3rd Gen iPad"
            case "iPad3,2":     return "3rd Gen iPad CDMA"
            case "iPad3,3":     return "3rd Gen iPad GSM"
            case "iPad2,5":     return "iPad mini"
            case "iPad2,6":     return "iPad mini GSM+LTE"
            case "iPad2,7":     return "iPad mini CDMA+LTE"
            case "iPad3,4":     return "4th Gen iPad"
            case "iPad3,5":     return "4th Gen iPad GSM+LTE"
            case "iPad3,6":     return "4th Gen iPad CDMA+LTE"
            case "iPad4,1":     return "iPad Air (WiFi)"
            case "iPad4,2":     return "iPad Air (GSM+CDMA)"
            case "iPad4,3":     return "1st Gen iPad Air (China)"
            case "iPad4,4":     return "iPad mini Retina (WiFi)"
            case "iPad4,5":     return "iPad mini Retina (GSM+CDMA)"
            case "iPad4,6":     return "iPad mini Retina (China)"
            case "iPad4,7":     return "iPad mini 3 (WiFi)"
            case "iPad4,8":     return "iPad mini 3 (GSM+CDMA)"
            case "iPad4,9":     return "iPad Mini 3 (China)"
            case "iPad5,1":     return "iPad mini 4 (WiFi)"
            case "iPad5,2":     return "4th Gen iPad mini (WiFi+Cellular)"
            case "iPad5,3":     return "iPad Air 2 (WiFi)"
            case "iPad5,4":     return "iPad Air 2 (Cellular)"
            case "iPad6,3":     return "iPad Pro (9.7 inch, WiFi)"
            case "iPad6,4":     return "iPad Pro (9.7 inch, WiFi+LTE)"
            case "iPad6,7":     return "iPad Pro (12.9 inch, WiFi)"
            case "iPad6,8":     return "iPad Pro (12.9 inch, WiFi+LTE)"
            case "iPad6,11":    return "iPad (2017)"
            case "iPad6,12":    return "iPad (2017)"
            case "iPad7,1":     return "iPad Pro 2nd Gen (WiFi)"
            case "iPad7,2":     return "iPad Pro 2nd Gen (WiFi+Cellular)"
            case "iPad7,3":     return "iPad Pro 10.5-inch 2nd Gen"
            case "iPad7,4":     return "iPad Pro 10.5-inch 2nd Gen"
            case "iPad7,5":     return "iPad 6th Gen (WiFi)"
            case "iPad7,6":     return "iPad 6th Gen (WiFi+Cellular)"
            case "iPad7,11":    return "iPad 7th Gen 10.2-inch (WiFi)"
            case "iPad7,12":    return "iPad 7th Gen 10.2-inch (WiFi+Cellular)"
            case "iPad8,1":     return "iPad Pro 11 inch 3rd Gen (WiFi)"
            case "iPad8,2":     return "iPad Pro 11 inch 3rd Gen (1TB, WiFi)"
            case "iPad8,3":     return "iPad Pro 11 inch 3rd Gen (WiFi+Cellular)"
            case "iPad8,4":     return "iPad Pro 11 inch 3rd Gen (1TB, WiFi+Cellular)"
            case "iPad8,5":     return "iPad Pro 12.9 inch 3rd Gen (WiFi)"
            case "iPad8,6":     return "iPad Pro 12.9 inch 3rd Gen (1TB, WiFi)"
            case "iPad8,7":     return "iPad Pro 12.9 inch 3rd Gen (WiFi+Cellular)"
            case "iPad8,8":     return "iPad Pro 12.9 inch 3rd Gen (1TB, WiFi+Cellular)"
            case "iPad8,9":     return "iPad Pro 11 inch 4th Gen (WiFi)"
            case "iPad8,10":    return "iPad Pro 11 inch 4th Gen (WiFi+Cellular)"
            case "iPad8,11":    return "iPad Pro 12.9 inch 4th Gen (WiFi)"
            case "iPad8,12":    return "iPad Pro 12.9 inch 4th Gen (WiFi+Cellular)"
            case "iPad11,1":    return "iPad mini 5th Gen (WiFi)"
            case "iPad11,2":    return "iPad mini 5th Gen"
            case "iPad11,3":    return "iPad Air 3rd Gen (WiFi)"
            case "iPad11,4":    return "iPad Air 3rd Gen"
            case "iPad11,6":    return "iPad 8th Gen (WiFi)"
            case "iPad11,7":    return "iPad 8th Gen (WiFi+Cellular)"
            case "iPad12,1":    return "iPad 9th Gen (WiFi)"
            case "iPad12,2":    return "iPad 9th Gen (WiFi+Cellular)"
            case "iPad14,1":    return "iPad mini 6th Gen (WiFi)"
            case "iPad14,2":    return "iPad mini 6th Gen (WiFi+Cellular)"
            case "iPad13,1":    return "iPad Air 4th Gen (WiFi)"
            case "iPad13,2":    return "iPad Air 4th Gen (WiFi+Cellular)"
            case "iPad13,4":    return "iPad Pro 11 inch 5th Gen"
            case "iPad13,5":    return "iPad Pro 11 inch 5th Gen"
            case "iPad13,6":    return "iPad Pro 11 inch 5th Gen"
            case "iPad13,7":    return "iPad Pro 11 inch 5th Gen"
            case "iPad13,8":    return "iPad Pro 12.9 inch 5th Gen"
            case "iPad13,9":    return "iPad Pro 12.9 inch 5th Gen"
            case "iPad13,10":   return "iPad Pro 12.9 inch 5th Gen"
            case "iPad13,11":   return "iPad Pro 12.9 inch 5th Gen"
            case "iPad13,16":   return "iPad Air 5th Gen (WiFi)"
            case "iPad13,17":   return "iPad Air 5th Gen (WiFi+Cellular)"
                
            case "AppleTV5,3":                              return "Apple TV"
            case "AppleTV6,2":                              return "Apple TV 4K"
            case "AudioAccessory1,1":                       return "HomePod"
            case "i386", "x86_64":                          return "Simulator \(mapToDevice(identifier: ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iOS"))"
            default:                                        return identifier
            }
            #elseif os(tvOS)
            switch identifier {
            case "AppleTV5,3": return "Apple TV 4"
            case "AppleTV6,2": return "Apple TV 4K"
            case "i386", "x86_64": return "Simulator \(mapToDevice(identifier: ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "tvOS"))"
            default: return identifier
            }
            #endif
        }
        
        return mapToDevice(identifier: modelIdentifier)
    }()
    
    static let isOldIPhonesFamily: Bool = {

        func mapToDevice(identifier: String) -> Bool {
            if ["iPhone3,1", "iPhone3,2", "iPhone3,3",
                "iPhone4,1",
                "iPhone5,1", "iPhone5,2", "iPhone5,3", "iPhone5,4",
                "iPhone6,1", "iPhone6,2",
                "iPhone7,1", "iPhone7,2",
                "iPhone8,1", "iPhone8,2", "iPhone8,4",
                "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4",
                "iPhone10,1", "iPhone10,2", "iPhone10,4", "iPhone10,5",
                "iPhone12,8",
                "iPhone14,6"].contains(identifier) {
                return true
            } else if ["i386", "x86_64"].contains(identifier) {
                return mapToDevice(identifier: ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iOS")
            }
            return false
        }
        return mapToDevice(identifier: modelIdentifier)
    }()
    
    static let isIPhoneXFamily: Bool = {
        
        func mapToDevice(identifier: String) -> Bool {
            if ["iPhone10,3", "iPhone10,6",
                "iPhone11,2", "iPhone11,4", "iPhone11,6", "iPhone11,8",
                "iPhone12,1", "iPhone12,3", "iPhone12,5",
                "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4",
                "iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5", "iPhone14,7", "iPhone14,8",
                "iPhone15,2", "iPhone15,3"].contains(identifier) {
                return true
            } else if ["i386", "x86_64"].contains(identifier) {
                return mapToDevice(identifier: ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iOS")
            }
            return false
        }
        return mapToDevice(identifier: modelIdentifier)
    }()
    
    static let isIPadHomeButtonFamily: Bool = {

        func mapToDevice(identifier: String) -> Bool {
            if ["iPad2,5", "iPad2,6", "iPad2,7",
                "iPad3,1", "iPad3,2", "iPad3,3", "iPad3,4", "iPad3,5", "iPad3,6",
                "iPad4,1", "iPad4,2", "iPad4,4", "iPad4,5", "iPad4,7", "iPad4,8",
                "iPad5,1", "iPad5,2", "iPad5,3", "iPad5,4",
                "iPad6,3", "iPad6,4", "iPad6,7", "iPad6,8", "iPad6,11", "iPad6,12",
                "iPad7,1", "iPad7,2", "iPad7,3", "iPad7,4", "iPad7,5", "iPad7,6", "iPad7,11", "iPad7,12",
                "iPad11,1", "iPad11,2", "iPad11,3", "iPad11,4", "iPad11,6", "iPad11,7", "iPad12,1", "iPad12,2"].contains(identifier) {
                return true
            } else if ["i386", "x86_64"].contains(identifier) {
                return mapToDevice(identifier: ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iOS")
            }
            return false
        }
        return mapToDevice(identifier: modelIdentifier)
    }()
    
    static let isIPadWithoutHomeButtonFamily: Bool = {
        
        func mapToDevice(identifier: String) -> Bool {
            if ["iPad8,1", "iPad8,2", "iPad8,3","iPad8,4", "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8", "iPad8,9", "iPad8,10", "iPad8,11", "iPad8,12",
                "iPad13,1", "iPad13,2", "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7", "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11", "iPad13,16", "iPad13,17",
                "iPad14,1", "iPad14,2"].contains(identifier) {
                return true
            } else if ["i386", "x86_64"].contains(identifier) {
                return mapToDevice(identifier: ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iOS")
            }
            return false
        }
        return mapToDevice(identifier: modelIdentifier)
    }()
    
    static let needBottomOffset: Bool = {
       return (isIPhoneXFamily || isIPadWithoutHomeButtonFamily)
    }()
    
    static let needTopOffset: Bool = {
       return isIPhoneXFamily
    }()
}
