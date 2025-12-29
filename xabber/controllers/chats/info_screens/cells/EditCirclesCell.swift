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

class EditCirclesCell: UITableViewCell {
    public static let cellName: String = "EditCirclesCell"
    
    class CircleCollectionItemCell: UICollectionViewCell {
        public static let cellName: String = "CircleCollectionItemCell"
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        required init?(coder: NSCoder) { fatalError() }

        private func setup() {
            label.font = .systemFont(ofSize: 14, weight: .regular)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false

            contentView.addSubview(label)
            contentView.layer.cornerRadius = 4
            contentView.layer.borderWidth = 0

            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
                label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
            ])
        }

        func configure(with text: String, color: UIColor) {
            label.text = text
            contentView.backgroundColor = color.withAlphaComponent(0.15)
            contentView.layer.borderColor = color.cgColor
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            label.text = nil
        }
    }
    
    let iconView: UIImageView = {
        let view = UIImageView()
        view.tintColor = .tintColor
        return view
    }()
    
    
    class FlowLayout: UICollectionViewFlowLayout {
        override init() {
            super.init()
            estimatedItemSize = UICollectionViewFlowLayout.automaticSize
            minimumInteritemSpacing = 8
            minimumLineSpacing = 8
            sectionInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        }
        
        required init?(coder: NSCoder) {
            fatalError()
        }
        
        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            let attributes = super.layoutAttributesForElements(in: rect)?.map { $0.copy() as! UICollectionViewLayoutAttributes }
                    
            var leftMargin = sectionInset.left
            var maxY: CGFloat = -1.0
            
            attributes?.forEach { layoutAttribute in
                if layoutAttribute.frame.origin.y >= maxY { // новая строка
                    leftMargin = sectionInset.left
                }
                layoutAttribute.frame.origin.x = leftMargin
                leftMargin += layoutAttribute.frame.width + minimumInteritemSpacing
                maxY = max(maxY, layoutAttribute.frame.maxY)
            }
            
            return attributes
        }
    }
    
    let tagView: UICollectionView = {
        let layout = FlowLayout()
        
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        
        view.register(CircleCollectionItemCell.self, forCellWithReuseIdentifier: CircleCollectionItemCell.cellName)
        
        view.isUserInteractionEnabled = false
        
        return view
    }()
    
    var circles: [String] = []
    var color: UIColor = .tintColor
    
    public final func configure(owner: String, icon: String?, circles: [String]) {
//        if let icon = icon {
//            iconView.image = imageLiteral(icon)
//        } else {
//            iconView.isHidden = true
//        }
        self.circles = Array(Set(circles)).sorted()
        self.tagView.reloadData()
        self.color = AccountColorManager.shared.palette(for: owner).tint700
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
//        iconView.isHidden = false
    }
    
    public final func setupSubviews() {
        selectionStyle = .none
//        contentView.addSubview(iconView)
        contentView.addSubview(tagView)

//        iconView.translatesAutoresizingMaskIntoConstraints = false
        tagView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
//            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
//            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
//            iconView.widthAnchor.constraint(equalToConstant: 24),
//            iconView.heightAnchor.constraint(equalToConstant: 24),

            tagView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tagView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20), // отступ слева
            tagView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tagView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])

        accessoryType = .disclosureIndicator
        tagView.dataSource = self
        tagView.delegate = self
        tagView.backgroundColor = .clear
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .value1, reuseIdentifier: reuseIdentifier)
        setupSubviews()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupSubviews()
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
    
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                          withHorizontalFittingPriority horizontal: UILayoutPriority,
                                          verticalFittingPriority: UILayoutPriority) -> CGSize {

        tagView.layoutIfNeeded()
        let height = tagView.collectionViewLayout.collectionViewContentSize.height
        return CGSize(width: targetSize.width, height: height + 16)
    }
}

extension EditCirclesCell: UICollectionViewDelegate {
    
}

extension EditCirclesCell: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if self.circles.isEmpty {
            return 1
        }
        return self.circles.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CircleCollectionItemCell.cellName, for: indexPath) as? CircleCollectionItemCell else {
            fatalError()
        }
        if self.circles.isEmpty {
            cell.configure(with: "No circles", color: MDCPalette.grey.tint500)
        } else {
            cell.configure(with: self.circles[indexPath.row], color: self.color)
        }
        return cell
    }
    
    
}
