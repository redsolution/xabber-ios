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

extension TimeInterval {
    
    var minuteFormatedString: String {
        get {
            let formatter = DateFormatter()
            formatter.dateFormat = "m:ss"
            let date = Date(timeIntervalSince1970: self)
            return formatter.string(from: date)
        }
    }
    
    var prettyMinuteFormatedString: String {
        get {
            let formatter = DateFormatter()
            let today = Date()
            let date = Date(timeIntervalSince1970: today.timeIntervalSince1970 - self)
            let seconds = NSCalendar.current.dateComponents([.second], from: date, to: today)
            if (NSCalendar.current.dateComponents([.second], from: date, to: today).second ?? 0) <= 61 {
                formatter.dateFormat = "s \'sec\'"
            } else {
                formatter.dateFormat = "m \'min\'"
            }
            return formatter.string(from: date)
        }
    }
}
