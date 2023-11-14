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
import Kingfisher
import CocoaLumberjack
import MaterialComponents.MDCPalettes

class PhotoGalleryCell: UICollectionViewCell {
    
    let errorImageView: UIImageView = {
        let view = UIImageView()
        view.tintColor = MDCPalette.grey.tint300.withAlphaComponent(0.75)
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let errorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = MDCPalette.grey.tint300
        label.font = UIFont.systemFont(ofSize: 18)
        label.text = "No image available".localizeString(id: "no_image_available", arguments: [])
        
        return label
    }()

//    var image:UIImage? {
//        didSet {
//            configureForNewImage(animated: false)
//        }
//    }

    var imageUrl: URL? {
        didSet {
            
        }
    }
    
    open var scrollView: UIScrollView
    public let imageView: UIImageView

    override init(frame: CGRect) {

        imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView = UIScrollView(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frame)
        var scrollViewConstraints: [NSLayoutConstraint] = []
        var imageViewConstraints: [NSLayoutConstraint] = []

        scrollViewConstraints.append(NSLayoutConstraint(item: scrollView,
                                                        attribute: .leading,
                                                        relatedBy: .equal,
                                                        toItem: contentView, 
                                                        attribute: .leading,
                                                        multiplier: 1,
                                                        constant: 0))

        scrollViewConstraints.append(NSLayoutConstraint(item: scrollView,
                                                        attribute: .top,
                                                        relatedBy: .equal,
                                                        toItem: contentView,
                                                        attribute: .top,
                                                        multiplier: 1,
                                                        constant: 0))

        scrollViewConstraints.append(NSLayoutConstraint(item: scrollView,
                                                        attribute: .trailing,
                                                        relatedBy: .equal,
                                                        toItem: contentView,
                                                        attribute: .trailing,
                                                        multiplier: 1,
                                                        constant: 0))

        scrollViewConstraints.append(NSLayoutConstraint(item: scrollView,
                                                        attribute: .bottom,
                                                        relatedBy: .equal,
                                                        toItem: contentView,
                                                        attribute: .bottom,
                                                        multiplier: 1,
                                                        constant: 0))

        contentView.addSubview(scrollView)
        contentView.addConstraints(scrollViewConstraints)

        imageViewConstraints.append(NSLayoutConstraint(item: imageView,
                                                       attribute: .leading,
                                                       relatedBy: .equal,
                                                       toItem: scrollView,
                                                       attribute: .leading,
                                                       multiplier: 1,
                                                       constant: 0))

        imageViewConstraints.append(NSLayoutConstraint(item: imageView,
                                                       attribute: .top,
                                                       relatedBy: .equal,
                                                       toItem: scrollView,
                                                       attribute: .top,
                                                       multiplier: 1,
                                                       constant: 0))

        imageViewConstraints.append(NSLayoutConstraint(item: imageView,
                                                       attribute: .trailing,
                                                       relatedBy: .equal,
                                                       toItem: scrollView,
                                                       attribute: .trailing,
                                                       multiplier: 1, 
                                                       constant: 0))

        imageViewConstraints.append(NSLayoutConstraint(item: imageView,
                                                       attribute: .bottom,
                                                       relatedBy: .equal,
                                                       toItem: scrollView,
                                                       attribute: .bottom,
                                                       multiplier: 1,
                                                       constant: 0))

        scrollView.addSubview(imageView)
        scrollView.addConstraints(imageViewConstraints)

        scrollView.delegate = self

        setupGestureRecognizer()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc public func doubleTapAction(recognizer: UITapGestureRecognizer) {

        if (scrollView.zoomScale > scrollView.minimumZoomScale) {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            scrollView.setZoomScale(scrollView.maximumZoomScale, animated: true)
        }
    }

    func configureForNewImageUrl(animated: Bool = true) {
        guard let url = imageUrl else { return }
        imageView.kf.indicatorType = .activity
        let resource = KF.ImageResource(downloadURL: url)
        ImageCache.default.retrieveImage(forKey: resource.cacheKey) { result in
            switch result {
            case .success(let value):
                if value.image != nil {
                    self.imageView.image = value.image
                    self.imageView.sizeToFit() //SIGABRT

                    self.setZoomScale()
                    self.scrollViewDidZoom(self.scrollView)
                } else {
                    self.activateErrorImage()
                }
            case .failure(let value):
                self.activateErrorImage()
                DDLogDebug("PhotoGalleryCell: \(#function). \(value.localizedDescription)")
            }
        }
        
//        imageView.kf.setImage(with: ImageResource(downloadURL: url)) {
//            (_) in
//            self.imageView.sizeToFit() //SIGABRT
//
//            self.setZoomScale()
//            self.scrollViewDidZoom(self.scrollView)
//        }
    }

    internal func setupGestureRecognizer() {

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapAction(recognizer:)))
        doubleTap.numberOfTapsRequired = 2
        self.addGestureRecognizer(doubleTap)
    }

    internal func setZoomScale() {
        let imageViewSize = imageView.bounds.size
        let scrollViewSize = scrollView.bounds.size
        let widthScale = scrollViewSize.width / imageViewSize.width
        let heightScale = scrollViewSize.height / imageViewSize.height

        scrollView.minimumZoomScale = min(widthScale, heightScale)
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
    }
    
    private func activateErrorImage() {
        imageView.addSubview(errorImageView)
        imageView.addSubview(errorLabel)
        errorImageView.image = #imageLiteral(resourceName: "badge-blocked").withRenderingMode(.alwaysTemplate)
        NSLayoutConstraint.activate([
            errorImageView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            errorImageView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            errorImageView.widthAnchor.constraint(equalToConstant: 48),
            errorImageView.heightAnchor.constraint(equalToConstant: 48),
            
            errorLabel.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: self.centerYAnchor, constant: 50)
        ])
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        errorImageView.removeFromSuperview()
        errorLabel.removeFromSuperview()
    }
}

extension PhotoGalleryCell: UIScrollViewDelegate {

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {

        let imageViewSize = imageView.frame.size
        let scrollViewSize = scrollView.bounds.size

        let verticalPadding = imageViewSize.height < scrollViewSize.height ? (scrollViewSize.height - imageViewSize.height) / 2 : 0
        let horizontalPadding = imageViewSize.width < scrollViewSize.width ? (scrollViewSize.width - imageViewSize.width) / 2 : 0

        if verticalPadding >= 0 {
            // Center the image on screen
            scrollView.contentInset = UIEdgeInsets(top: verticalPadding, left: horizontalPadding, bottom: verticalPadding, right: horizontalPadding)
        } else {
            // Limit the image panning to the screen bounds
            scrollView.contentSize = imageViewSize
        }
    }

}
