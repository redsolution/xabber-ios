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
import CocoaLumberjack

protocol DatePickerModalViewControllerDelegate {
    func onValueSelect(_ itemId: String, date: Date)
    func onValueChanged(_ itemId: String, date: Date)
    func onCancel(_ itemId: String)
}

class DatePickerModalViewController: UIViewController {
    
    open var itemId: String = ""
    open var delegate: DatePickerModalViewControllerDelegate? = nil
    
    internal let windowView: UIView = {
        let view = UIView(frame: .zero)
        
        return view
    }()
    
    internal let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, bottom: 12, left: 20, right: 20)
        
        return stack
    }()
    
    internal let buttonStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = 8
        
        return stack
    }()
    
    
    internal let cancelButton: UIButton = {
        let button = UIButton()
        
        button.setTitle("Cancel".localizeString(id: "cancel", arguments: []), for: .normal)
        button.setTitleColor(MDCPalette.blue.tint500, for: .normal)
        
        return button
    }()
    
    internal let saveButton: UIButton = {
        let button = UIButton()
        
        button.setTitle("Save".localizeString(id: "save", arguments: []), for: .normal)
        button.setTitleColor(MDCPalette.blue.tint500, for: .normal)
        
        return button
    }()
    
    internal let datePicker: UIDatePicker = {
        let picker = UIDatePicker()
        
        picker.datePickerMode = .countDownTimer
        
        return picker
    }()
    
    internal func activateConstraints() {
        
    }
    
    open func configure(_ itemId: String, currentDate: Date?) {
        self.itemId = itemId
        view.backgroundColor = UIColor.black.withAlphaComponent(0.87)
        windowView.frame = CGRect(x: 0,
                                  y: view.frame.height - 160,
                                  width: view.frame.width,
                                  height: 160)
        view.addSubview(windowView)
        windowView.addSubview(stack)
        stack.fillSuperview()
        stack.addArrangedSubview(buttonStack)
        stack.addArrangedSubview(datePicker)
        buttonStack.addArrangedSubview(cancelButton)
        buttonStack.addArrangedSubview(saveButton)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
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
