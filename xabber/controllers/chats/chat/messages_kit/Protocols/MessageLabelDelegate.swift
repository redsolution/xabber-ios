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

/// A protocol used to handle tap events on detected text.
public protocol MessageLabelDelegate: AnyObject {

    /// Triggered when a tap occurs on a detected address.
    ///
    /// - Parameters:
    ///   - addressComponents: The components of the selected address.
    func didSelectAddress(_ addressComponents: [String: String])

    /// Triggered when a tap occurs on a detected date.
    ///
    /// - Parameters:
    ///   - date: The selected date.
    func didSelectDate(_ date: Date)

    /// Triggered when a tap occurs on a detected phone number.
    ///
    /// - Parameters:
    ///   - phoneNumber: The selected phone number.
    func didSelectPhoneNumber(_ phoneNumber: String)

    /// Triggered when a tap occurs on a detected URL.
    ///
    /// - Parameters:
    ///   - url: The selected URL.
    func didSelectURL(_ url: URL)

    /// Triggered when a tap occurs on detected transit information.
    ///
    /// - Parameters:
    ///   - transitInformation: The selected transit information.
    func didSelectTransitInformation(_ transitInformation: [String: String])

}

public extension MessageLabelDelegate {

    func didSelectAddress(_ addressComponents: [String: String]) {}

    func didSelectDate(_ date: Date) {}

    func didSelectPhoneNumber(_ phoneNumber: String) {}

    func didSelectURL(_ url: URL) {}
    
    func didSelectTransitInformation(_ transitInformation: [String: String]) {}

}
