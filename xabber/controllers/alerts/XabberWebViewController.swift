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
import WebKit

class XabberWebViewController: UIViewController {
    
    public final var url: URL? = nil
    
    internal let webView: WKWebView = {
        let view = WKWebView()
                
        return view
    }()
    
    public final func configure(url: URL?, title: String) {
        guard let url = url else {
            fatalError("URL can`t be empty")
        }
        self.url = url
        self.title = title
    }
    
    private final func setup() {
        setupSubviews()
    }
    
    private final func setupNavbar() {
        let cancelButton = UIBarButtonItem(
            title: "Cancel".localizeString(id: "cancel", arguments: []),
            style: .done,
            target: self,
            action: #selector(self.dismissScreen)
        )
        self.navigationItem.setLeftBarButton(cancelButton, animated: true)
    }
    
    private final func setupSubviews() {
        view.addSubview(webView)
        webView.fillSuperview()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setup()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let url = self.url else { return }
        webView.load(URLRequest(url: url))
        setupNavbar()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        webView.stopLoading()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    @objc
    private func dismissScreen() {
        self.dismiss(animated: true, completion: nil)
    }
    
}
