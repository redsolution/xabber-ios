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

extension String {

    
    func localizeString(id: String, arguments: [String]) -> String {
//        guard let selectedLang = TranslationsManager.shared.currentLang else {
//            let string = String(format: NSLocalizedString(id, comment: ""), arguments: arguments)
//            if string == id {
//                return self
//            } else {
//                return string
//            }
//        }
        guard let selectedLang = TranslationsManager.shared.currentLang ?? NSLocale.current.languageCode else {
            return self
        }
        
        let lanCode = TranslationsManager.shared.prepareLanCode(language: selectedLang)
        let path = Bundle.main.path(forResource: lanCode, ofType: "lproj")
        guard let bundle = Bundle(path: path!) else {
            return self
        }
        
        return String(format: NSLocalizedString(id, tableName: nil, bundle: bundle, value: self, comment: ""),
                      arguments: arguments)
    }
    
    func localizeHTML(id: String, arguments: [String]) -> NSAttributedString {
        guard let selectedLang = TranslationsManager.shared.currentLang ?? NSLocale.current.languageCode else {
            return NSAttributedString(string: self)
        }
        
        let lanCode = TranslationsManager.shared.prepareLanCode(language: selectedLang)
        let path = Bundle.main.path(forResource: lanCode, ofType: "lproj")
        guard let bundle = Bundle(path: path!) else {
            return NSAttributedString(string: self)
        }
        
        return NSAttributedString(string: String(format: NSLocalizedString(id, tableName: nil, bundle: bundle, value: self, comment: ""),
                      arguments: arguments))
        
        
//        if let attributedString = try? NSAttributedString(data: data,
//                                                          options: [.documentType: NSAttributedString.DocumentType.html],
//                                                          documentAttributes: nil) {
//            return attributedString
//        } else {
//            return NSAttributedString()
//        }
    }
    

    
    var xmppDate: Date? {
        get {
            var date: Date? = nil
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            date = dateFormatter.date(from: self)
            if date == nil {
                dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
                date = dateFormatter.date(from: self)
            }
            if date == nil {
                dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                date = dateFormatter.date(from: self)
            }
            return date
        }
    }
    
    public var booleanValue: Bool {
        get {
            return["true", "True", "TRUE", "1"].contains(self)
        }
    }
    
    public static func fromBoolean(_ value: Bool, numeric: Bool = false) -> String {
        if numeric {
            if value {
                return "1"
            } else {
                return "0"
            }
        } else {
            if value {
                return "true"
            } else {
                return "false"
            }
        }
    }
    
}

extension Array where Element: StringProtocol {
    mutating func onceAppend(_ newElement: Element) {
        if !self.contains(newElement) {
            self.append(newElement)
        }
    }
}

extension String {
    private static let slugSafeCharacters = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-")

    public func slugify() -> String? {
        if let latin = self.applyingTransform(StringTransform("Any-Latin; Latin-ASCII; Lower;"), reverse: false) {
            let urlComponents = latin.components(separatedBy: String.slugSafeCharacters.inverted)
            let result = urlComponents.filter { $0 != "" }.joined(separator: "-")

            if result.count > 0 {
                return result
            }
        }

        return nil
    }
}




extension String {
    func split(by length: Int) -> [String] {
        var startIndex = self.startIndex
        var results = [Substring]()

        while startIndex < self.endIndex {
            let endIndex = self.index(startIndex, offsetBy: length, limitedBy: self.endIndex) ?? self.endIndex
            results.append(self[startIndex..<endIndex])
            startIndex = endIndex
        }

        return results.map { String($0) }
    }
}

import UIKit

extension String
{
    func image(fontSize:CGFloat = 40, bgColor:UIColor = UIColor.clear, imageSize:CGSize? = nil) -> UIImage? {
        let font = UIFont.systemFont(ofSize: fontSize)
        let attributes = [NSAttributedString.Key.font: font]
        let imageSize = imageSize ?? self.size(withAttributes: attributes)
        UIGraphicsBeginImageContextWithOptions(imageSize, false, 0)
        bgColor.set()
        let rect = CGRect(origin: .zero, size: imageSize)
        UIRectFill(rect)
        self.draw(in: rect, withAttributes: [.font: font])
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image
    }
}

extension String {
    static func membersAndContactsString(members: Int, contacts: Int) -> String {
        var memberStr: String = ""
        var contactStr: String = ""
        if members == 0 {
            return ""
        }
        if members == 1 {
            memberStr = "1 member"
        }
        if members > 1 {
            memberStr = "\(members) members"
        }
        if contacts == 0 {
            contactStr = ""
        }
        if contacts == 1 {
            contactStr = " · 1 contact"
        }
        if contacts > 1 {
            contactStr = " · \(contacts) contacts"
        }
        return memberStr + contactStr
    }
}
