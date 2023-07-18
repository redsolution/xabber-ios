//
//  ChatTableViewController.swift
//  xabber_test_xmpp
//
//  Created by Igor Boldin on 31/01/2018.
//  Copyright © 2018 Igor Boldin. All rights reserved.
//

import UIKit
import XMPPFramework

class ChatTableViewController: UITableViewController {

    var contact: XMPPContact?
    var messages: [XMPPMessageContainer]?
    
    required init?(coder aDecoder: NSCoder) {
    
        super.init(coder: aDecoder)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Uncomment the following line to preserve selection between presentations
        // self.clearsSelectionOnViewWillAppear = false

        // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
        // self.navigationItem.rightBarButtonItem = self.editButtonItem
    
        self.title = contact?.name
        messages = self.contact!.load_messages()
       // self.tabBarController?.tabBar.isHidden = true
        var tab_bar_items = self.tabBarController?.tabBar.items![0] as! UITabBarItem
    }
    override func viewDidAppear(_ animated: Bool) {
        print("appear chat")
        self.contact!.unread = 0
        self.contact!.read_messages()
        xmpp_user1!.xmpp_controller!.xmppStream.addDelegate(self, delegateQueue: DispatchQueue.main)
        self.updateScrollView()
        //self.tabBarController?.tabBar.isHidden = true
    }
    override func viewDidDisappear(_ animated: Bool) {
        print("disappear chat")
        xmpp_user1!.xmpp_controller!.xmppStream.removeDelegate(self)
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        // #warning Incomplete implementation, return the number of sections
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // #warning Incomplete implementation, return the number of rows
        return messages!.count
    }

    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let message = messages![indexPath.row]
        if message.income {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "incomeMessage", for: indexPath) as? IncomeMessageTableViewCell  else {
                fatalError("The dequeued cell is not an instance of ChatCell.")
            }
            cell.message.text = message.body
            return cell
        } else {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: "outcomeMessage", for: indexPath) as? OutcomeMessageTableViewCell  else {
                fatalError("The dequeued cell is not an instance of ChatCell.")
            }
            cell.message.text = message.body
            return cell
        }        
    }
 
    func updateScrollView() {
        let lastRow: Int = self.tableView.numberOfRows(inSection: 0) - 1
        let indexPath = IndexPath(row: lastRow, section: 0);
        self.tableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
    }
    
    /*
    // Override to support conditional editing of the table view.
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        // Return false if you do not want the specified item to be editable.
        return true
    }
    */

    /*
    // Override to support editing the table view.
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            // Delete the row from the data source
            tableView.deleteRows(at: [indexPath], with: .fade)
        } else if editingStyle == .insert {
            // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view
        }    
    }
    */

    /*
    // Override to support rearranging the table view.
    override func tableView(_ tableView: UITableView, moveRowAt fromIndexPath: IndexPath, to: IndexPath) {

    }
    */

    /*
    // Override to support conditional rearranging of the table view.
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        // Return false if you do not want the item to be re-orderable.
        return true
    }
    */

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

}

extension ChatTableViewController: XMPPStreamDelegate {
    //receive message
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        if message.from!.bareJID == XMPPJID(string: self.contact!.jid) {
            print("chat self save message")
            messages?.append(XMPPMessageContainer(
                body: message.body!,
                from: String(describing: message.from!.bareJID),
                income: true,
                is_read: true,
                message_id: message.elementID!
            ))
            tableView.beginUpdates()
            tableView.insertRows(at: [IndexPath(row: messages!.count-1, section: 0)], with: .automatic)
            tableView.endUpdates()
            self.updateScrollView()
            xmpp_user1?.add_income_message(message: message, is_read: true)
        } else {
            print("chat alien save message")
            xmpp_user1?.add_income_message(message: message, is_read: false)
        }
    }
}
