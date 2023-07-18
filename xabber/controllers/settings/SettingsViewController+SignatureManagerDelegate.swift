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


extension SettingsViewController: SignatureManagerDelegate {
    func didConnectionStop(with error: Error?) {
        
    }
    
    func didGenerateDigitalSignature(with error: Error?) {
        
    }
    
    func retrieveCertificate(with error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.view.makeToast("Internal error")
            }
        } else {
            DispatchQueue.main.async {
                let vc = YubikeySetupViewController()
                vc.isFromOnboarding = false
                vc.owner = AccountManager.shared.users.first?.jid ?? ""
                self.navigationController?.pushViewController(vc, animated: true)
            }
        }
    }
    
    func retrieveYubikeyInfo(with error: Error?) {
        
    }
    
    
}

