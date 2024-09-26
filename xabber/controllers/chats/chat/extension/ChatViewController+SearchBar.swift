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
import MaterialComponents.MDCPalettes
import CocoaLumberjack

extension ChatViewController {
    class SearchBar: UITabBar {
        
        public enum SearchResultDirection: String {
            case up = "SearchBarUpResultsButton"
            case down = "SearchBarDownResultsButton"
        }
        
        private let upButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 40))
            
            button.restorationIdentifier = SearchResultDirection.up.rawValue
            button.setImage(imageLiteral("chevron-up")?.withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.imageEdgeInsets = UIEdgeInsets(square: 8)
            
            return button
        }()
        
        private let downButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 40))
            
            button.restorationIdentifier = SearchResultDirection.down.rawValue
            button.setImage(imageLiteral("chevron-down")?.withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.imageEdgeInsets = UIEdgeInsets(square: 8)
            
            return button
        }()
        
        open var callback: ((SearchResultDirection) -> Void)? = nil
        
        private final func setup() {
            upButton.frame = CGRect(
                x: 16,
                y: 2,
                width: 40,
                height: 40
            )
            
            downButton.frame = CGRect(
                x: 64,
                y: 2,
                width: 40,
                height: 40
            )
            addSubview(upButton)
            addSubview(downButton)
            layoutSubviews()
            isUserInteractionEnabled = false
            upButton.addTarget(self, action: #selector(onButtonTouchUp), for: .touchUpInside)
            downButton.addTarget(self, action: #selector(onButtonTouchUp), for: .touchUpInside)
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        @objc
        private final func onButtonTouchUp(_ sender: UIButton) {
            guard let identifier = sender.restorationIdentifier,
                  let direction = SearchResultDirection(rawValue: identifier) else {
                return
            }
            self.callback?(direction)
        }
    }
    
    
    internal func onSearchPanelSeekUp() {
        guard let currentIndex = self.searchResultsIds.firstIndex(of: self.selectedSearchResultId ?? "") else {
            return
        }
        if self.searchResultsIds.count == 1 {
            return
        }
        var newIndex = currentIndex + 1
        if newIndex >= self.searchResultsIds.count {
            newIndex = 0
        }
        print(self.selectedSearchResultId!)
        self.selectedSearchResultId = self.searchResultsIds[newIndex]
        print(self.selectedSearchResultId!)
        self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchResultsIds.count)
        self.scrollToMessage(primary: self.selectedSearchResultId ?? "")
        print(#function)
    }
    
    internal func onSearchPanelSeekDown() {
        guard let currentIndex = self.searchResultsIds.firstIndex(of: self.selectedSearchResultId ?? "") else {
            return
        }
        if self.searchResultsIds.count == 1 {
            return
        }
        var newIndex = currentIndex - 1
        if newIndex < 0 {
            newIndex = self.searchResultsIds.count - 1
        }
        self.selectedSearchResultId = self.searchResultsIds[newIndex]
        self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchResultsIds.count)
        self.scrollToMessage(primary: self.selectedSearchResultId ?? "")
        print(#function)
    }
    
    internal func onSearchPanelChangeChatViewState() {
        let vc = SearchChatListViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        vc.conversationType = self.conversationType
        vc.searchTextObserver.accept(self.searchBar.text)
        vc.searchBar.text = self.searchBar.text
        self.navigationController?.pushViewController(vc, animated: true)
    }
}
