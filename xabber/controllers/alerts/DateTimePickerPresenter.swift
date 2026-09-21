//
//  DateTimePickerPresenter.swift
//  xabber
//
//  Created by Игорь Болдин on 20.11.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

private enum DateTimePickerDurationLocalization {
    static func summary(day: Int, hour: Int, minute: Int) -> String {
        if day > 0 {
            return L10n.plural(
                "date_time_picker__duration__days_count",
                count: day,
                fallback: "%lld days"
            )
        }
        if hour > 0 {
            return L10n.plural(
                "date_time_picker__duration__hours_count",
                count: hour,
                fallback: "%lld hours"
            )
        }
        if minute > 0 {
            return L10n.plural(
                "date_time_picker__duration__minutes_count",
                count: minute,
                fallback: "%lld minutes"
            )
        }
        return L10n.text(
            "date_time_picker__duration__less_than_minute",
            fallback: "Less than a minute"
        )
    }
}


protocol DateTimePickerTextFieldDelegate {
    func dateTimePickerTextField(_ sender: DateTimePickerTextField, didSet date: Date, key: String)
    func dateTimePickerTextFieldDidCancel(_ sender: DateTimePickerTextField, key: String)
}

class DateTimePickerTextField: UITextField {
    
    open var datePicker: UIDatePicker = {
        let picker = UIDatePicker()
        
        return picker
    }()
    
    enum Kind {
        case date
        case period
    }
    
    private var key: String = ""
    
    open var callback: ((Date?) -> Void)? = nil
    open var isForever: Bool = false
    
    open var currentDate: Date? = Date()
    
    open var dateDelegate: DateTimePickerTextFieldDelegate? = nil
    
    var withPlaceholder: Bool = false
    
    func setMinimumDate(_ date: Date) {
        self.datePicker.minimumDate = date
    }
    
    func configureDatePicker(for kind: Kind, key: String, withPlaceholder: Bool = false) {
        self.key = key
        let screenWidth = UIScreen.main.bounds.width
        self.withPlaceholder = withPlaceholder
        self.textColor = .tintColor
        if self.withPlaceholder {
            self.placeholder = L10n.text("date_time_picker__field__select_date", fallback: "Select date")
        } else {
            self.placeholder = nil
        }
        
        self.datePicker.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 216)
        switch kind {
            case .date:
                self.datePicker.datePickerMode = .dateAndTime
            case .period:
                self.datePicker.datePickerMode = .countDownTimer
        }
        self.datePicker.preferredDatePickerStyle = .wheels
        
        if let date = self.currentDate {
            self.datePicker.date = date
        }
        
        self.inputView = self.datePicker
        
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        
        let doneButton = UIBarButtonItem(title: L10n.text("common__action__select", fallback: "Select"), style: .done, target: self, action: #selector(donePressed))
        let flexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        
        toolbar.setItems([flexibleSpace, doneButton], animated: true)
        self.inputAccessoryView = toolbar
        self.datePicker.addTarget(self, action: #selector(self.dateChanged), for: .valueChanged)
    }
    
    @objc private func donePressed() {
        self.updateTextField(with: self.currentDate, isForever: self.isForever)
        let now = Date()
        if let date = self.currentDate,
            date > now  {
            self.dateDelegate?.dateTimePickerTextField(self, didSet: date, key: self.key)
        } else {
            self.dateDelegate?.dateTimePickerTextFieldDidCancel(self, key: self.key)
        }
        self.endEditing(true)
    }
    
    @objc private func dateChanged(_ sender: UIDatePicker) {
        self.currentDate = sender.date
    }
    
    public func updateTextField(with date: Date?, isForever: Bool) {
        
        if self.withPlaceholder {
            self.placeholder = L10n.text("date_time_picker__field__select_date", fallback: "Select date")
        } else {
            self.placeholder = nil
        }
        
        if isForever {
            self.text = L10n.text("date_time_picker__field__forever", fallback: "Forever")
            return
        }
        guard let date = date else {
            return
        }
        let calendar = Calendar.current
        let now = Date()
        
        if date <= now {
            return
        }
        
        let components = calendar.dateComponents([.day, .hour, .minute], from: now, to: date)
        
        guard let day = components.day,
              let hour = components.hour,
              let minute = components.minute else {
            return
        }
        
        self.text = DateTimePickerDurationLocalization.summary(
            day: day,
            hour: hour,
            minute: minute
        )
    }
}

class DatePeriodPickerTextField: UITextField {
    
    open var datePicker: UIPickerView = {
        let picker = UIPickerView()
        
        return picker
    }()
    
    enum Kind {
        case date
        case period
    }
    
    private var key: String = ""
    
    open var callback: ((Date?) -> Void)? = nil
    open var isForever: Bool = false
    
    open var currentDate: Date? = Date()
    
    open var dateDelegate: DateTimePickerTextFieldDelegate? = nil
    
    static let maxDays: Int = 100
    static let maxHours: Int = 24
    static let maxMinutes: Int = 60
    
    let days: [Int] = (0..<TimePickerAlertController.maxDays).compactMap({ $0 })
    let hours: [Int] = (0..<TimePickerAlertController.maxHours).compactMap({ $0 })
    let minutes: [Int] = (0..<TimePickerAlertController.maxMinutes).compactMap({ $0 })
    
    open var selectedDays : Int? = nil
    open var selectedHours : Int? = nil
    open var selectedMins : Int? = nil
    
    var withPlaceholder: Bool = false
    
    func setMinimumDate(_ date: Date) {
//        self.datePicker.minimumDate = date
    }
    
    func configureDatePicker(for kind: Kind, key: String, withPlaceholder: Bool = false) {
        self.key = key
        let screenWidth = UIScreen.main.bounds.width
        self.withPlaceholder = withPlaceholder
        self.textColor = .tintColor
        if self.withPlaceholder {
            self.placeholder = L10n.text("date_time_picker__field__select_period", fallback: "Select period")
        } else {
            self.placeholder = nil
        }
        
        self.datePicker.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 216)
//        switch kind {
//            case .date:
//                self.datePicker.datePickerMode = .dateAndTime
//            case .period:
//                self.datePicker.datePickerMode = .countDownTimer
//        }
//        self.datePicker.preferredDatePickerStyle = .wheels
        
//        if let date = self.currentDate {
//            self.datePicker.date = date
//        }
        
        self.inputView = self.datePicker
        
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        
        let doneButton = UIBarButtonItem(title: L10n.text("common__action__select", fallback: "Select"), style: .done, target: self, action: #selector(donePressed))
        let flexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        
        toolbar.setItems([flexibleSpace, doneButton], animated: true)
        self.inputAccessoryView = toolbar
//        self.datePicker.addTarget(self, action: #selector(self.dateChanged), for: .valueChanged)
    }
    
    @objc private func donePressed() {
        self.updateTextField(with: self.currentDate, isForever: self.isForever)
        let now = Date()
//        if let date = self.currentDate,
//            date > now  {
//            self.dateDelegate?.dateTimePickerTextField(self, didSet: date, key: self.key)
//        } else {
//            self.dateDelegate?.dateTimePickerTextFieldDidCancel(self, key: self.key)
//        }
        self.endEditing(true)
    }
    
    @objc private func dateChanged(_ sender: UIDatePicker) {
        self.currentDate = sender.date
    }
    
    public func updateTextField(with date: Date?, isForever: Bool) {
        
        if self.withPlaceholder {
            self.placeholder = L10n.text("date_time_picker__field__select_date", fallback: "Select date")
        } else {
            self.placeholder = nil
        }
        
        if isForever {
            self.text = L10n.text("date_time_picker__field__forever", fallback: "Forever")
            return
        }
        guard let date = date else {
            return
        }
        let calendar = Calendar.current
        let now = Date()
        
        if date <= now {
            return
        }
        
        let components = calendar.dateComponents([.day, .hour, .minute], from: now, to: date)
        
        guard let day = components.day,
              let hour = components.hour,
              let minute = components.minute else {
            return
        }
        
        self.text = DateTimePickerDurationLocalization.summary(
            day: day,
            hour: hour,
            minute: minute
        )
    }
}

class DateTimePickerViewController: XabberAlertController{
    weak var presenter: DateTimePickerPresenter?
    var cancelled: Bool = false
    private var picker: UIDatePicker!
    private var headerView: UIView!
    
    static let maxDays: Int = 100
    static let maxHours: Int = 24
    static let maxMinutes: Int = 60
    
    let days: [Int] = (0..<TimePickerAlertController.maxDays).compactMap({ $0 })
    let hours: [Int] = (0..<TimePickerAlertController.maxHours).compactMap({ $0 })
    let minutes: [Int] = (0..<TimePickerAlertController.maxMinutes).compactMap({ $0 })
    
    var delegate: TimePickerAlertControllerDelegate? = nil
    
    var key: String? = nil
    
    open var selectedDays : Int? = nil
    open var selectedHours : Int? = nil
    open var selectedMins : Int? = nil
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        picker = UIDatePicker()
//        picker.dataSource = self
//        picker.delegate = self
        self.view.addSubview(picker)
        picker.sizeToFit()
        picker.datePickerMode = .dateAndTime
        picker.preferredDatePickerStyle = .wheels
        picker.fillSuperview()
//        picker.fillSuperviewWithOffset(top: -44, bottom: 52, left: -100, right: 0)
//        DispatchQueue.main.async {
//            if let firstSubview = self.view.subviews.first,
//               let contentView = firstSubview.subviews.first {
//                contentView.addSubview(self.picker)
//                self.picker.fillSuperview()
//            }
//        }

    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        picker.sizeToFit()
    }
}

extension DateTimePickerViewController: UIPickerViewDelegate {
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let selectedComponents = [
            pickerView.selectedRow(inComponent: 0),
            pickerView.selectedRow(inComponent: 2),
            pickerView.selectedRow(inComponent: 4),
        ]
        let out = selectedComponents[0] * 24 * 60 * 60 + selectedComponents[1] * 60 * 60 + selectedComponents[2] * 60
        self.selectedDays = selectedComponents[0]
        self.selectedHours = selectedComponents[1]
        self.selectedMins = selectedComponents[2]
//        self.delegate?.timePickerAlertController(didSelect: out, days: selectedComponents[0], hours: selectedComponents[1], minutes: selectedComponents[2], key: self.key)
    }
}

class DateTimePickerPresenter {
    public var alert: DateTimePickerViewController? = nil
    var selectionCompletion: ((String) -> Void)?
    
    var delegate: TimePickerAlertControllerDelegate? = nil
    var key: String? = nil
   
    func present(in view: UIViewController, title: String?, message: String?, cancel: String?, animated: Bool, key: String?) {
        
        self.alert = DateTimePickerViewController(title: title, message: message ?? "", preferredStyle: .actionSheet)
        self.alert?.presenter = self
        self.alert?.delegate = self.delegate
        alert?.preferredContentSize = CGSize(width: 250, height: 250)
        self.key = key
        
        
        if let cancel = cancel {
            let cancelUIAction = UIAlertAction(title: cancel, style: .cancel) { action in
                self.delegate?.timePickerAlertControllerDidCancel()
                self.alert?.cancelled = true
                self.alert?.dismiss(animated: false)
            }
            alert?.addAction(cancelUIAction)
        }
        
        let okAction = UIAlertAction(title: L10n.text("common__action__confirm", fallback: "Confirm"), style: .default) { action in
            self.delegate?.timePickerAlertControllerDidSet(key: self.key, days: self.alert?.selectedDays, hours: self.alert?.selectedHours, minutes: self.alert?.selectedMins)
            self.alert?.dismiss(animated: false)
        }
        alert?.addAction(okAction)
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert?.popoverPresentationController {
                popoverController.sourceView = view.view
                popoverController.sourceRect = CGRect(x: view.view.bounds.midX, y: view.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        view.present(alert!, animated: animated, completion: nil)
    }
}
