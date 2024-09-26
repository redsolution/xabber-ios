//
//  ChatViewController+ChangeChatStateProtocol.swift
//  xabber
//
//  Created by Игорь Болдин on 09.09.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation

extension ChatViewController: ChangeChatStateProtocol {
    func openSearchBar() {
//        self.inSearchMode.accept(true)
        let vc = SearchChatListViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        vc.conversationType = self.conversationType
        self.navigationController?.pushViewController(vc, animated: true)
//        showStacked(vc, in: self)
    }
}
