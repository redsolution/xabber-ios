//
//  XabberAccountWebViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 05.03.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit
import CocoaLumberjack
import WebKit

class XabberAccountWebViewController: SimpleBaseViewController, WKNavigationDelegate /* or WKScriptMessageHandler if needed */ {
    
    var webView: WKWebView!
    
    func createWebViewWithPreSavedLocalStorage() -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // 1. (Опционально) очистить старый localStorage, если нужно
         let clearScript = WKUserScript(
             source: "localStorage.clear();",
             injectionTime: .atDocumentStart,
             forMainFrameOnly: true
         )
         config.userContentController.addUserScript(clearScript)
        
        // 2. Подготовь данные, которые хочешь сохранить
        let token = CredentialsManager.getXabberAccountToken(for: self.owner) ?? ""//"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."   // твой токен
//        let userId = "12345"
//        let role    = "admin"
        
        // 3. Важно: правильно экранируем строку для вставки в JS
        // Лучше использовать JSON-сериализацию — это безопаснее
        let data: [String: String] = [
            "token": token
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("Ошибка сериализации данных")
            return WKWebView(frame: .zero, configuration: config)
        }
        
        // 4. Сам скрипт — выполняем максимально рано
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
            injectionTime: .atDocumentStart,      // ← ключевой момент!
            forMainFrameOnly: true
        )
        
        config.userContentController.addUserScript(script)
        
        // 5. Создаём webView с этой конфигурацией
        let webView = WKWebView(frame: view.bounds, configuration: config)
        
        // (опционально) shared process pool — чтобы localStorage был общим между несколькими webview
        // static let sharedPool = WKProcessPool()
        // webView.configuration.processPool = Self.sharedPool
        
        return webView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "REQUEST_TOKEN")
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        
        if let expiresTs = CredentialsManager.getXabberAccountTokenExpire(for: self.owner),
           expiresTs < Date().timeIntervalSince1970 {
            webView = createWebViewWithPreSavedLocalStorage()
            webView.navigationDelegate = self
            view.addSubview(webView)
            
            if let url = URL(string: CommonConfigManager.shared.config.xabber_account_url) {
                webView.load(URLRequest(url: url))
            }
        } else {
            
            let _ = XabberAccountManager.shared.requestToken(for: self.owner) { token in
                
                DispatchQueue.main.async {
                    self.webView = self.createWebViewWithPreSavedLocalStorage()
                    self.webView.navigationDelegate = self
                    self.view.addSubview(self.webView)
                    
                    if let url = URL(string: CommonConfigManager.shared.config.xabber_account_url) {
                        self.webView.load(URLRequest(url: url))
                    }
                }
            }
            
        }
//        let result = XabberAccountManager.shared.requestToken(for: self.owner) { token in
//            if let token = token {
//                self.injectToken(token: token)
//            }
//        }
//        print(result)
    }
    
    func injectToken(token: String) {
        let escaped = token.replacingOccurrences(of: "\"", with: "\\\"")
        let js = "window.postMessage({ type: 'TOKEN_RESPONSE', token: \"\(escaped)\" }, '*');"
        webView.evaluateJavaScript(js) { _, err in
            if let err { print(err) }
        }
    }
    
    func sendTokenToWebView(token: String) {
        let escapedToken = token.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
                                 .replacingOccurrences(of: "\n", with: "\\n")
        
        let js = """
        if (window.parent && window.parent !== window) {
            window.parent.postMessage(
                {
                    type: 'TOKEN_RESPONSE',
                    token: "\(escapedToken)"
                },
                '*'
            );
        } else {
            window.postMessage(
                {
                    type: 'TOKEN_RESPONSE',
                    token: "\(escapedToken)"
                },
                '*'
            );
        }
        """
        
        webView.evaluateJavaScript(js) { (result, error) in
            if let error = error {
                print("Error sending token to webview: \(error)")
            } else {
                print("Token sent successfully")
            }
        }
    }
}

extension XabberAccountWebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "REQUEST_TOKEN" {
            let result = XabberAccountManager.shared.requestToken(for: self.owner) { token in
                if let token = token {
                    self.sendTokenToWebView(token: token)
                }
            }
//            let token = getCurrentTokenSomehow()   // your logic
//            sendTokenToWebView(token: token)
        }
    }
}
