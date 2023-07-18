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

enum PushReceiveError: Error {
    case noData
    case invalidPayload
    
}

enum PushRegisterError: Error {
    case success
    case notRegisterPush
    case invalidData
    case lowData
    case commonError
}

enum PushPipelineError: Error {
    case invalidPushReceivedFlag
    case alreadyConnect
    case pushNotInitiated
    case pushAlreadyExist
    case pushEnd
    case success
}

enum XMPPControllerError: Error {
    case wrongUserJID
}

enum AddXMPPAccountError: Error {
    case nilField
    case invalidJid
    case invalidPassword
    case duplicateJid
}

enum AccountError: Error {
    case commonError
}

enum RosterError: Error {
    case commonError
}

enum DDXMLElementArrayError: Error {
    case unsafeRemove
}
