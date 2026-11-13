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
    private var networkImageTask: KingfisherChatThumbnailLoadTask?
    private lazy var showExternalImageButton = ExternalImageConsentButton(in: contentView)

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelImageLoad()
        selectedImageView.isHidden = true
        imageView.image = nil
        errorImageView.removeFromSuperview()
        selectedImageView.removeFromSuperview()
    }
    
    internal func setup(photoUrls urls: (thumb: String?, url: String), owner: String) {
        if imageView.superview == nil {
            contentView.insertSubview(imageView, at: 0)
            makeConstraints()
        }
        imageView.addSubview(selectedImageView)
        selectedImageView.frame = CGRect(x: contentView.frame.width - 28, y: 4, width: 22, height: 22)
        selectedImageView.layer.cornerRadius = selectedImageView.frame.height / 2
        imageView.layer.cornerRadius = 3
        addImage(urls: (thumb: urls.thumb, url: urls.url), owner: owner)
    }
    
    
    internal func makeConstraints() {
        NSLayoutConstraint.activate([
            imageView.leftAnchor.constraint(equalTo: contentView.leftAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.rightAnchor.constraint(equalTo: contentView.rightAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
    
    private func cancelImageLoad() {
        imageGeneration = UUID()
        networkImageTask?.cancel()
        networkImageTask = nil
        imageView.kf.cancelDownloadTask()
        showExternalImageButton.reset()
    }

    private func addImage(urls: (thumb: String?, url: String), owner: String) {
        cancelImageLoad()
        errorImageView.removeFromSuperview()
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

    private func loadImage(_ source: URL, fallback: URL?, owner: String, generation: UUID, previous: URL? = nil) {
        let task = KingfisherChatThumbnailLoadTask()
        networkImageTask = task
        let modifier = PrivacyProxyImageRequestModifier(
            owner: owner,
            onResolution: task.updateResolution,
            onDownloadTaskStarted: task.update
        )
        imageView.kf.setImage(with: source, options: modifier.options) { [weak self] result in
            guard let self, !task.isCancelled, self.imageGeneration == generation else { return }
            self.networkImageTask = nil
            if case .failure = result {
                if let fallback {
                    self.loadImage(fallback, fallback: nil, owner: owner, generation: generation, previous: source)
                } else if let candidate = [source, previous].compactMap({ $0 }).first(where: {
                    PrivacyProxyMediaRouter.shared.canRequestDirectImage($0, owner: owner)
                }) {
                    self.offerExternalImageConsent(candidate, owner: owner, generation: generation)
                } else {
                    self.activateErrorImage()
                    self.infoScreenDelegate?.passCellToFooter(cell: self)
                }
            }
        }
    }

    private func offerExternalImageConsent(_ url: URL, owner: String, generation: UUID) {
        showExternalImageButton.isHidden = !selectedImageView.isHidden
        let retry: () -> Void = { [weak self] in
            guard let self else { return }
            self.cancelImageLoad()
            self.loadImage(url, fallback: nil, owner: owner, generation: self.imageGeneration)
        }
        showExternalImageButton.retryWhenProxyRecovers(for: owner, retry: retry)
        showExternalImageButton.onTap = { [weak self] in
            guard let self else { return }
            ExternalImageConsent.present(for: url, owner: owner, from: self, shouldGrant: { [weak self] in
                guard let self else { return false }
                return self.window != nil && self.imageGeneration == generation && self.selectedImageView.isHidden
            }, onGranted: retry)
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
        showExternalImageButton.isHidden = true
    }
    
    func editModeDisabled() {
        selectedImageView.isHidden = true
        showExternalImageButton.isHidden = showExternalImageButton.onTap == nil
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
