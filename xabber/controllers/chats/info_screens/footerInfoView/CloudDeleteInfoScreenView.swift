//
//  CloudDeleteInfoScreenView.swift
//  xabber
//
//  Created by MacIntel on 14.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import DeepDiff
import RxSwift
import Alamofire

class CloudDeleteInfoScreenView: UIStackView {
    var jid: String = ""
    var owner: String = ""
    var infoVCDelegate: InfoVCDelegate? = nil
    
    let sectionImages: CloudInfoScreenView = {
        let view = CloudInfoScreenView(frame: .zero)
        view.selectedKind = .images
        
        return view
    }()
    
    let sectionVideos: CloudInfoScreenView = {
        let view = CloudInfoScreenView(frame: .zero)
        view.selectedKind = .videos

        return view
    }()
    
    let sectionFiles: CloudInfoScreenView = {
        let view = CloudInfoScreenView(frame: .zero)
        view.selectedKind = .files

        return view
    }()
    
    let sectionVoices: CloudInfoScreenView = {
        let view = CloudInfoScreenView(frame: .zero)
        view.selectedKind = .voice

        return view
    }()
    
    let labelImages: UILabel = {
        let label = UILabel()
        label.text = "Images"
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        return label
    }()
    
    let labelVideos: UILabel = {
        let label = UILabel()
        label.text = "Videos"
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        return label
    }()
    
    let labelFiles: UILabel = {
        let label = UILabel()
        label.text = "Files"
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        return label
    }()
    
    let labelVoices: UILabel = {
        let label = UILabel()
        label.text = "Voice messages"
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure() {
        
        backgroundColor = .clear
        
//        addSectionAndLabel(section: sectionImages, label: labelImages)
//        addSectionAndLabel(section: sectionVideos, label: labelVideos)
//        addSectionAndLabel(section: sectionFiles, label: labelFiles)
//        addSectionAndLabel(section: sectionVoices, label: labelVoices)
        
        addArrangedSubview(labelImages)
        addArrangedSubview(sectionImages)
        addArrangedSubview(labelFiles)
        addArrangedSubview(sectionFiles)
        addArrangedSubview(labelVoices)
        addArrangedSubview(sectionVoices)
        
        [sectionImages, sectionFiles, sectionVoices] .forEach { section in
            section.jid = jid
            section.owner = owner
        }
        
        sectionImages.infoVCDelegate = infoVCDelegate
        sectionVoices.infoVCDelegate = infoVCDelegate
        sectionImages.setup()
        sectionFiles.setup()
        sectionVoices.setup()
        
        activateConstraints()
    }
    
    func addSectionAndLabel(section: CloudInfoScreenView, label: UILabel) {
        if section.datasource.isEmpty {
            return
        }
        addArrangedSubview(label)
        addArrangedSubview(section)
    }
    
    func activateConstraints() {
        NSLayoutConstraint.activate([
            sectionImages.mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            sectionImages.mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            sectionImages.mediaCollectionView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            sectionImages.mediaCollectionView.heightAnchor.constraint(equalToConstant: CGFloat(sectionImages.datasource.count / 3 + 1) * 124),
            
            sectionFiles.mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            sectionFiles.mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            sectionFiles.mediaCollectionView.topAnchor.constraint(equalTo: sectionImages.mediaCollectionView.bottomAnchor, constant: 30),
            sectionFiles.mediaCollectionView.heightAnchor.constraint(equalToConstant: CGFloat(sectionImages.datasource.isNotEmpty ? sectionImages.datasource.count / 3 + 1 : 0) * 124),

            sectionVoices.mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            sectionVoices.mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            sectionVoices.mediaCollectionView.topAnchor.constraint(equalTo: sectionFiles.mediaCollectionView.bottomAnchor, constant: 30),
            sectionVoices.mediaCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
