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
        label.textAlignment = .left
        label.font = UIFont.preferredFont(forTextStyle: .title3).bold()
//        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    let labelVideos: UILabel = {
        let label = UILabel()
        label.text = "Videos"
        label.textAlignment = .left
        label.font = UIFont.preferredFont(forTextStyle: .title3).bold()
//        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    let labelFiles: UILabel = {
        let label = UILabel()
        label.text = "Files"
        label.textAlignment = .left
        label.font = UIFont.preferredFont(forTextStyle: .title3).bold()
//        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    let labelVoices: UILabel = {
        let label = UILabel()
        label.text = "Voice messages"
        label.textAlignment = .left
        label.font = UIFont.preferredFont(forTextStyle: .title3).bold()
//        label.translatesAutoresizingMaskIntoConstraints = false
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
        
//        addArrangedSubview(labelImages)
//        addArrangedSubview(sectionImages)
//        addArrangedSubview(labelFiles)
//        addArrangedSubview(sectionFiles)
//        addArrangedSubview(labelVoices)
//        addArrangedSubview(sectionVoices)
        
        [sectionImages, sectionVideos, sectionFiles, sectionVoices] .forEach { section in
            section.jid = jid
            section.owner = owner
        }
        
        sectionImages.infoVCDelegate = infoVCDelegate
        sectionVideos.infoVCDelegate = infoVCDelegate
        sectionFiles.infoVCDelegate = infoVCDelegate
        sectionVoices.infoVCDelegate = infoVCDelegate
        sectionImages.setup()
        sectionVideos.setup()
        sectionFiles.setup()
        sectionVoices.setup()
        
        addSectionAndLabel(section: sectionImages, label: labelImages)
        addSectionAndLabel(section: sectionVideos, label: labelVideos)
        addSectionAndLabel(section: sectionFiles, label: labelFiles)
        addSectionAndLabel(section: sectionVoices, label: labelVoices)
        
        activateConstraints()
    }
    
    func addSectionAndLabel(section: CloudInfoScreenView, label: UILabel) {
        if section.datasource.isNotEmpty {
            addArrangedSubview(label)
        }
        addArrangedSubview(section)
    }
    
    func activateConstraints() {
        NSLayoutConstraint.activate([
            sectionImages.mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            sectionImages.mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            sectionImages.mediaCollectionView.topAnchor.constraint(equalTo: topAnchor, constant: sectionImages.datasource.isNotEmpty ? 30 : 0),
            sectionImages.mediaCollectionView.heightAnchor.constraint(equalToConstant: CGFloat(sectionImages.datasource.isNotEmpty ? sectionImages.datasource.count / 3 + 1 : 0) * 124),
            
            sectionVideos.mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            sectionVideos.mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            sectionVideos.mediaCollectionView.topAnchor.constraint(equalTo: sectionImages.mediaCollectionView.bottomAnchor, constant: sectionVideos.datasource.isNotEmpty ? 30 : 0),
            sectionVideos.mediaCollectionView.heightAnchor.constraint(equalToConstant: CGFloat(sectionVideos.datasource.isNotEmpty ? sectionVideos.datasource.count / 3 + 1 : 0) * 124),
            
            sectionFiles.mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            sectionFiles.mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            sectionFiles.mediaCollectionView.topAnchor.constraint(equalTo: sectionVideos.mediaCollectionView.bottomAnchor, constant: sectionFiles.datasource.isNotEmpty ? 30 : 0),
            sectionFiles.mediaCollectionView.heightAnchor.constraint(equalToConstant: CGFloat(sectionFiles.datasource.isNotEmpty ? sectionFiles.datasource.count : 0) * 60),

            sectionVoices.mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            sectionVoices.mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            sectionVoices.mediaCollectionView.topAnchor.constraint(equalTo: sectionFiles.mediaCollectionView.bottomAnchor, constant: sectionVoices.datasource.isNotEmpty ? 30 : 0),
            sectionVoices.mediaCollectionView.heightAnchor.constraint(equalToConstant: CGFloat(sectionVoices.datasource.isNotEmpty ? sectionVoices.datasource.count : 0) * 60),
        ])
    }
}
