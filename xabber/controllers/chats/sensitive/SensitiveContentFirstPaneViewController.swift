//
//  SensitiveContentFirstPaneViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 17.02.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//
import Foundation
import UIKit

protocol SensitiveContentFirstPaneViewControllerDelegate {
    func onViewGallery(messagePrimary: String, urls: [URL], url: URL)
}

class SensitiveContentFirstPaneViewController: SimpleBaseViewController {
    internal let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.distribution = .fill
        stack.alignment = .center
        stack.spacing = 16
        
        return stack
    }()
    
    internal let contentStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.distribution = .fill
        stack.alignment = .center
        
        return stack
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(contentStack)
        contentStack.fillSuperview()
        contentStack.addArrangedSubview(stack)
    }

    open var isFirstStep: Bool = true
    
    override func configure() {
        super.configure()
        if isFirstStep {
            configure_first_step()
        } else {
            configure_second_step()
        }
    }
    
    open var delegate: SensitiveContentFirstPaneViewControllerDelegate? = nil
    open var urls: [URL] = []
    open var url: URL?
    open var messagePrimary: String = ""
    
    private func configure_first_step() {
        let imageView = UIImageView(image: "🤔".image(fontSize: 48, bgColor: .systemBackground, imageSize: CGSize(square: 64)))
        stack.addArrangedSubview(imageView)
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .largeTitle)
        label.text = "This could be sensitive\nAre you sure you want to view?"
        stack.addArrangedSubview(label)
        let substack1 = UIStackView()
        let substack2 = UIStackView()
        [substack1, substack2].forEach {
            stack in
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.spacing = 0
            stack.alignment = .center
        }
        let imageView1 = UIImageView(image: "🙈".image(fontSize: 24, bgColor: .systemBackground, imageSize: CGSize(square: 48)))
        let imageView2 = UIImageView(image: "🌄".image(fontSize: 24, bgColor: .systemBackground, imageSize: CGSize(square: 48)))
        let label1 = UILabel()
        label1.numberOfLines = 0
        label1.text = "Nude photos and videos can be used to hurt people. Once you view this, you can`t unsee it"
        let label2 = UILabel()
        label2.numberOfLines = 0
        label2.text = "The person in this may not have given consent to share it. How would they feel knowing other people saw it?"
        
        substack1.addArrangedSubview(imageView1)
        substack1.addArrangedSubview(label1)
        substack2.addArrangedSubview(imageView2)
        substack2.addArrangedSubview(label2)
        
        stack.addArrangedSubview(substack1)
        stack.addArrangedSubview(substack2)
        
        stack.setCustomSpacing(32, after: label)
        
        var cancelButtonConf = UIButton.Configuration.filled()
        cancelButtonConf.title = "Not Now"
        cancelButtonConf.buttonSize = .large
        cancelButtonConf.titleAlignment = .center
        var helpConfiguration = UIButton.Configuration.plain()
        helpConfiguration.title = "Ways to Get Help"
        helpConfiguration.buttonSize = .large
        helpConfiguration.titleAlignment = .center
        var continueConfiguration = UIButton.Configuration.plain()
        continueConfiguration.title = "I`m Sure"
        continueConfiguration.buttonSize = .large
        continueConfiguration.titleAlignment = .center
        
        let cancelButton = UIButton(configuration: cancelButtonConf, primaryAction: nil)
        cancelButton.addTarget(self, action: #selector(cancelButtonTouchUpInside), for: .touchUpInside)
        let helpButton = UIButton(configuration: helpConfiguration)
        helpButton.addTarget(self, action: #selector(helpButtonTouchUpInside), for: .touchUpInside)
        let continueButton = UIButton(configuration: continueConfiguration)
        continueButton.addTarget(self, action: #selector(continueButtonTouchUpInside), for: .touchUpInside)
        stack.addArrangedSubview(UIStackView())
        stack.addArrangedSubview(cancelButton)
//        stack.addArrangedSubview(helpButton)
        stack.addArrangedSubview(continueButton)
        
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: stack.topAnchor, constant: 48),
            imageView.widthAnchor.constraint(equalToConstant: 128),
            imageView.heightAnchor.constraint(equalToConstant: 128),
            imageView1.widthAnchor.constraint(equalToConstant: 48),
            imageView2.widthAnchor.constraint(equalToConstant: 48),
            substack1.widthAnchor.constraint(equalTo: stack.widthAnchor),
            substack2.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
//            helpButton.heightAnchor.constraint(equalToConstant: 44),
            continueButton.heightAnchor.constraint(equalToConstant: 44),
            cancelButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
//            helpButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            continueButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: continueButton.topAnchor),
//            helpButton.bottomAnchor.constraint(equalTo: continueButton.topAnchor),
            continueButton.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 0),
        ])
    }
    
    private func configure_second_step() {
        let imageView = UIImageView(image: "🧐".image(fontSize: 48, bgColor: .systemBackground, imageSize: CGSize(square: 64)))
        stack.addArrangedSubview(imageView)
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .largeTitle)
        label.text = "It`s your choice, but make sure you feel safe."
        stack.addArrangedSubview(label)
        let substack1 = UIStackView()
        let substack2 = UIStackView()
        [substack1, substack2].forEach {
            stack in
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.spacing = 0
        }
        let imageView1 = UIImageView(image: "👯‍♀️".image(fontSize: 24, bgColor: .systemBackground, imageSize: CGSize(square: 48)))
        let imageView2 = UIImageView(image: "🙊".image(fontSize: 24, bgColor: .systemBackground, imageSize: CGSize(square: 48)))
        let label1 = UILabel()
        label1.numberOfLines = 0
        label1.text = "Don`t share anything you don`t want to. Talk to someone you trust if you feel pressured to view naked photos or videos."
        let label2 = UILabel()
        label2.numberOfLines = 0
        label2.text = "Do you feel OK? You`re not alone, and can alwaus talk with someone who`s trained to help."
        
        substack1.addArrangedSubview(imageView1)
        substack1.addArrangedSubview(label1)
        substack2.addArrangedSubview(imageView2)
        substack2.addArrangedSubview(label2)
        
        stack.addArrangedSubview(substack1)
        stack.addArrangedSubview(substack2)
        
        stack.setCustomSpacing(32, after: label)
        
        var cancelButtonConf = UIButton.Configuration.filled()
        cancelButtonConf.title = "Don`t view"
        cancelButtonConf.buttonSize = .large
        cancelButtonConf.titleAlignment = .center
        var helpConfiguration = UIButton.Configuration.plain()
        helpConfiguration.title = "Message someone"
        helpConfiguration.buttonSize = .large
        helpConfiguration.titleAlignment = .center
        var continueConfiguration = UIButton.Configuration.plain()
        continueConfiguration.title = "View"
        continueConfiguration.buttonSize = .large
        continueConfiguration.titleAlignment = .center
        
        let cancelButton = UIButton(configuration: cancelButtonConf, primaryAction: nil)
        cancelButton.addTarget(self, action: #selector(cancelButtonTouchUpInside), for: .touchUpInside)
        let helpButton = UIButton(configuration: helpConfiguration)
        helpButton.addTarget(self, action: #selector(helpButtonTouchUpInside), for: .touchUpInside)
        let continueButton = UIButton(configuration: continueConfiguration)
        continueButton.addTarget(self, action: #selector(continueButtonTouchUpInside), for: .touchUpInside)
        
        stack.addArrangedSubview(UIStackView())
        stack.addArrangedSubview(cancelButton)
//        stack.addArrangedSubview(helpButton)
        stack.addArrangedSubview(continueButton)
        
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: stack.topAnchor, constant: 48),
            imageView.widthAnchor.constraint(equalToConstant: 128),
            imageView.heightAnchor.constraint(equalToConstant: 128),
            imageView1.widthAnchor.constraint(equalToConstant: 48),
            imageView2.widthAnchor.constraint(equalToConstant: 48),
            substack1.widthAnchor.constraint(equalTo: stack.widthAnchor),
            substack2.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
//            helpButton.heightAnchor.constraint(equalToConstant: 44),
            continueButton.heightAnchor.constraint(equalToConstant: 44),
            cancelButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
//            helpButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            continueButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: continueButton.topAnchor),
//            helpButton.bottomAnchor.constraint(equalTo: continueButton.topAnchor),
            continueButton.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 0),
        ])
    }
    
    @objc
    private func cancelButtonTouchUpInside(_ sender: UIButton) {
        self.dismiss(animated: true)
    }
    
    @objc
    private func helpButtonTouchUpInside(_ sender: UIButton) {
        
    }
    
    
    
    @objc
    private func continueButtonTouchUpInside(_ sender: UIButton) {
        if self.isFirstStep {
            let vc = SensitiveContentFirstPaneViewController()
            vc.isFirstStep = false
            vc.delegate = self.delegate
            vc.url = self.url
            vc.urls = self.urls
            vc.messagePrimary = self.messagePrimary
            self.navigationController?.pushViewController(vc, animated: true)
        } else {
            self.dismiss(animated: true) {
                if let url = self.url {
                    self.delegate?.onViewGallery(messagePrimary: self.messagePrimary, urls: self.urls, url: url)
                }
            }
        }
    }
}
