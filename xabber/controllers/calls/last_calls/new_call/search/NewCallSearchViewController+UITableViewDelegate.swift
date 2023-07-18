//
//  NewCallSearchViewController+UITableViewDelegate.swift
//  xabber
//
//  Created by Игорь Болдин on 05.02.2021.
//  Copyright © 2021 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension NewCallSearchViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 66
    }
    
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        self.tableView.deselectRow(at: indexPath, animated: true)
        self.delegate?.startCall(owner: item.owner, jid: item.jid)
//        self.dismiss(animated: true, completion: nil)
    }
}
