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
//
//import Foundation
//
//protocol UploadManagerProtocol {
//    var node: String? { get set }
//    func isAvailable() -> Bool
//}
//
//protocol UploadManagerExtendedProtocol: UploadManagerProtocol {
//    func enable()
//    func getFileData(message primary: String, successCallback: @escaping (() -> Void), failCallback: @escaping (() -> Void))
//    func getQuotaInfo(_ callback: (() -> Void)?)
//    func deleteMediaFromServer(fileID: Int)
//    func deleteAvatarFromServer(fileID: Int)
//    func getFilesOfType(type: MimeIconTypes, page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void)
//    func getAvatars(page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void)
//    func getFilesToDeleteByPercent(percent: Int, page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void)
//    func deleteMediaForSelectedPeriod(earlierThanDate: String, successCallback: @escaping (() -> Void))
//    func deleteGallery(jid: String)
//}
