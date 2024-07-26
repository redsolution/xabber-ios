//
//  XabberActivityViewController+UITableViewDelegate.swift
//  xabber
//
//  Created by Admin on 19.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension XabberActivityViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 84
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        item.isSelected = true
        
        let cell = tableView.cellForRow(at: indexPath)
        cell?.accessoryType = .checkmark
        
        button.isEnabled = true
    }
    
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        item.isSelected = false
        
        let cell = tableView.cellForRow(at: indexPath)
        cell?.accessoryType = .none
        
        if tableView.indexPathsForSelectedRows == nil {
            button.isEnabled = false
        }
    }
}
