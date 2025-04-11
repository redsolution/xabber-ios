//
//  UIButton+Extension.swift
//  xabber
//
//  Created by Игорь Болдин on 29.05.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//
import Foundation
import UIKit

extension UIButton {
    private var imageView: UIImageView? {
        for subview in subviews {
            if let iv = subview as? UIImageView {
                return iv
            }
        }
        return nil
    }

    @available(iOS 17.0, *)
    func addSymbolEffect(_ effect: some IndefiniteSymbolEffect & SymbolEffect, options: SymbolEffectOptions = .default, animated: Bool = true, completion: UISymbolEffectCompletion? = nil) {
        imageView?.addSymbolEffect(effect, options: options, animated: animated, completion: completion)
    }
    
    @available(iOS 17.0, *)
    func addSymbolEffect(_ effect: some DiscreteSymbolEffect & IndefiniteSymbolEffect & SymbolEffect, options: SymbolEffectOptions = .default, animated: Bool = true, completion: UISymbolEffectCompletion? = nil) {
        imageView?.addSymbolEffect(effect, options: options, animated: animated, completion: completion)
    }
    
    @available(iOS 17.0, *)
    func addSymbolEffect(_ effect: some DiscreteSymbolEffect & SymbolEffect, options: SymbolEffectOptions = .default, animated: Bool = true, completion: UISymbolEffectCompletion? = nil) {
        imageView?.addSymbolEffect(effect, options: options, animated: animated, completion: completion)
    }
    
    @available(iOS 17.0, *)
    func removeSymbolEffect(ofType effect: some IndefiniteSymbolEffect & SymbolEffect, options: SymbolEffectOptions = .default, animated: Bool = true, completion: UISymbolEffectCompletion? = nil) {
        imageView!.removeSymbolEffect(ofType: effect, options: options, animated: animated, completion:  completion)
    }
    
    @available(iOS 17.0, *)
    func removeSymbolEffect(ofType effect: some DiscreteSymbolEffect & IndefiniteSymbolEffect & SymbolEffect, options: SymbolEffectOptions = .default, animated: Bool = true, completion: UISymbolEffectCompletion? = nil) {
        imageView!.removeSymbolEffect(ofType: effect, options: options, animated: animated, completion:  completion)
    }
    
    @available(iOS 17.0, *)
    func removeSymbolEffect(ofType effect: some DiscreteSymbolEffect & SymbolEffect, options: SymbolEffectOptions = .default, animated: Bool = true, completion: UISymbolEffectCompletion? = nil) {
        imageView!.removeSymbolEffect(ofType: effect, options: options, animated: animated, completion:  completion)
    }
    
    @available(iOS 17.0, *)
    func removeAllSymbolEffects(options: SymbolEffectOptions = .default, animated: Bool = true) {
        imageView!.removeAllSymbolEffects(options: options, animated: animated)
    }
    
    @available(iOS 17.0, *)
    func setSymbolImage(image: UIImage, contentTransition: some ContentTransitionSymbolEffect & SymbolEffect, options: SymbolEffectOptions = .nonRepeating, completion: UISymbolEffectCompletion? = nil) {
        imageView!.setSymbolImage(image, contentTransition: contentTransition, options: options, completion: completion)
    }
}
