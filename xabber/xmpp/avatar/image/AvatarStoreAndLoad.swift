//
//  AvatarStoreAndLoad.swift
//  xabber_test_xmpp
//
//  Created by Igor Boldin on 24/04/2018.
//  Copyright © 2018 Igor Boldin. All rights reserved.
//


import Foundation
import Haneke

func createDefaultAvatar(forJid jid: String, withUsername username: String) {
    
}

class DefaultAvatar: UIView {
    var username: String = ""
    var jid: String = ""
    var color: CGColor = UIColor.blue.cgColor
    
    func set(forJid jid: String, withUsername un: String, color: CGColor) {
        self.jid = jid
        self.username = un
        self.color = color
        self.setNeedsDisplay()
    }
    
    override func draw(_ rect: CGRect) {
        self.backgroundColor = UIColor(displayP3Red: 0, green: 0, blue: 0, alpha: 0)
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        context.addRect(rect)
        context.setFillColor(self.color)
        context.fillPath()
        context.addRect(rect)
        let toner = UIColor(displayP3Red: 0, green: 0, blue: 0, alpha: 0.3)
        context.setFillColor(toner.cgColor)
        context.fillPath()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        let attributes = [
            NSAttributedStringKey.paragraphStyle: paragraphStyle,
            NSAttributedStringKey.font: UIFont.systemFont(ofSize: 20.0),
            NSAttributedStringKey.foregroundColor: UIColor.white
        ]
        var text: String = ""
        self.username = self.username.uppercased()
        if username.contains(" ") {
            text = "\(Array(username.split(separator: " ").first!)[0])\(Array(username.split(separator: " ")[1])[0])"
        } else {
            text = "\(Array(self.jid.uppercased())[0])\(Array(self.jid.uppercased())[1])"
        }
        let myText = text
        let textRect = CGRect(x: 0, y: rect.midY - rect.midY/2, width: rect.size.width, height: rect.size.height - rect.midY/2)
        let attributedString = NSAttributedString(string: myText, attributes: attributes)
        attributedString.draw(in: textRect)
    }
}
