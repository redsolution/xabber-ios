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

protocol PresenterPickerViewControllerDelegate {
    func didUpdateValue(_ value: String, component: Int)
}

class PresenterPickerViewController: UIViewController {
    
    class Datasource: Hashable {
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.title == rhs.title && lhs.value == rhs.value
        }
        
        var current: Bool
        var title: String
        var value: String
        
        init(_ current: Bool, title: String, value: String) {
            self.current = current
            self.title = title
            self.value = value
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            hasher.combine(value)
        }
    }
    
    open var delegate: PresenterPickerViewControllerDelegate?
    
    internal var datasource: [[Datasource]] = []
    
    internal let picker: UIPickerView = {
        let picker = UIPickerView()
        
        return picker
    }()
    
    internal func activateConstraints() {
//        preferredContentSize = CGSize(width: 250, height: 250)
    }
    
    internal func configure(_ values: [[Datasource]]) {
        datasource = values
        view.addSubview(picker)
        picker.fillSuperview()
        picker.dataSource = self
        picker.delegate = self
        activateConstraints()
        self.preferredContentSize = CGSize(width: 250, height: 140)
        datasource.forEach {
            if let row = $0.firstIndex(where: { $0.current }),
                let section = datasource.firstIndex(of: $0) {
                picker.selectRow(row, inComponent: section, animated: true)
            }
        }
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        picker.reloadAllComponents()
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

extension PresenterPickerViewController: UIPickerViewDataSource {
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return datasource.count
    }
    
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return datasource[component].count
    }
    
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return datasource[component][row].title
    }
}

extension PresenterPickerViewController: UIPickerViewDelegate {
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        self.delegate?.didUpdateValue(datasource[component][row].value, component: component)
    }
}

class PickerViewPresenter {
    
    var selectedValue: String? = nil
    var selectedComponent: Int? = nil
    
    func present(in view: UIViewController, title: String?, message: String?, setText: String, cancelText: String, defaultText: String?, defaultValue: String?, values: [[PresenterPickerViewController.Datasource]], animated: Bool, onCancel: @escaping (() -> Void), completion: @escaping ((String?, String?, Int?)->Void)) {
        selectedValue = defaultValue
        let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)

        let vc = PresenterPickerViewController()
        vc.delegate = self
        vc.configure(values)
        
        alert.setValue(vc, forKey: "contentViewController")
        if let defaultText = defaultText {
            alert.addAction(UIAlertAction(title: defaultText, style: .default, handler: { (_) in
                completion(defaultValue,
                           values[self.selectedComponent ?? 0].first(where: { $0.value == self.selectedValue })?.title,
                           self.selectedComponent)
            }))
        }
        alert.addAction(UIAlertAction(title: setText, style: .default, handler: { (_) in
            completion(self.selectedValue,
                       values[self.selectedComponent ?? 0].first(where: { $0.value == self.selectedValue })?.title,
                       self.selectedComponent)
        }))
        alert.addAction(UIAlertAction(title: cancelText, style: .cancel, handler: { (_) in
            onCancel()
        }))
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = view.view
                popoverController.sourceRect = CGRect(x: view.view.bounds.midX, y: view.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        view.present(alert, animated:  animated, completion: nil)
    }
}

extension PickerViewPresenter: PresenterPickerViewControllerDelegate {
    func didUpdateValue(_ value: String, component: Int) {
        selectedValue = value
        selectedComponent = component
        print(value)
    }
}
