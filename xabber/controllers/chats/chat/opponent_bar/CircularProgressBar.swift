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

// MARK: - KYCircularProgress
@IBDesignable
open class CircularProgressBar: UIView {
    
    /**
     Current progress value. (0.0 - 1.0)
     */
    @IBInspectable open var progress: Double = 0.0 {
        didSet {
            let clipProgress = max( min( progress, 1.0), 0.0 )
            progressView.update(progress: normalize(progress: clipProgress))
            
            progressChanged?(clipProgress, self)
            delegate?.progressChanged(progress: clipProgress, circularProgress: self)
        }
    }
    
    /**
     Main progress line width.
     */
    @IBInspectable open var lineWidth: Double = 8.0 {
        didSet {
            progressView.shapeLayer.lineWidth = CGFloat(lineWidth)
        }
    }
  
    /**
     Progress bar line cap. The cap style used when stroking the path.
     */
    @IBInspectable open var lineCap: String = CAShapeLayerLineCap.butt.rawValue {
        didSet {
            progressView.shapeLayer.lineCap = CAShapeLayerLineCap(rawValue: lineCap)
        }
    }
  
    /**
     Guide progress line width.
     */
    @IBInspectable open var guideLineWidth: Double = 2.0 {
        didSet {
            guideView.shapeLayer.lineWidth = CGFloat(guideLineWidth)
        }
    }
    
    /**
     Progress guide bar color.
     */
    @IBInspectable open var guideColor: UIColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.2) {
        didSet {
            guideLayer.backgroundColor = guideColor.cgColor
        }
    }
    
    /**
     Switch of progress guide view. If you set to `true`, progress guide view is enabled.
     */
    @IBInspectable open var showGuide: Bool = false {
        didSet {
            guideView.isHidden = !showGuide
            guideLayer.backgroundColor = showGuide ? guideColor.cgColor : UIColor.clear.cgColor
        }
    }
    
    private var allowBarAnimation: Bool = false
    
    /**
     Progress bar path. You can create various type of progress bar.
     */
    open var path: UIBezierPath? {
        didSet {
            progressView.shapeLayer.path = path?.cgPath
            guideView.shapeLayer.path = path?.cgPath
        }
    }
    
    /**
     Progress bar colors. You can set many colors in `colors` property, and it makes gradation color in `colors`.
     */
    open var colors: [UIColor] = [] {
        didSet {
            update(colors: colors)
        }
    }
    
    /**
     Progress start offset. (0.0 - 1.0)
     */
    @IBInspectable open var strokeStart: Double = 0.0 {
        didSet {
            progressView.shapeLayer.strokeStart = CGFloat(max( min(strokeStart, 1.0), 0.0 ))
            guideView.shapeLayer.strokeStart = CGFloat(max( min(strokeStart, 1.0), 0.0 ))
        }
    }
    
    /**
     Progress end offset. (0.0 - 1.0)
     */
    @IBInspectable open var strokeEnd: Double = 1.0 {
        didSet {
            progressView.shapeLayer.strokeEnd = CGFloat(max( min(strokeEnd, 1.0), 0.0 ))
            guideView.shapeLayer.strokeEnd = CGFloat(max( min(strokeEnd, 1.0), 0.0 ))
        }
    }
  
    open var delegate: CircularProgressBarDelegate?
    
    /**
    Typealias of progressChangedClosure.
    */
    public typealias progressChangedHandler = (_ progress: Double, _ circularProgress: CircularProgressBar) -> Void
    
    /**
    This closure is called when set value to `progress` property.
    */
    private var progressChanged: progressChangedHandler?
    
    /**
    Main progress view.
    */
    private lazy var progressView: CircularShapeView = {
        let progressView = CircularShapeView(frame: self.bounds)
        progressView.shapeLayer.fillColor = UIColor.clear.cgColor
        progressView.shapeLayer.lineWidth = CGFloat(self.lineWidth)
        progressView.shapeLayer.lineCap = CAShapeLayerLineCap(rawValue: self.lineCap)
        progressView.radius = self.radius
        progressView.shapeLayer.path = self.path?.cgPath
        progressView.shapeLayer.strokeColor = self.tintColor.cgColor
        return progressView
    }()
    
    /**
    Gradient mask layer of `progressView`.
    */
    public lazy var progressLayer: CAGradientLayer = {
        let progressLayer = CAGradientLayer(layer: self.layer)
        progressLayer.frame = self.progressView.frame
        progressLayer.startPoint = CGPoint(x: 0, y: 0.5)
        progressLayer.endPoint = CGPoint(x: 1, y: 0.5)
        progressLayer.mask = self.progressView.shapeLayer
        progressLayer.colors = self.colors
        progressLayer.type = .axial
        self.layer.addSublayer(progressLayer)
        return progressLayer
    }()
    
    /**
    Guide view of `progressView`.
    */
    private lazy var guideView: CircularShapeView = {
        let guideView = CircularShapeView(frame: self.bounds)
        guideView.shapeLayer.fillColor = UIColor.clear.cgColor
        guideView.shapeLayer.lineWidth = CGFloat(self.guideLineWidth)
        guideView.radius = self.radius
        self.progressView.radius = self.radius
        guideView.shapeLayer.path = self.progressView.shapeLayer.path
        guideView.shapeLayer.strokeColor = self.tintColor.cgColor
        guideView.update(progress: normalize(progress: 1.0))
        return guideView
    }()
    
    /**
    Mask layer of `progressGuideView`.
    */
    private lazy var guideLayer: CALayer = {
        let guideLayer = CAGradientLayer(layer: self.layer)
        guideLayer.frame = self.guideView.frame
        guideLayer.mask = self.guideView.shapeLayer
        guideLayer.backgroundColor = self.guideColor.cgColor
        guideLayer.zPosition = -1
        self.layer.addSublayer(guideLayer)
        return guideLayer
    }()
    
    private var radius: Double {
        return lineWidth >= guideLineWidth ? lineWidth : guideLineWidth
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        
        setNeedsLayout()
        layoutIfNeeded()
        
        update(colors: colors)
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        
        setNeedsLayout()
        layoutIfNeeded()
    }
    
    /**
    Create `KYCircularProgress` with progress guide.
    
    - parameter frame: `KYCircularProgress` frame.
    - parameter showProgressGuide: If you set to `true`, progress guide view is enabled.
    */
    public init(frame: CGRect, showGuide: Bool) {
        super.init(frame: frame)
        self.showGuide = showGuide
        guideLayer.backgroundColor = showGuide ? guideColor.cgColor : UIColor.clear.cgColor
    }

    private final func rotateProgressView() {
        UIView.animate(withDuration: 2, delay: 0, options: .curveLinear, animations: {
            self.progressView.transform = self.progressView.transform.rotated(by: .pi )
        }) { result in
            if self.allowBarAnimation {
                self.rotateProgressView()
            }
        }
    }
    
    public final func startAnimation() {
        self.allowBarAnimation = true
        self.rotateProgressView()
    }
    
    public final func stopAnimation() {
        self.allowBarAnimation = false
        self.allowBarAnimation = false
        UIView.animate(withDuration: 2, delay: 0, options: .curveLinear, animations: {
            self.progressView.transform = self.progressView.transform.rotated(by: .pi )
//            self.progressLayer.setAffineTransform(self.progressLayer.affineTransform().rotated(by: .pi))
        }) { result in
            
        }
    }
    
    /**
    This closure is called when set value to `progress` property.
    
    - parameter completion: progress changed closure.
    */
    open func progressChanged(completion: @escaping progressChangedHandler) {
        progressChanged = completion
    }

    public func set(progress: Double, duration: Double) {
        let clipProgress = max( min(progress, 1.0), 0.0 )
        progressView.update(progress: normalize(progress: clipProgress), duration: duration)
        
        progressChanged?(clipProgress, self)
        delegate?.progressChanged(progress: clipProgress, circularProgress: self)
    }
    
    private func update(colors: [UIColor]) {
        progressLayer.colors = colors.map {$0.cgColor}
        if colors.count == 1 {
            progressLayer.colors?.append(colors.first!.cgColor)
        }
    }
    
    private func normalize(progress: Double) -> CGFloat {
        return CGFloat(strokeStart + progress * (strokeEnd - strokeStart))
    }
    
    override open func layoutSubviews() {
        super.layoutSubviews()
        
//        let lineHalf = CGFloat(lineWidth / 2)
//        progressView.scale = (x: (bounds.width - lineHalf) / progressView.frame.width, y: (bounds.height - lineHalf) / progressView.frame.height)
//        progressView.frame = CGRect(x: bounds.origin.x + lineHalf, y: bounds.origin.y + lineHalf, width: bounds.width - lineHalf, height: bounds.height - lineHalf)
        progressView.frame = bounds
        progressLayer.frame = bounds
        guideView.scale = progressView.scale
        guideView.frame = progressView.frame
        guideLayer.frame = bounds
    }
}

public protocol CircularProgressBarDelegate {
    func progressChanged(progress: Double, circularProgress: CircularProgressBar)
}

// MARK: - KYCircularShapeView
class CircularShapeView: UIView {
    var radius = 0.0
    var scale: (x: CGFloat, y: CGFloat) = (1.0, 1.0)
    
    override class var layerClass : AnyClass {
        return CAShapeLayer.self
    }
    
    var shapeLayer: CAShapeLayer {
        return layer as! CAShapeLayer
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        update(progress: 0)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        shapeLayer.path = shapeLayer.path ?? layoutPath().cgPath
        var affineScale = CGAffineTransform(scaleX: scale.x, y: scale.y)
        shapeLayer.path = shapeLayer.path?.copy(using: &affineScale)
    }
    
    private func layoutPath() -> UIBezierPath {
        let halfWidth = CGFloat(frame.width / 2.0)
        return UIBezierPath(arcCenter: CGPoint(x: halfWidth, y: halfWidth), radius: (frame.width - CGFloat(radius)) / 2, startAngle: 0, endAngle: CGFloat(Double.pi * 2), clockwise: true)
    }
    
    fileprivate func update(progress: CGFloat) {
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        shapeLayer.strokeEnd = progress
        CATransaction.commit()
    }
    
    fileprivate func update(progress: CGFloat, duration: Double) {
        CATransaction.begin()
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.duration = duration
        animation.isRemovedOnCompletion = false
        animation.fromValue = shapeLayer.presentation()?.value(forKeyPath: "strokeEnd") as? CGFloat
        animation.toValue = progress
        shapeLayer.add(animation, forKey: "animateStrokeEnd")
        CATransaction.commit()
        shapeLayer.strokeEnd = progress
    }
}
