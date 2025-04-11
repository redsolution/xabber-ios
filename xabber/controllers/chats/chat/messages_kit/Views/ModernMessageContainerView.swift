//
//  ModernMessageContainerView.swift
//  xabber
//
//  Created by Игорь Болдин on 19.02.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//
import Foundation
import UIKit

open class ModernContainerView: UIView {
    var radius1: CGFloat = 16
    var radius2: CGFloat = 16
    var radius3: CGFloat = 2
    var radius4: CGFloat = 16
    var side: MessageSide = .left
    
    static let padding: CGFloat = 0
    
    func setup() {
        
    }
    
    public final func configure(side: MessageSide, radiusLU: CGFloat = 8, radiusRU: CGFloat = 8, radiusRB: CGFloat = 2, radiusLB: CGFloat = 8) {
        self.radius1 = [radiusLU - ModernContainerView.padding, 2.0].max() ?? 2
        self.radius2 = [radiusRU - ModernContainerView.padding, 2.0].max() ?? 2
//        if side == .right {
        self.radius3 = [radiusRB - ModernContainerView.padding, 2.0].max() ?? 2
        self.radius4 = [radiusLB - ModernContainerView.padding, 2.0].max() ?? 2
//        } else {
//            self.radius4 = [radiusRB - ModernContainerView.padding, 2.0].max() ?? 2
//            self.radius3 = [radiusLB - ModernContainerView.padding, 2.0].max() ?? 2
//        }
        self.transform = CGAffineTransformIdentity
        self.setupBackground()
    }
    
    func drawPath() -> UIBezierPath {
        let width = frame.width
        let height = frame.height
        let path = UIBezierPath()
        
        path.move(to: CGPoint(x: radius1, y: 0))
        
        path.addLine(to: CGPoint(x: width - radius2, y: 0))
        path.addQuadCurve(to: CGPoint(x: width, y: radius2), controlPoint: CGPoint(x: width, y: 0))
        
        path.addLine(to: CGPoint(x: width, y: height - radius3))
        path.addQuadCurve(to: CGPoint(x: width - radius3, y: height), controlPoint: CGPoint(x: width, y: height))
        
            
        path.addLine(to: CGPoint(x: radius4, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - radius4), controlPoint: CGPoint(x: 0, y: height))
        
        
        path.addLine(to: CGPoint(x: 0, y: radius1))
        path.addQuadCurve(to: CGPoint(x: radius1, y: 0), controlPoint: CGPoint(x: 0, y: 0))
        path.close()
        path.fill()
        
        return path
    }
    
    func setupBackground() {
        let path = self.drawPath()
        let mask = CAShapeLayer()
        mask.fillColor = UIColor.black.cgColor
        mask.strokeColor = UIColor.white.cgColor
        mask.path = path.cgPath
        mask.lineWidth = 0.0
        
        self.layer.mask = mask
        self.layer.masksToBounds = true
        self.setNeedsLayout()
    }
}

open class ModernMessageContainerView: UIView {
    
    var radius1: CGFloat = 16
    var radius2: CGFloat = 16
    var radius3: CGFloat = 2
    var radius4: CGFloat = 16
    var paddingr: CGFloat = 8
    var tail: String = "none"
    var side: MessageSide = .left
    var topCorner: Bool = false
    
    internal let bubble: UIView = {
        let view = UIView(frame: .zero)
        
        return view
    }()
    
    
    func setup() {
        self.bubble.removeFromSuperview()
        self.addSubview(self.bubble)
        self.bubble.frame = self.bounds
    }
    
    public final func configure(tail: String, side: MessageSide, radiusLU: CGFloat = 8, radiusRU: CGFloat = 8, radiusRB: CGFloat = 2, radiusLB: CGFloat = 8, padding: CGFloat = 8, topCorner: Bool = false) {
        self.tail = tail
        self.side = side
        self.radius1 = radiusLU
        self.radius2 = radiusRU
        self.radius3 = radiusRB
        self.radius4 = radiusLB
        self.paddingr = padding
        self.topCorner = topCorner
        self.setupBackground()
    }
    
    func setupBackground() {
        self.bubble.layer.mask = nil
        self.bubble.frame = self.bounds
        let path = self.drawPath()
        let mask = CAShapeLayer()
        mask.fillColor = UIColor.black.cgColor
        mask.strokeColor = UIColor.white.cgColor
        mask.path = path.cgPath
        mask.lineWidth = 0.0
        
        let tailPath: CGPath? = drawTail(name: self.tail)
        
        if let tailPath = tailPath {
            let submask = CAShapeLayer()
            submask.fillColor = UIColor.black.cgColor
            submask.strokeColor = UIColor.white.cgColor
            submask.path = tailPath
            submask.lineWidth = 0.0
            mask.addSublayer(submask)
        }
        self.bubble.layer.mask = mask
        self.bubble.layer.masksToBounds = true
//        self.bubble.layer.backgroundColor = side == .left ? UIColor.systemRed.cgColor : UIColor.systemBlue.cgColor
        self.bubble.layer.backgroundColor = side == .left ? UIColor(red: 227.0 / 255.0, green: 242.0 / 255.0, blue: 253.0 / 255.0, alpha: 1).cgColor : UIColor.white.cgColor
        if side == .left {
            if topCorner {
                self.bubble.transform = CGAffineTransform(scaleX: -1, y: -1)
                self.transform = CGAffineTransform(scaleX: 1, y: 1)
            } else {
                self.bubble.transform = CGAffineTransform(scaleX: -1, y: 1)
                self.transform = CGAffineTransform(scaleX: 1, y: 1)
            }
            
        } else {
            if topCorner {
                self.bubble.transform = CGAffineTransform(scaleX: 1, y: -1)
                self.transform = CGAffineTransform(scaleX: 1, y: 1)
            } else {
                self.bubble.transform = CGAffineTransformIdentity
                self.transform = CGAffineTransformIdentity
            }
        }
        
        self.bubble.setNeedsLayout()
        self.setNeedsLayout()
    }
        
    func drawTail(name: String) -> CGPath? {
        let st = CGSize(width: frame.width - 14, height: frame.height - 14)
        switch name {
            case "stripes":
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 9.0, y: 5.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 10.0, y: 6.0).offset(by: st), controlPoint1: CGPoint(x: 9.55228475, y: 5.0).offset(by: st), controlPoint2: CGPoint(x: 10.0, y: 5.44771525).offset(by: st))
                path.addLine(to: CGPoint(x: 10.0, y: 13.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 9.0, y: 14.0).offset(by: st), controlPoint1: CGPoint(x: 10.0, y: 13.5522847).offset(by: st), controlPoint2: CGPoint(x: 9.55228475, y: 14.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 8.0, y: 13.0).offset(by: st), controlPoint1: CGPoint(x: 8.44771525, y: 14.0).offset(by: st), controlPoint2: CGPoint(x: 8.0, y: 13.5522847).offset(by: st))
                path.addLine(to: CGPoint(x: 8.0, y: 6.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 9.0, y: 5.0).offset(by: st), controlPoint1: CGPoint(x: 8.0, y: 5.44771525).offset(by: st), controlPoint2: CGPoint(x: 8.44771525, y: 5.0).offset(by: st))
                path.move(to: CGPoint(x: 13.0, y: 9.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 14.0, y: 10.0).offset(by: st), controlPoint1: CGPoint(x: 13.5522847, y: 9.0).offset(by: st), controlPoint2: CGPoint(x: 14.0, y: 9.44771525).offset(by: st))
                path.addLine(to: CGPoint(x: 14.0, y: 13.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 13.0, y: 14.0).offset(by: st), controlPoint1: CGPoint(x: 14.0, y: 13.5522847).offset(by: st), controlPoint2: CGPoint(x: 13.5522847, y: 14.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 12.0, y: 13.0).offset(by: st), controlPoint1: CGPoint(x: 12.4477153, y: 14.0).offset(by: st), controlPoint2: CGPoint(x: 12.0, y: 13.5522847).offset(by: st))
                path.addLine(to: CGPoint(x: 12.0, y: 10.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 13.0, y: 9.0).offset(by: st), controlPoint1: CGPoint(x: 12.0, y: 9.44771525).offset(by: st), controlPoint2: CGPoint(x: 12.4477153, y: 9.0).offset(by: st))
                
                return path.cgPath
            case "transparent":
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 10.8795676, y: 7.40257451).offset(by: st))
                path.addCurve(to: CGPoint(x: 14.0, y: 10.7).offset(by: st), controlPoint1: CGPoint(x: 12.6144291, y: 7.47163811).offset(by: st), controlPoint2: CGPoint(x: 14.0, y: 8.92152097).offset(by: st))
                path.addCurve(to: CGPoint(x: 10.75, y: 14.0).offset(by: st), controlPoint1: CGPoint(x: 14.0, y: 12.5225397).offset(by: st), controlPoint2: CGPoint(x: 12.5449254, y: 14.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 8.43073123, y: 13.0117563).offset(by: st), controlPoint1: CGPoint(x: 9.84171842, y: 14.0).offset(by: st), controlPoint2: CGPoint(x: 9.02046034, y: 13.6216759).offset(by: st))
                path.addCurve(to: CGPoint(x: 11.0, y: 8.5).offset(by: st), controlPoint1: CGPoint(x: 9.98455362, y: 12.0177407).offset(by: st), controlPoint2: CGPoint(x: 11.0, y: 10.3675734).offset(by: st))
                path.addCurve(to: CGPoint(x: 10.8942743, y: 7.46667989).offset(by: st), controlPoint1: CGPoint(x: 11.0, y: 8.14679464).offset(by: st), controlPoint2: CGPoint(x: 10.9636791, y: 7.80136553).offset(by: st))
                path.addLine(to: CGPoint(x: 10.8795676, y: 7.40257451).offset(by: st))
                return path.cgPath
            case "bubbles":
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 12.5, y: 11.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 14.0, y: 12.5).offset(by: st), controlPoint1: CGPoint(x: 13.3284271, y: 11.0).offset(by: st), controlPoint2: CGPoint(x: 14.0, y: 11.6715729).offset(by: st))
                path.addCurve(to: CGPoint(x: 12.5, y: 14.0).offset(by: st), controlPoint1: CGPoint(x: 14.0, y: 13.3284271).offset(by: st), controlPoint2: CGPoint(x: 13.3284271, y: 14.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 11.0, y: 12.5).offset(by: st), controlPoint1: CGPoint(x: 11.6715729, y: 14.0).offset(by: st), controlPoint2: CGPoint(x: 11.0, y: 13.3284271).offset(by: st))
                path.addCurve(to: CGPoint(x: 12.5, y: 11.0).offset(by: st), controlPoint1: CGPoint(x: 11.0, y: 11.6715729).offset(by: st), controlPoint2: CGPoint(x: 11.6715729, y: 11.0).offset(by: st))
                path.move(to: CGPoint(x: 9.0, y: 7.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 11.5, y: 9.5).offset(by: st), controlPoint1: CGPoint(x: 10.3807119, y: 7.0).offset(by: st), controlPoint2: CGPoint(x: 11.5, y: 8.11928813).offset(by: st))
                path.addCurve(to: CGPoint(x: 9.0, y: 12.0).offset(by: st), controlPoint1: CGPoint(x: 11.5, y: 10.8807119).offset(by: st), controlPoint2: CGPoint(x: 10.3807119, y: 12.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 6.5, y: 9.5).offset(by: st), controlPoint1: CGPoint(x: 7.61928813, y: 12.0).offset(by: st), controlPoint2: CGPoint(x: 6.5, y: 10.8807119).offset(by: st))
                path.addCurve(to: CGPoint(x: 9.0, y: 7.0).offset(by: st), controlPoint1: CGPoint(x: 6.5, y: 8.11928813).offset(by: st), controlPoint2: CGPoint(x: 7.61928813, y: 7.0).offset(by: st))
                return path.cgPath
            case "smooth":
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0.0, y: 8.0).offset(by: st))
                path.addLine(to: CGPoint(x: 6.0, y: 14.0).offset(by: st))
                path.addLine(to: CGPoint(x: 14.0, y: 14.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 5.95, y: 2.0).offset(by: st), controlPoint1: CGPoint(x: 10.0, y: 12.0).offset(by: st), controlPoint2: CGPoint(x: 5.95, y: 8.0).offset(by: st))
                path.addLine(to: CGPoint(x: 0.0, y: 2.0).offset(by: st))
                path.addLine(to: CGPoint(x: 0.0, y: 8.0).offset(by: st))
                return path.cgPath
            case "curvy":
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 14.0, y: 13.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 5.95, y: 0.0).offset(by: st), controlPoint1: CGPoint(x: 7.0, y: 9.0).offset(by: st), controlPoint2: CGPoint(x: 5.95, y: 4.0).offset(by: st))
                path.addLine(to: CGPoint(x: 0.0, y: 0.0).offset(by: st))
                path.addLine(to: CGPoint(x: 0.0, y: 9.0).offset(by: st))
                path.addCurve(to: CGPoint(x: 14.0, y: 13.0).offset(by: st), controlPoint1: CGPoint(x: 4.0, y: 12.0).offset(by: st), controlPoint2: CGPoint(x: 7.0, y: 13.0).offset(by: st))
                path.close()
                return path.cgPath
            default:
                return nil
        }
    }
    
    func drawPath() -> UIBezierPath {
        let width = frame.width
        let height = frame.height
        let padding: CGFloat = 0
        let paddingR: CGFloat = paddingr
        let path = UIBezierPath()
        
        path.move(to: CGPoint(x: padding + radius1, y: 0))
        
        path.addLine(to: CGPoint(x: width - radius2 - paddingR, y: 0))
        path.addQuadCurve(to: CGPoint(x: width - paddingR, y: radius2), controlPoint: CGPoint(x: width - paddingR, y: 0))
        
        path.addLine(to: CGPoint(x: width - paddingR, y: height - radius3))
        path.addQuadCurve(to: CGPoint(x: width - radius3 - paddingR, y: height), controlPoint: CGPoint(x: width - paddingR, y: height))
        
            
        path.addLine(to: CGPoint(x: padding + radius4, y: height))
        path.addQuadCurve(to: CGPoint(x: padding, y: height - radius4), controlPoint: CGPoint(x: padding, y: height))
        
        
        path.addLine(to: CGPoint(x: padding, y: radius1))
        path.addQuadCurve(to: CGPoint(x: padding + radius1, y: 0), controlPoint: CGPoint(x: padding, y: 0))
        path.close()
        path.fill()
        
        return path
    }
    
    
}
