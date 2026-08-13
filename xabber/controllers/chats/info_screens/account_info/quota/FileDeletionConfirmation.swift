//
//  FileDeletionConfirmation.swift
//  xabber
//
//  Created by MacIntel on 20.09.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

final class FileDeletionConfirmation: BaseViewController {
    private enum State: Equatable {
        case loading
        case ready
        case empty
        case failed
        case deleting
    }

    private let percent: Int
    private var items: [NSDictionary] = []
    private var plan: XabberUploadManager.CloudStorageCleanupPlan?
    private var state: State = .loading
    private let capturedGalleryIdentity: String

    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ViewFilesCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "DeleteFilesCell")
        return view
    }()

    private lazy var spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.color = .gray
        view.hidesWhenStopped = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(percent: Int, owner: String) {
        self.percent = percent
        self.capturedGalleryIdentity = AccountGalleryConfiguration(owner: owner).currentGalleryIdentity
        super.init(nibName: nil, bundle: nil)
        self.owner = owner
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageGalleryDidChange(_:)),
            name: .cloudStorageGalleryDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageGalleryDidChange(_:)),
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
        configureView()
        loadPreview()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.title = "Delete files"
        navigationItem.largeTitleDisplayMode = CommonConfigManager.shared.config.use_large_title ? .automatic : .never
        navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
        navigationItem.backButtonDisplayMode = .minimal
    }

    private func configureView() {
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.accessibilityIdentifier = "cloudStorage.cleanup.confirmation"

        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func loadPreview() {
        guard CloudStorageCleanupPolicy.supportedPercents.contains(percent),
              gallerySelectionIsCurrent() else {
            finishLoading(.failure(.staleSelection), plan: nil)
            return
        }

        state = .loading
        items.removeAll()
        plan = nil
        spinner.startAnimating()
        tableView.backgroundView = nil
        tableView.reloadData()

        guard let account = AccountManager.shared.find(for: owner) else {
            finishLoading(.failure(.unavailable), plan: nil)
            return
        }

        account.action { [weak self] user, _ in
            guard let self else { return }
            switch user.cloudStorage.makeCleanupPlan(percent: percent) {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.finishLoading(.failure(error), plan: nil)
                }

            case .success(let plan):
                CloudStoragePagedLoader().loadAll(fetchPage: { page, completion in
                    user.cloudStorage.getFilesToDelete(plan: plan, page: page, completion: completion)
                }, completion: { [weak self] result in
                    DispatchQueue.main.async {
                        self?.finishLoading(result, plan: plan)
                    }
                })
            }
        }
    }

    private func finishLoading(
        _ result: Result<[NSDictionary], CloudStorageListLoadError>,
        plan: XabberUploadManager.CloudStorageCleanupPlan?
    ) {
        spinner.stopAnimating()
        guard gallerySelectionIsCurrent() else { return }

        switch result {
        case .success(let loadedItems):
            self.items = loadedItems.compactMap { payload in
                guard let presentation = CloudStorageItemPresentation.make(from: payload),
                      presentation.kind != .avatar else {
                    return nil
                }
                return payload
            }
            self.plan = plan
            state = items.isEmpty ? .empty : .ready
        case .failure:
            items.removeAll()
            self.plan = nil
            state = .failed
        }
        updateBackground()
        tableView.reloadData()
    }

    private func updateBackground() {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        switch state {
        case .empty:
            label.text = "No eligible files need to be deleted for this target."
        case .failed:
            label.text = "Couldn't prepare the cleanup preview. Tap Retry."
        default:
            label.text = nil
        }
        tableView.backgroundView = label.text == nil ? nil : label
    }

    private func gallerySelectionIsCurrent() -> Bool {
        return capturedGalleryIdentity == AccountGalleryConfiguration(owner: owner).currentGalleryIdentity
    }

    @objc private func cloudStorageGalleryDidChange(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == owner else { return }
        if notification.name == .cloudStorageGalleryTokenDidChange,
           let galleryIdentity = notification.userInfo?["galleryIdentity"] as? String,
           galleryIdentity != capturedGalleryIdentity {
            return
        }
        items.removeAll()
        plan = nil
        navigationController?.popViewController(animated: true)
    }

    private func confirmDeletion() {
        guard state == .ready, let plan else { return }
        ActionSheetPresenter().present(
            in: self,
            title: "Delete files",
            message: "Please confirm deleting files from Cloud Storage. This action cannot be undone.",
            cancel: "Cancel",
            values: [ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete")],
            animated: true
        ) { [weak self] _ in
            self?.performDeletion(using: plan)
        }
    }

    private func performDeletion(using plan: XabberUploadManager.CloudStorageCleanupPlan) {
        guard state == .ready,
              let account = AccountManager.shared.find(for: owner) else { return }
        state = .deleting
        spinner.startAnimating()
        tableView.reloadData()

        account.action { [weak self] user, _ in
            user.cloudStorage.deleteMedia(using: plan) { result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spinner.stopAnimating()
                    switch result {
                    case .success:
                        self.navigationController?.popViewController(animated: true)
                    case .failure(let error):
                        if error == .staleSelection || error == .unauthorized {
                            self.items.removeAll()
                            self.plan = nil
                            self.state = .failed
                            self.updateBackground()
                        } else {
                            self.state = .ready
                        }
                        self.tableView.reloadData()
                        self.presentDeletionError()
                    }
                }
            }
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

extension FileDeletionConfirmation: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let isPreview = indexPath.section == 0
        let identifier = isPreview ? "ViewFilesCell" : "DeleteFilesCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath)
        var content = cell.defaultContentConfiguration()

        if isPreview, state == .failed {
            content.text = "Retry"
            content.textProperties.color = .systemBlue
        } else {
            content.text = isPreview ? "View files to delete (\(items.count))" : "Delete files"
            content.textProperties.color = state == .ready
                ? (isPreview ? .systemBlue : .systemRed)
                : .tertiaryLabel
        }
        content.textProperties.alignment = .center
        cell.contentConfiguration = content
        cell.selectionStyle = (state == .ready || (isPreview && state == .failed)) ? .default : .none
        cell.isUserInteractionEnabled = state == .ready || (isPreview && state == .failed)
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section == 0 else { return nil }
        let header = UITableViewHeaderFooterView()
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.text = "Review the files selected to reach \(percent)% free space. The preview is advisory; the server validates the cleanup again when you confirm. Avatars are excluded."
        label.numberOfLines = 0
        header.addSubview(label)
        label.fillSuperviewWithOffset(top: 0, bottom: 35, left: 16, right: 16)
        return header
    }
}

extension FileDeletionConfirmation: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard gallerySelectionIsCurrent() else { return }

        if indexPath.section == 0, state == .failed {
            loadPreview()
            return
        }
        guard state == .ready, let plan else { return }
        if indexPath.section == 0 {
            navigationController?.pushViewController(
                CloudStorageDeleteViewController(owner: owner, items: items, plan: plan),
                animated: true
            )
        } else {
            confirmDeletion()
        }
    }
}
