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
//import RealmSwift
//import CocoaLumberjack
//
////protocol QuotaCellDelegate {
////    func getQuotaInfo(requiresDataFromServer: Bool, callback: @escaping ((Int, Int, Int, Int, Int, String, String) -> Void))
////}
//
//extension _AccountInfoViewController: QuotaCellDelegate {
//    func getQuotaInfo(requiresDataFromServer: Bool = false, callback: @escaping ((Int, Int, Int, Int, Int, String, String) -> Void)) {
//        func extractStatsFromRealm(callback: @escaping ((Int, Int, Int, Int, Int, String, String) -> Void)) {
//            do {
//                let realm = try Realm()
//                guard let quotaItem = realm.object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: jid) else { return }
//                
//                let rawImages = quotaItem.rawImages
//                let rawVideos = quotaItem.rawVideos
//                let rawFiles = quotaItem.rawFiles
//                let rawVoices = quotaItem.rawVoices
//                let quotaRaw = quotaItem.rawQuota
//                let quota = quotaItem.quota
//                let used = quotaItem.used
//                
//                callback(rawImages, rawVideos, rawFiles, rawVoices, quotaRaw, quota, used)
//            } catch {
//                DDLogDebug("QuotaInfoCell: \(#function). \(error.localizedDescription)")
//            }
//        }
//        
//        if requiresDataFromServer == true {
//            if let account = AccountManager.shared.find(for: jid),
//               let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol {
//                uploader.getQuotaInfo {
//                    extractStatsFromRealm() { rawImages, rawVideos, rawFiles, rawVoices, quotaRaw, quota, used in
//                        callback(rawImages, rawVideos, rawFiles, rawVoices, quotaRaw,quota, used)
//                    }
//                }
//            }
//        } else {
//            extractStatsFromRealm() { rawImages, rawVideos, rawFiles, rawVoices, quotaRaw, quota, used in
//                callback(rawImages, rawVideos, rawFiles, rawVoices, quotaRaw,quota, used)
//            }
//        }
//    }
//}
