//
//  ChatViewController.swift
//  xabber_test_xmpp
//
//  Created by Igor Boldin on 30/01/2018.
//  Copyright © 2018 Igor Boldin. All rights reserved.
//

import UIKit
import XMPPFramework

class ChatViewController: UIViewController {

    var contact: XMPPContact?
    let screenSize = UIScreen.main.bounds
    
    @IBOutlet weak var mesage_body: UILabel!
    @IBOutlet weak var messageField: UITextField!
    @IBOutlet weak var contactInfo: UILabel!
    @IBOutlet weak var messageZone: UIScrollView!
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if contact != nil {
            self.contactInfo.text = contact!.jid
        }
        //xmpp_user1!.xmpp_controller!.xmppStream.addDelegate(self, delegateQueue: DispatchQueue.main)
        // Do any additional setup after loading the view.
    }
    override func viewDidAppear(_ animated: Bool) {
        print("appear chat")
        self.contact!.unread = 0
        self.contact!.read_messages()
        xmpp_user1!.xmpp_controller!.xmppStream.addDelegate(self, delegateQueue: DispatchQueue.main)
        let messages_list = contact!.load_messages()
        for item in messages_list! {
            messageZone.contentSize.height += 30
            var label: UILabel
            if item.income {
                label = UILabel(frame: CGRect(x: 40, y: messageZone.contentSize.height-30, width: screenSize.width-40, height: 25))
                label.textAlignment = NSTextAlignment.left
            } else {
                label = UILabel(frame: CGRect(x: 40, y: messageZone.contentSize.height-30, width: screenSize.width-90, height: 25))
                label.textAlignment = NSTextAlignment.right
            }
            label.text = item.body
            messageZone.addSubview(label)
            self.updateScrollView()
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        print("disappear chat")
        xmpp_user1!.xmpp_controller!.xmppStream.removeDelegate(self)
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    func updateScrollView() {
        let bottomOffset = CGPoint(x: 0, y: messageZone.contentSize.height - messageZone.bounds.size.height)
        messageZone.setContentOffset(bottomOffset, animated: true)
    }
    
    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */
    @IBAction func sendButton(_ sender: UIButton) {
        if contact != nil {
            let message_id = xmpp_user1?.send_message(message: messageField.text!, to: contact!.jid)
            xmpp_user1?.add_outcome_message(body: messageField.text!, from: XMPPJID(string: self.contact!.jid)!, message_id: message_id!)
            messageZone.contentSize.height += 30
            let outcome = UILabel(frame: CGRect(x: 40, y: messageZone.contentSize.height-30, width: screenSize.width-90, height: 25))
            outcome.textAlignment = NSTextAlignment.right
            outcome.text = messageField.text
            messageField.text = ""
            messageZone.addSubview(outcome)
            self.updateScrollView()
        }
    }
    
}

extension ChatViewController: XMPPStreamDelegate {
    //receive message
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        if message.from!.bareJID == XMPPJID(string: self.contact!.jid) {
            print("chat self save message")
            //TODO: Archiving message in storage
            messageZone.contentSize.height += 30
            let income = UILabel(frame: CGRect(x: 40, y: messageZone.contentSize.height-30, width: screenSize.width-40, height: 25))
            income.textAlignment = NSTextAlignment.left
            income.text = message.body!
            messageZone.addSubview(income)
            self.updateScrollView()
            xmpp_user1?.add_income_message(message: message, is_read: true)
        } else {
            print("chat alien save message")
            xmpp_user1?.add_income_message(message: message, is_read: false)
        }
    }
}
