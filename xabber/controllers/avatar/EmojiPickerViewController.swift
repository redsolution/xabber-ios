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

class EmojiPicketCollectionViewCell: UICollectionViewCell {
    static let cellName: String = "EmojiPickerCell"
    private let label: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 32)
        
        return label
    }()
    
    public final func configure(_ emoji: String) {
        self.label.text = emoji
    }
    
    private final func setupSubviews() {
        contentView.addSubview(label)
        label.fillSuperview()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }
    
    override class func awakeFromNib() {
        super.awakeFromNib()
    }
}

class EmojiCollectionViewFlowLayout: UICollectionViewLayout {
    
}

protocol EmojiPickerViewControllerDelegate {
    func onEmojiSelected(_ emoji: String)
}

class EmojiPickerViewController: UIViewController {
    
    class Datasource {
        var categoryName: String
        var emojis: [String] = []
        
        init(name categoryName: String, emojis: [String]) {
            self.categoryName = categoryName
            self.emojis = emojis
        }
    }
    
    open var delegate: EmojiPickerViewControllerDelegate? = nil
    
    private var datasource: [Datasource] = []
    
    private var selectedCategoryId: Int = 0
    
    private let contentView: UIView = {
        let view = UIView()
        
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        
        view.layer.cornerRadius = 44
        view.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
        
        return view
    }()
    
    private let dragToDismissButton: UIButton = {
        let button = UIButton()
        
        button.backgroundColor = UIColor.black.withAlphaComponent(0.23)
        button.layer.cornerRadius = 3
        
        return button
    }()
    
    
    private let collectionView: UICollectionView = {
        let flowLayout = EmojiCollectionViewFlowLayout()
        let view = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        
        view.register(
            EmojiPicketCollectionViewCell.self,
            forCellWithReuseIdentifier: EmojiPicketCollectionViewCell.cellName
        )
//        view.backgroundColor = MDCPalette.lightBlue.tint100
        
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        
        return view
    }()
    
    private let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
//        stack.spacing = 16
        stack.distribution = .equalSpacing 
        
        return stack
    }()
    
    private var controls: [UIButton] = []
    
    public func activateConstraints() {
        
    }
    
    public func setupSubviews() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            contentView.frame = CGRect(
                x: (self.view.frame.width - 414) / 2,
                y: self.view.frame.height / 2 + 16,
                width: 414,
                height: (self.view.frame.height / 2) - 16)
            dragToDismissButton.frame = CGRect(x: 414 / 2 - 32, y: 8, width: 64, height: 6)
        } else {
            contentView.frame = CGRect(
                x: 0,
                y: self.view.frame.height / 4 + 16,
                width: self.view.frame.width,
                height: (self.view.frame.height / 4) * 3 - 16)
            dragToDismissButton.frame = CGRect(x: self.view.frame.width / 2 - 32, y: 8, width: 64, height: 6)
        }
//        view.isUserInteractionEnabled = false
        view.addSubview(contentView)
        contentView.addSubview(dragToDismissButton)
        contentView.addSubview(collectionView)
        collectionView.fillSuperviewWithOffset(top: 36, bottom: 82, left: 24, right: 24)
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: (self.view.frame.height / 4) * 3 - 16 - 68, bottom: 24, left: 24, right: 24)
    }
    
    public func configure() {
        collectionView.delegate = self
        collectionView.dataSource = self
        
        
        
        
        let dismissGestureRecognizer = PanDirectionGestureRecognizer(direction: .vertical, target: self, action: #selector(self.onDismissGestureRecognizerDidChange))
        dismissGestureRecognizer.delaysTouchesBegan = true
        dismissGestureRecognizer.maximumNumberOfTouches = 1
        dismissGestureRecognizer.cancelsTouchesInView = false
        
        contentView.addGestureRecognizer(dismissGestureRecognizer)
//        let dismissGesture = UITapGestureRecognizer(target: self, action: #selector(dismissOnTap))
//        dismissGesture.delaysTouchesBegan = true
//        dismissGesture.cancelsTouchesInView = false
//        self.view.addGestureRecognizer(dismissGesture)
        let flowLayout = UICollectionViewFlowLayout()
        flowLayout.estimatedItemSize = CGSize(square: 64)
        flowLayout.scrollDirection = .vertical
        flowLayout.itemSize = CGSize(square: 64)
        
//        collectionView.allowsSelection = true
        
        collectionView.isUserInteractionEnabled = true
        collectionView.setCollectionViewLayout(flowLayout, animated: true)
//        collectionView.allowsSelection = true
        loadDatasource()
    }
    
    private final func loadDatasource() {
        if let path = Bundle.main.path(forResource: "emojis", ofType: "json") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                let jsonResult = try JSONSerialization.jsonObject(with: data, options: .mutableLeaves)
                if let categories = (jsonResult as? NSArray)?.compactMap({ return $0 as? NSDictionary }) {
                    self.datasource = categories.enumerated().compactMap {
                        (offset, category) in
                        guard let categoryName = category["type"] as? String,
                              let emojis = (category["emojis"] as? NSArray)?
                                  .compactMap({ return ($0 as? NSArray)?.firstObject as? String }) else {
                            return nil
                        }
                        if let image = UIImage(named: categoryName, in: Bundle.main, compatibleWith: nil) {
                            let button = UIButton(frame: CGRect(square: 44))
                            button.setImage(image, for: .normal)
                            button.backgroundColor = MDCPalette.grey.tint50
                            button.tintColor = MDCPalette.grey.tint600
                            button.tag = offset
                            button.addTarget(self, action: #selector(self.onCategorySelectorTouchUpInside), for: .touchUpInside)
                            controls.append(button)
                        }
                        return Datasource(name: categoryName, emojis: emojis)
                    }
                }
                var constreints: [NSLayoutConstraint] = []
                controls.forEach {
                    stack.addArrangedSubview($0)
                    constreints.append(contentsOf: [
                        $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
                        $0.heightAnchor.constraint(equalToConstant: 44)
                    ])
                }
                NSLayoutConstraint.activate(constreints)
            } catch {
                print(error.localizedDescription)
                fatalError()
            }
        }
    }
    
    public func addObservers() {
        
    }
    
    public func removeObservers() {
        
    }
    
    public func localizeResources() {
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupSubviews()
        configure()
        localizeResources()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activateConstraints()
        addObservers()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        removeObservers()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    @objc
    private final func onCategorySelectorTouchUpInside(_ sender: UIButton) {
        self.selectedCategoryId = sender.tag
        self.collectionView.reloadData()
        self.collectionView.scrollToItem(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
    }
    
    @objc
    private final func onDismissGestureRecognizerDidChange(_ sender: UIPanGestureRecognizer) {
        let y = sender.translation(in: self.contentView).y
        if sender.state == .ended {
            if y > 200 {
                FeedbackManager.shared.tap()
                self.dismiss(animated: true, completion: nil)
            }
            UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
                let rect = self.contentView.frame
                
                if UIDevice.current.userInterfaceIdiom == .pad {
                    self.contentView.frame = CGRect(
                        x: (self.view.frame.width - 414) / 2,
                        y: self.view.frame.height / 2 + 16,
                        width: rect.width,
                        height: rect.height
                    )
                } else {
                    self.contentView.frame = CGRect(
                        x: 0,
                        y: self.view.frame.height / 4 + 16,
                        width: rect.width,
                        height: rect.height
                    )
                }
                
                
            } completion: { result in
                
            }

        }
        if sender.state != .changed { return }
        let rect = self.contentView.frame
        if y > 0 {
            
            if UIDevice.current.userInterfaceIdiom == .pad {
                self.contentView.frame = CGRect(
                    x: (self.view.frame.width - 414) / 2,
                    y: self.view.frame.height / 2 + 16 + y,
                    width: rect.width,
                    height: rect.height
                )
            } else {
                self.contentView.frame = CGRect(
                    x: 0,
                    y: self.view.frame.height / 4 + 16 + y,
                    width: rect.width,
                    height: rect.height
                )
            }
        }
    }
    
    @objc
    private final func dismissOnTap(_ sender: AnyObject) {
        
    }
}


extension EmojiPickerViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView,
                          layout collectionViewLayout: UICollectionViewLayout,
                          sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(square: 64)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        self.delegate?.onEmojiSelected(datasource[self.selectedCategoryId].emojis[indexPath.row])
        self.dismiss(animated: true, completion: nil)
    }
    
}

extension EmojiPickerViewController: UICollectionViewDataSource {
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiPicketCollectionViewCell.cellName, for: indexPath) as? EmojiPicketCollectionViewCell else {
            fatalError()
        }

        cell.configure(datasource[selectedCategoryId].emojis[indexPath.row])
        
        return cell
    }
    
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return datasource[selectedCategoryId].emojis.count
    }
    
}
