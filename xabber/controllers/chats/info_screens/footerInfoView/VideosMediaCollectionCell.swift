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
import MaterialComponents.MDCPalettes
import Kingfisher
import CocoaLumberjack

class VideosMediaCollectionCell: UICollectionViewCell {
    static let cellName = "VideosMediaCollectionCell"
    var infoScreenDelegate: CellPhotoIsMissing? = nil
    
    let imageView: UIImageView = {
        let view = UIImageView()
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.borderColor = MDCPalette.grey.tint500.withAlphaComponent(0.2).cgColor
        view.layer.borderWidth = 0.5
        
        return view
    }()
    
    let videoPlayIconBackground: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.layer.cornerRadius = 24
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.cgColor
        
        return view
    }()
    
    let videoPlayIcon: UIImageView = {
        let view = UIImageView()
        view.image = imageLiteral( "play")?.withRenderingMode(.alwaysTemplate)
        view.tintColor = .white
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let videoDurationLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = .black.withAlphaComponent(0.5)
        label.font = .systemFont(ofSize: 12)
        
        return label
    }()
    
    let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView()
        indicator.style = .medium
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        
        return indicator
    }()
    
    let errorImageView: UIImageView = {
        let view = UIImageView()
        view.tintColor = MDCPalette.grey.tint300
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let selectedVideoView: UIImageView = {
        let view = UIImageView()
        view.image = nil
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        view.layer.borderColor = MDCPalette.grey.tint100.cgColor
        view.layer.masksToBounds = true
        
        view.isHidden = true
        return view
    }()
    
    let videoWithoutPreviewIcon: UIImageView = {
        let view = UIImageView()
        view.image = imageLiteral("file-video")?.withRenderingMode(.alwaysTemplate)
        view.tintColor = .white
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()
    
    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        selectedVideoView.removeFromSuperview()
    }
    
    internal func setup(videoCacheKey key: String?, videoDuration: String) {
        addSubview(imageView)
        addSubview(activityIndicator)
        imageView.addSubview(videoPlayIconBackground)
        imageView.addSubview(videoWithoutPreviewIcon)
        videoPlayIconBackground.addSubview(videoPlayIcon)
        imageView.addSubview(videoDurationLabel)
        imageView.addSubview(selectedVideoView)
        selectedVideoView.frame = CGRect(x: contentView.frame.width - 28, y: 4, width: 22, height: 22)
        selectedVideoView.layer.cornerRadius = selectedVideoView.frame.height / 2
        contentView.bringSubviewToFront(selectedVideoView)
        videoDurationLabel.text = videoDuration
        makeConstraints()
        imageView.layer.cornerRadius = 3
        if let key = key {
            setCellWithVideo(key: key)
        } else {
            setCellWithoutVideo(keyIsNotNil: false)
        }
    }
    
    internal func makeConstraints() {
        NSLayoutConstraint.activate([
            imageView.leftAnchor.constraint(equalTo: leftAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.rightAnchor.constraint(equalTo: rightAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            
            videoWithoutPreviewIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            videoWithoutPreviewIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            videoWithoutPreviewIcon.heightAnchor.constraint(equalToConstant: 32),
            videoWithoutPreviewIcon.widthAnchor.constraint(equalToConstant: 32),
            
            videoPlayIconBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            videoPlayIconBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            videoPlayIconBackground.heightAnchor.constraint(equalToConstant: 48),
            videoPlayIconBackground.widthAnchor.constraint(equalToConstant: 48),

            videoPlayIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            videoPlayIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            videoPlayIcon.heightAnchor.constraint(equalToConstant: 32),
            videoPlayIcon.widthAnchor.constraint(equalToConstant: 32),

            videoDurationLabel.rightAnchor.constraint(equalTo: rightAnchor),
            videoDurationLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoDurationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 35),
            videoDurationLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18)
        ])
    }
    
    internal func addVideoPreview(key: String) {
        ImageCache.default.retrieveImage(forKey: key) { result in
            switch result {
            case .success(let value):
                if value.image != nil {
                    self.imageView.image = value.image
                } else {
                    self.activateErrorImage()
//                    self.infoScreenDelegate?.passCellToFooter(cell: self)
                    DDLogDebug("PhotosMediaCollectionVell: \(#function). Error with video preview.")
                }
            case .failure(let value):
                self.activateErrorImage()
                self.infoScreenDelegate?.passCellToFooter(cell: self)
                DDLogDebug("PhotosMediaCollectionVell: \(#function). \(value.localizedDescription)")
            }
        }
    }
    
    private func setCellWithVideo(key: String) {
        activityIndicator.stopAnimating()
        videoPlayIconBackground.isHidden = false
        videoPlayIcon.isHidden = false
        addVideoPreview(key: key)
    }
    
    private func setCellWithoutVideo(keyIsNotNil: Bool = true) {
//        if !keyIsNotNil {
//            activityIndicator.startAnimating()
//            activityIndicator.isHidden = false
//        }
        if !keyIsNotNil {
            activityIndicator.stopAnimating()
            videoWithoutPreviewIcon.isHidden = false
        }
        videoPlayIconBackground.isHidden = true
        videoPlayIcon.isHidden = true
    }
    
    func activateErrorImage() {
        imageView.addSubview(errorImageView)
        errorImageView.image = imageLiteral( "video-off-outline")?.withRenderingMode(.alwaysTemplate)
        NSLayoutConstraint.activate([
            errorImageView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            errorImageView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            errorImageView.widthAnchor.constraint(equalToConstant: 24),
            errorImageView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    
    func editModeEnabled() {
        selectedVideoView.isHidden = false
    }
    
    func editModeDisabled() {
        selectedVideoView.isHidden = true
        deselect()
    }
    
    func select() {
        selectedVideoView.image = imageLiteral( "xabber.checkmark")
        selectedVideoView.tintColor = .systemBlue
        selectedVideoView.backgroundColor = .clear
    }
    
    func deselect() {
        selectedVideoView.image = nil
        selectedVideoView.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        selectedVideoView.layer.borderColor = MDCPalette.grey.tint100.cgColor
    }
}
