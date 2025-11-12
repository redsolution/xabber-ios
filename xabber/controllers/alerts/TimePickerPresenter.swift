//
//  TimePickerPresenter.swift
//  xabber
//
//  Created by Игорь Болдин on 01.11.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

protocol TimePickerAlertControllerDelegate {
    func timePickerAlertControllerDidSet(key: String?, days: Int?, hours: Int?, minutes: Int?)
    func timePickerAlertControllerDidCancel()
}

class TimePickerAlertController: XabberAlertController{
    weak var presenter: TimePickerPresenter?
    var cancelled: Bool = false
    private var picker: UIPickerView!
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
        
        picker = UIPickerView()
        picker.dataSource = self
        picker.delegate = self
        self.view.addSubview(picker)
        picker.fillSuperviewWithOffset(top: -44, bottom: 52, left: 0, right: 0)
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
extension TimePickerAlertController: UIPickerViewDataSource {
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 6
    }
    
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        switch component {
            case 0:
                return days.count
            case 1:
                return 1
            case 2:
                return hours.count
            case 3:
                return 1
            case 4:
                return minutes.count
            case 5:
                return 1
            default:
                return 0
        }
    }
    
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        switch component {
            case 0:
                return "\(days[row])"
            case 1:
                return "days"
            case 2:
                return "\(hours[row])"
            case 3:
                return "hours"
            case 4:
                return "\(minutes[row])"
            case 5:
                return "mins"
            default:
                return nil
        }
    }
    
    func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
        let fontForNumber = UIFont.systemFont(ofSize: 17)
        let fontForTitle = UIFont.systemFont(ofSize: 13)
        switch component {
            case 0:
                if let label = view as? UILabel {
                    label.text = "\(days[row])"
                    label.font = fontForNumber
                    return label
                }
                let label = UILabel(frame: CGRectMake(35, 0, pickerView.frame.size.width/3 - 35, 30))
                label.text = "\(days[row])"
                label.font = fontForNumber
                label.textAlignment = NSTextAlignment.center

                return label
            case 1:
                if let label = view as? UILabel {
                    label.text = "days"
                    label.font = fontForTitle
                    label.textAlignment = NSTextAlignment.center
                    return label
                }
                let label = UILabel(frame: CGRectMake(35, 0, pickerView.frame.size.width/3 - 35, 30))
                label.text = "days"
                label.font = fontForTitle
                label.textAlignment = NSTextAlignment.center

                return label
            case 2:
                if let label = view as? UILabel {
                    label.text = "\(hours[row])"
                    label.font = fontForNumber
                    return label
                }
                let label = UILabel(frame: CGRectMake(35, 0, pickerView.frame.size.width/3 - 35, 30))
                label.text = "\(hours[row])"
                label.font = fontForNumber
                label.textAlignment = NSTextAlignment.center

                return label
            case 3:
                if let label = view as? UILabel {
                    label.text = "hours"
                    label.font = fontForTitle
                    label.textAlignment = NSTextAlignment.center
                    return label
                }
                let label = UILabel(frame: CGRectMake(35, 0, pickerView.frame.size.width/3 - 35, 30))
                label.text = "hours"
                label.font = fontForTitle
                label.textAlignment = NSTextAlignment.center

                return label
            case 4:
                if let label = view as? UILabel {
                    label.text = "\(minutes[row])"
                    label.font = fontForNumber
                    return label
                }
                let label = UILabel(frame: CGRectMake(35, 0, pickerView.frame.size.width/3 - 35, 30))
                label.text = "\(minutes[row])"
                label.font = fontForNumber
                label.textAlignment = NSTextAlignment.center

                return label
            case 5:
                if let label = view as? UILabel {
                    label.text = "mins"
                    label.font = fontForTitle
                    label.textAlignment = NSTextAlignment.center
                    return label
                }
                let label = UILabel(frame: CGRectMake(35, 0, pickerView.frame.size.width/3 - 35, 30))
                label.text = "mins"
                label.font = fontForTitle
                label.textAlignment = NSTextAlignment.center

                return label
            default:
                let label = UILabel(frame: CGRectMake(35, 0, pickerView.frame.size.width/3 - 35, 30))
                label.text = "mins"
                label.font = UIFont.systemFont(ofSize: 10)
                label.textAlignment = NSTextAlignment.center

                return label
        }
        
        
    }
}

extension TimePickerAlertController: UIPickerViewDelegate {
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

class TimePickerPresenter {
    public var alert: TimePickerAlertController? = nil
    var selectionCompletion: ((String) -> Void)?
    
    var delegate: TimePickerAlertControllerDelegate? = nil
    var key: String? = nil
   
    func present(in view: UIViewController, title: String?, message: String?, cancel: String?, animated: Bool, key: String?) {
        
        self.alert = TimePickerAlertController(title: title, message: message ?? "", preferredStyle: .actionSheet)
        self.alert?.presenter = self
        self.alert?.delegate = self.delegate
        self.key = key
        
        
        if let cancel = cancel {
            let cancelUIAction = UIAlertAction(title: cancel, style: .cancel) { action in
                self.delegate?.timePickerAlertControllerDidCancel()
                self.alert?.cancelled = true
                self.alert?.dismiss(animated: false)
            }
            alert?.addAction(cancelUIAction)
        }
        
        let okAction = UIAlertAction(title: "Confirm", style: .default) { action in
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
