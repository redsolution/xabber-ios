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

extension ContactsViewController {
    class CollapsedCell: UITableViewCell {
        static let cellName: String = "CollapsedCell"
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            let firstLine = UIView(frame: CGRect(x: 0, y: 3, width: self.frame.width * 2, height: 0.33))
            firstLine.backgroundColor = UIColor.black.withAlphaComponent(0.27)
            addSubview(firstLine)
            
            let secondLine = UIView(frame: CGRect(x: 0, y: 6.25, width: self.frame.width * 2, height: 0.33))
            secondLine.backgroundColor = UIColor.black.withAlphaComponent(0.27)
            addSubview(secondLine)
            
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)
//            NSLayoutConstraint.activate([
//                firstLine.leftAnchor.constraint(equalTo: leftAnchor, constant: 0),
//                firstLine.rightAnchor.constraint(equalTo: rightAnchor, constant: 0),
//                secondLine.leftAnchor.constraint(equalTo: leftAnchor, constant: 0),
//                secondLine.rightAnchor.constraint(equalTo: rightAnchor, constant: 0),
//            ])
            selectionStyle = .none
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
            
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}
