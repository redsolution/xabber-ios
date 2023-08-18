//
//  CloudInfoScreenView.swift
//  xabber
//
//  Created by MacIntel on 07.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import UIKit
import SwiftUI
import CocoaLumberjack
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff

class CloudInfoScreenView: InfoScreenFooterView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isGroupChat = false
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override internal func setup() {
        self.backgroundColor = .clear
        getReferences()
        
        self.addSubview(scrollView)
        
        setCollectionLayout()
        addSubview(mediaCollectionView)
        
        mediaCollectionView.backgroundColor = .clear
        mediaCollectionView.delegate = self
        mediaCollectionView.dataSource = self
        mediaCollectionView.collectionViewLayout = collectionFlowLayout

        needsCollectionUpdate = true
    }
    
    override internal func activateConstraints() {
        NSLayoutConstraint.activate([
            mediaCollectionView.topAnchor.constraint(equalTo: topAnchor),
            mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            mediaCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
