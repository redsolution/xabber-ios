//
//  NewCallSearchViewController+UISearchResultsUpdating.swift
//  xabber
//
//  Created by Игорь Болдин on 05.02.2021.
//  Copyright © 2021 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension NewCallSearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        updateSearchResults(with: searchController.searchBar.text ?? "")
    }
}

