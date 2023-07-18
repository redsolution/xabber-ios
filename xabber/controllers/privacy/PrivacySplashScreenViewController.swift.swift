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

class PrivacySplashScreenViewController: UIViewController {
    let logoView: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 128))
        
        view.image = UIImage(named: "onboarding_logo_128pt")
        
        return view
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        logoView.center = view.center
        view.addSubview(logoView)
        view.backgroundColor = UIColor(red: 43/255, green: 48/255, blue: 63/255, alpha: 1.0)
    }
}
