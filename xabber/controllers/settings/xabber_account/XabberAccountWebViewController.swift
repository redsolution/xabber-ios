//
//  XabberAccountWebViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 05.03.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import CocoaLumberjack
import WebKit

class XabberAccountWebViewController: SimpleBaseViewController, WKNavigationDelegate {

    var webView: WKWebView!
    private var canGoBackObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?


    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavigationBar()

        if let expiresTs = CredentialsManager.getXabberAccountTokenExpire(for: self.owner),
           expiresTs > Date().timeIntervalSince1970 {
            setupAndLoadWebView()
        } else {
            let _ = XabberAccountManager.shared.requestToken(for: self.owner) { [weak self] token in
                DispatchQueue.main.async {
                    self?.setupAndLoadWebView()
                }
            }
        }
    }

    deinit {
        canGoBackObservation?.invalidate()
        urlObservation?.invalidate()
    }

    private func setupNavigationBar() {
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(backButtonTapped)
        )
    }

    @objc private func backButtonTapped() {
        if let components = webView?.url?.absoluteString.contains("confirm") {
            navigationController?.popViewController(animated: true)
        }
        if webView?.canGoBack == true {
            webView.goBack()
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func setupAndLoadWebView() {
        webView = createWebViewWithPreSavedLocalStorage()
        view.addSubview(webView)

        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        webView.allowsBackForwardNavigationGestures = true
        
        canGoBackObservation = webView.observe(\.canGoBack, options: .new) { [weak self] _, _ in
            self?.updateInteractivePopGesture()
        }

        urlObservation = webView.observe(\.url, options: .new) { [weak self] _, _ in
            self?.updateTitleFromRoute()
        }

        if let url = URL(string: CommonConfigManager.shared.config.xabber_account_url) {
            webView.load(URLRequest(url: url))
        }
    }

    private func createWebViewWithPreSavedLocalStorage() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        let clearScript = WKUserScript(
            source: "localStorage.clear();",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(clearScript)

        let token = CredentialsManager.getXabberAccountToken(for: self.owner) ?? ""
        let data: [String: String] = [
            "token": token,
            "platform": "ios"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return WKWebView(frame: .zero, configuration: config)
        }

        let jsSource = """
        (function() {
            const data = \(jsonString);
            for (const [key, value] of Object.entries(data)) {
                localStorage.setItem(key, value);
            }
        })();
        """

        let script = WKUserScript(
            source: jsSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        return webView
    }

    private func updateInteractivePopGesture() {
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !(webView?.canGoBack ?? false)
    }

    private func updateTitleFromRoute() {
        title = self.webView?.title
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let baseHost = URL(string: CommonConfigManager.shared.config.xabber_account_url)?.host

        if url.host == baseHost || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }

        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }
}
