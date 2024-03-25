//
//  ShowCodeViewController.swift
//  xabber
//
//  Created by Admin on 20.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class ShowCodeViewController: UIViewController {
    var code: String? = nil
    var owner: String? = nil
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Tell to your opponent"
        self.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = code
        label.font = UIFont.systemFont(ofSize: 20)
        self.view.addSubview(label)
        label.centerXAnchor.constraint(equalTo: self.view.centerXAnchor).isActive = true
        label.centerYAnchor.constraint(equalTo: self.view.centerYAnchor).isActive = true
    }
}
