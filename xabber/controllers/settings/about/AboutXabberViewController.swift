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
import TOInsetGroupedTableView

class AboutXabberViewController: BaseViewController {
    
    class Datasource {
        var title: String
        var text: String
        
        init(_ title: String, for text: String) {
            self.title = title
            self.text = text
        }
    }
    
    internal var datasource: [Datasource] = []
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(Cell.self, forCellReuseIdentifier: Cell.cellName)
        
        return view
    }()
    
    internal func activateConstraints() {
        
    }
    
    internal func configure() {
        datasource = [
            Datasource("", for: "Xabber is an <u><b>open</b> <i>source</i></u> XMPP messenger for Android, iOS and Web platforms. It is build around open standards, interoperability, design and great user experience. Versions of Xabber for every platform are built to provide a continuous chat experience between them.\nYou will find more information on our official website https://xabber.com".localizeString(id: "about_xabber", arguments: [])),
            Datasource("XMPP protocol".localizeString(id: "web_client__screen_about__block_1__header", arguments: []), for: "Extensible Messaging and Presence Protocol (XMPP) is a communications protocol for message-oriented middleware based on XML (Extensible Markup Language). It enables the near-real-time exchange of structured yet extensible data between any two or more network entities. The protocol was originally named Jabber, and was developed by the Jabber open-source community in 1999 for near real-time instant messaging (IM),presence information, and contact list maintenance.".localizeString(id: "about_xmpp_protocol", arguments: [])),
            Datasource("XMPP Extension Protocols".localizeString(id: "web_client__screen_about__block_2__header", arguments: []), for: "XMPP is highly extensible, via extensions known as XEPs (XMPP Extension Protocol). Xabber supports a number of popular XEPs that are essential to providing great chat experience for our users.".localizeString(id: "about_extension_protocols", arguments: [])),
            Datasource("Developers".localizeString(id: "web_client__screen_about__block_3__header", arguments: []), for: "Xabber for Android was originally developed by Redsolution — an international software and services company currently based in Estonia. Since then, a number of individuals joined Xabber as developers, testers and translators.\nOur goal is to create a stable, reliable, interoperable and user friendly ecosystem for instant messaging that does not rely on proprietary services and data silos. We welcome anyone who believes in open standards and free information interchange to take part in moving Xabber forward.\nFollow us on Twitter and Github.".localizeString(id: "xabber_developers", arguments: [])),
            Datasource("Translators".localizeString(id: "web_client__screen_about__block_4__header", arguments: []), for: "Xabber is available in multiple languages thanks to many fine people from all over the world. We have created a special page on our website to acknowledge their efforts.\nYou may join their ranks and help us improve translation quality by contributing your translations to Xabber project".localizeString(id: "xabber_translators", arguments: []))
        ]
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        title = "About".localizeString(id: "about", arguments: [])
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 360
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.configure()
        self.activateConstraints()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
