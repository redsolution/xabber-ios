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

import UIKit
import Kingfisher
import MaterialComponents.MDCPalettes
import CocoaLumberjack

class PhotosMediaCollectionCell: UICollectionViewCell {
    static let cellName: String = "PhotosMediaCollectionCell"
    var infoScreenDelegate: CellPhotoIsMissing? = nil
    
    let imageView: UIImageView = {
        let view = UIImageView()
        view.backgroundColor = .systemGroupedBackground
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.borderColor = MDCPalette.grey.tint500.withAlphaComponent(0.2).cgColor
        view.layer.borderWidth = 0.5
        
        return view
    }()
    
    let errorImageView: UIImageView = {
        let view = UIImageView()
        view.tintColor = MDCPalette.grey.tint300
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let selectedImageView: UIImageView = {
        let view = UIImageView()
        view.image = nil
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        view.layer.borderColor = MDCPalette.grey.tint100.cgColor
        view.layer.masksToBounds = true
        
        view.isHidden = true
        return view
    }()
    
    private var imageGeneration = UUID()
    private var imageResolutionTask: Task<Void, Never>?

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelImageLoad()
        imageView.image = nil
        errorImageView.removeFromSuperview()
        selectedImageView.removeFromSuperview()
    }
    
    internal func setup(photoUrls urls: (thumb: String?, url: String), owner: String) {
        addSubview(imageView)
        imageView.addSubview(selectedImageView)
        selectedImageView.frame = CGRect(x: contentView.frame.width - 28, y: 4, width: 22, height: 22)
        selectedImageView.layer.cornerRadius = selectedImageView.frame.height / 2
        contentView.bringSubviewToFront(selectedImageView)
        makeConstraints()
        imageView.layer.cornerRadius = 3
        addImage(urls: (thumb: urls.thumb, url: urls.url), owner: owner)
    }
    
    
    internal func makeConstraints() {
        NSLayoutConstraint.activate([
            imageView.leftAnchor.constraint(equalTo: self.leftAnchor),
            imageView.topAnchor.constraint(equalTo: self.topAnchor),
            imageView.rightAnchor.constraint(equalTo: self.rightAnchor),
            imageView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
        ])
    }
    
    private func cancelImageLoad() {
        imageGeneration = UUID()
        imageResolutionTask?.cancel()
        imageResolutionTask = nil
        imageView.kf.cancelDownloadTask()
    }

    private func addImage(urls: (thumb: String?, url: String), owner: String) {
        cancelImageLoad()
        let generation = imageGeneration
        let original = URL(string: urls.url)
        let thumbnail = urls.thumb.flatMap(URL.init(string:))
        guard let source = thumbnail ?? original else {
            activateErrorImage()
            return
        }
        let fallback = thumbnail != nil && thumbnail != original ? original : nil
        loadImage(source, fallback: fallback, owner: owner, generation: generation)
    }

    private func loadImage(_ source: URL, fallback: URL?, owner: String, generation: UUID) {
        let modifier = PrivacyProxyImageRequestModifier(owner: owner, onResolution: { [weak self] task in
            guard let self, self.imageGeneration == generation else { task.cancel(); return }
            self.imageResolutionTask = task
        })
        imageView.kf.setImage(with: source, options: modifier.options) { [weak self] result in
            guard let self, self.imageGeneration == generation else { return }
            self.imageResolutionTask = nil
            if case .failure = result {
                if let fallback {
                    self.loadImage(fallback, fallback: nil, owner: owner, generation: generation)
                } else {
                    self.activateErrorImage()
                    self.infoScreenDelegate?.passCellToFooter(cell: self)
                }
            }
        }
    }

    func activateErrorImage() {
        imageView.addSubview(errorImageView)
        errorImageView.image = imageLiteral("badge-blocked")?.withRenderingMode(.alwaysTemplate)
        NSLayoutConstraint.activate([
            errorImageView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            errorImageView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            errorImageView.widthAnchor.constraint(equalToConstant: 24),
            errorImageView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    
    func editModeEnabled() {
        selectedImageView.isHidden = false
    }
    
    func editModeDisabled() {
        selectedImageView.isHidden = true
        deselect()
    }
    
    func select() {
        selectedImageView.image = imageLiteral("checkmark.circle.fill")
        selectedImageView.tintColor = .systemBlue
        selectedImageView.backgroundColor = .clear
    }
    
    func deselect() {
        selectedImageView.image = nil
        selectedImageView.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        selectedImageView.layer.borderColor = MDCPalette.grey.tint100.cgColor
    }
}
