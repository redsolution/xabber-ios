//
//  CloudStorageDeleteViewController.swift
//  xabber
//
//  Created by MacIntel on 11.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

final class CloudStorageDeleteViewController: CloudStorageShowFilesViewController {
    var datasource: [[Datasource]] = []
    let plan: XabberUploadManager.CloudStorageCleanupPlan
    var isDeleting = false

    let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.sectionInset = CloudStorageCategoryLayoutPolicy.sectionInsets
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.register(PhotosMediaCollectionCell.self, forCellWithReuseIdentifier: PhotosMediaCollectionCell.cellName)
        collection.register(VideosMediaCollectionCell.self, forCellWithReuseIdentifier: VideosMediaCollectionCell.cellName)
        collection.register(FilesMediaCollectionCell.self, forCellWithReuseIdentifier: FilesMediaCollectionCell.cellName)
        collection.register(VoiceMediaCollectionCell.self, forCellWithReuseIdentifier: VoiceMediaCollectionCell.cellName)
        collection.register(
            UICollectionReusableView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "headerView"
        )
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "deleteButton")
        collection.backgroundColor = .systemGroupedBackground
        collection.accessibilityIdentifier = "cloudStorage.cleanup.preview"
        return collection
    }()

    init(
        owner: String,
        items: [NSDictionary],
        plan: XabberUploadManager.CloudStorageCleanupPlan
    ) {
        self.plan = plan
        super.init(owner: owner, items: items, totalPages: 1)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageContextDidChange(_:)),
            name: .cloudStorageGalleryDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageContextDidChange(_:)),
            name: .cloudStorageGalleryTokenDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(collectionView)
        collectionView.fillSuperview()
        collectionView.dataSource = self
        collectionView.delegate = self
        configureCollections()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.title = "Delete files"
        navigationItem.largeTitleDisplayMode = CommonConfigManager.shared.config.use_large_title ? .automatic : .never
        navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
    }

    func gallerySelectionIsCurrent() -> Bool {
        return CloudStorageGalleryRequestContext.resolve(owner: owner) == plan.context
    }

    @objc private func cloudStorageContextDidChange(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == owner else { return }
        if notification.name == .cloudStorageGalleryTokenDidChange,
           let galleryIdentity = notification.userInfo?["galleryIdentity"] as? String,
           galleryIdentity != plan.context.identity {
            return
        }
        items.removeAll()
        datasource.removeAll()
        collectionView.reloadData()
        navigationController?.popViewController(animated: true)
    }

    func configureCollections() {
        let grouped = CloudStorageItemPresentation.grouped(items)
            .filter { $0.first?.kind != .avatar }
        datasource = [[]] + grouped
        collectionView.reloadData()
    }

    func performDeletion() {
        guard !isDeleting,
              gallerySelectionIsCurrent(),
              let account = AccountManager.shared.find(for: owner) else { return }
        isDeleting = true
        collectionView.isUserInteractionEnabled = false
        spinner.startAnimating()
        if spinner.superview == nil {
            view.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        collectionView.reloadData()

        account.action { [weak self] user, _ in
            guard let self else { return }
            user.cloudStorage.deleteMedia(using: plan) { result in
                DispatchQueue.main.async {
                    self.spinner.stopAnimating()
                    self.spinner.removeFromSuperview()
                    self.collectionView.isUserInteractionEnabled = true
                    switch result {
                    case .success:
                        self.finishSuccessfulDeletion()
                    case .failure:
                        self.isDeleting = false
                        self.collectionView.reloadData()
                        self.presentDeletionError()
                    }
                }
            }
        }
    }

    private func finishSuccessfulDeletion() {
        guard let navigationController else { return }
        if let destination = navigationController.viewControllers.last(where: { $0 is CloudStorageViewController }) {
            navigationController.popToViewController(destination, animated: true)
        } else {
            navigationController.popViewController(animated: true)
        }
    }

    private func presentDeletionError() {
        let alert = UIAlertController(
            title: "Couldn't delete files",
            message: "Cloud Storage was not changed. Check your connection and try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
