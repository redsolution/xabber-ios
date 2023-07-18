//
//  OutcomeMessageTableViewCell.swift
//  xabber_test_xmpp
//
//  Created by Igor Boldin on 31/01/2018.
//  Copyright © 2018 Igor Boldin. All rights reserved.
//

import UIKit

class OutcomeMessageTableViewCell: UITableViewCell {

    @IBOutlet weak var message: UILabel!
    @IBOutlet weak var avatar: UIImageView!
    
    
    override func awakeFromNib() {
        super.awakeFromNib()
        self.avatar.layer.borderWidth = 1
        self.avatar.layer.masksToBounds = false
        self.avatar.layer.borderColor = UIColor.black.cgColor
        self.avatar.layer.cornerRadius = self.avatar.frame.height/2
        self.avatar.clipsToBounds = true
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }

}
