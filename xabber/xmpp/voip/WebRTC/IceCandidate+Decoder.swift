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

struct IceCandidateDecoder {
    
    let sdp: String
    
    var decode: [String : String] {
        get {
            guard let paramsArray = self.sdp.split(separator: ":").last?.split(separator: " ") else {
                return ["":""]
            }
            if paramsArray.count < 6 { return ["":""] }
            if paramsArray.count % 2 != 0 { return ["":""] }
            
            var out: [String : String] = [
                "foundation":   String(paramsArray[0]),
                "component": String(paramsArray[1]),
                "protocol":    String(paramsArray[2]),
                "priority":     String(paramsArray[3]),
                "ip":       String(paramsArray[4]),
                "port":       String(paramsArray[5])
            ]
            let miscellaneous = paramsArray.suffix(from: out.count)
            
            for i in stride(from: out.count, to: paramsArray.count - 1, by: 2) {
                out[String(miscellaneous[i])] = String(miscellaneous[i + 1])
            }
            
            print(sdp)
            print(out.map({ return [$0.key, ]}))
            
            return out
        }
    }
    
    static func encode(_ params: [String : String]) -> String? {
    
//        let base: [String] = [
//            "foundation",
//            "component",
//            "protocol",
//            "priority",
//            "ip",
//            "port",
//        ]
        
        guard let foundation = params["foundation"] else { return nil }
        guard let component = params["component"] else { return nil }
        guard let protocolType = params["protocol"] else { return nil }
        guard let priority = params["priority"] else { return nil }
        guard let ip = params["ip"] else { return nil }
        guard let port = params["port"] else { return nil }
        
        var misc: [String] = []
        
        for item in params {
            misc.append([item.key, item.value].joined(separator: " "))
        }
        
        return ["candidate:\(foundation)",
                    component,
                    protocolType,
                    priority,
                    ip,
                    port,
                    misc.joined(separator: " ")
//                    params.compactMap({ (item) -> String? in
//                        if !base.contains(item.key) {
//                            return [item.key, item.value].joined(separator: " ")
//                        }
//                        return nil
//                    }).joined(separator: " ")
                ]
                .joined(separator: " ")
    }
    
}
