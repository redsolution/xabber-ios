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

class PrivacyBlurredViewController: UIViewController {
    let blurredView: UIImageView = {
        let view = UIImageView()
        
        view.contentMode = .scaleToFill
        view.alpha = 0.0
        return view
    }()
    
    private final func blur(_ image: UIImage) -> UIImage? {
        let radius: CGFloat = 8
        let context = CIContext(options: nil)
        let inputImage = CIImage(cgImage: image.cgImage!)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(inputImage, forKey: kCIInputImageKey)
        filter?.setValue("\(radius)", forKey:kCIInputRadiusKey)
        let result = filter?.value(forKey: kCIOutputImageKey) as! CIImage
        let rect =  CGRect(x: radius * 2, y: radius * 2, width: image.size.width - radius * 4, height: image.size.height - radius * 4)
        guard let cgImage = context.createCGImage(result, from: rect) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
    
    public final func configure(_ image: UIImage) {
        if let blurred = self.blur(image.resize(targetSize: view.bounds.size)) {
            blurredView.image = blurred
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        blurredView.frame = view.bounds
        view.addSubview(blurredView)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIView.animate(withDuration: 0.18, delay: 0.0, options: [.curveEaseInOut]) {
            self.blurredView.alpha = 1.0
        } completion: { _ in
            
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIView.animate(withDuration: 0.2, delay: 0.0, options: [.curveEaseInOut]) {
            self.blurredView.alpha = 0.0
        } completion: { _ in
            
        }
    }
    
}
