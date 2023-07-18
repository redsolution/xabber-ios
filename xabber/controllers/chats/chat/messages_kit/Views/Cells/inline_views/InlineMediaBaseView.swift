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

class InlineMediaBaseView: UIView {
    struct GridItem {
        let cell: CGRect
        let url: URL?
    }
    
    open var datasource: MessagesDataSource? = nil
    
    var contentViews: [UIView] = []
    
    var grid: [GridItem] = []
    var messageId: String? = nil
    
    internal func prepareGrid(_ references: [MessageReferenceStorageItem.Model]) -> [CGRect] {
        return []
    }
    
    func configure(_ references: [MessageReferenceStorageItem.Model], messageId: String?, indexPath: IndexPath) {
        self.grid = []
        self.messageId = nil
    }
    
    func handleTouch(at point: CGPoint, callback: ((String?, Int, Bool) -> Void)?) {
        
    }
}
