//
//  XabberAccountManager.swift
//  xabber
//
//  Created by Игорь Болдин on 05.03.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//
import Foundation
import Alamofire
import XMPPFramework
import CocoaLumberjack

class XabberAccountManager: NSObject {
    open class var shared: XabberAccountManager {
        struct XabberAccountManagerSingleton {
            static let instance = XabberAccountManager()
        }
        return XabberAccountManagerSingleton.instance
    }
    
    class AuthTaskItem: NSObject {
        var requestId: String
        let account: String
        var callback: ((String?) -> Void)?
        var requestDate: Date = Date()
        var timeoutWorkItem: DispatchWorkItem?
        
        init(
            requestId: String,
            account: String = "",
            callback: ((String?) -> Void)? = nil
        ) {
            self.requestId = requestId
            self.account = account
            self.callback = callback
        }
    }

    struct TokenConfirmation: Equatable {
        let requestId: String
        let code: String
        let account: String
    }

    final class TokenCorrelationStore {
        enum RegistrationResult {
            case waiting
            case matched(TokenConfirmation)
            case accountMismatch
            case duplicate
        }

        enum ConfirmationResult {
            case buffered
            case matched(AuthTaskItem)
            case accountMismatch(AuthTaskItem)
            case duplicate
        }

        private enum State {
            case task(AuthTaskItem)
            case confirmation(TokenConfirmation)
        }

        private let lock = NSLock()
        private var states: [String: State] = [:]
        private var terminalRequestIds: [String] = []
        private var terminalRequestIdSet = Set<String>()
        private let terminalCapacity = 256

        func register(_ task: AuthTaskItem) -> RegistrationResult {
            lock.lock()
            defer { lock.unlock() }

            guard !terminalRequestIdSet.contains(task.requestId) else {
                return .duplicate
            }
            switch states[task.requestId] {
            case nil:
                states[task.requestId] = .task(task)
                return .waiting
            case .confirmation(let confirmation):
                markTerminalLocked(task.requestId)
                guard accountsMatch(task.account, confirmation.account) else {
                    return .accountMismatch
                }
                return .matched(confirmation)
            case .task:
                return .duplicate
            }
        }

        func receive(_ confirmation: TokenConfirmation) -> ConfirmationResult {
            var taskToCancel: AuthTaskItem?
            let result: ConfirmationResult

            lock.lock()
            if terminalRequestIdSet.contains(confirmation.requestId) {
                result = .duplicate
            } else {
                switch states[confirmation.requestId] {
                case nil:
                    states[confirmation.requestId] = .confirmation(confirmation)
                    result = .buffered
                case .confirmation:
                    result = .duplicate
                case .task(let task):
                    markTerminalLocked(confirmation.requestId)
                    taskToCancel = task
                    if !accountsMatch(task.account, confirmation.account) {
                        result = .accountMismatch(task)
                    } else {
                        result = .matched(task)
                    }
                }
            }
            lock.unlock()

            taskToCancel?.timeoutWorkItem?.cancel()
            return result
        }

        func timeoutTask(requestId: String) -> AuthTaskItem? {
            lock.lock()
            guard case .task(let task) = states[requestId] else {
                lock.unlock()
                return nil
            }
            markTerminalLocked(requestId)
            lock.unlock()
            task.timeoutWorkItem?.cancel()
            return task
        }

        func discardPendingConfirmation(requestId: String) {
            lock.lock()
            if case .confirmation = states[requestId] {
                markTerminalLocked(requestId)
            }
            lock.unlock()
        }

        private func accountsMatch(_ lhs: String, _ rhs: String) -> Bool {
            lhs.caseInsensitiveCompare(rhs) == .orderedSame
        }

        private func markTerminalLocked(_ requestId: String) {
            states.removeValue(forKey: requestId)
            guard terminalRequestIdSet.insert(requestId).inserted else {
                return
            }
            terminalRequestIds.append(requestId)
            if terminalRequestIds.count > terminalCapacity {
                let evicted = terminalRequestIds.removeFirst()
                terminalRequestIdSet.remove(evicted)
            }
        }
    }
    
    var tasks: [AuthTaskItem] = []
    private let tasksLock = NSLock()
    private let tokenRequestTimeout: TimeInterval = 15
    private let tokenCorrelationStore = TokenCorrelationStore()

    private func appendTask(_ task: AuthTaskItem) {
        tasksLock.lock()
        tasks.append(task)
        tasksLock.unlock()
    }

    private func hasTask(requestId: String?) -> Bool {
        guard let requestId = requestId else { return false }
        tasksLock.lock()
        defer { tasksLock.unlock() }
        return tasks.contains(where: { $0.requestId == requestId })
    }

    private func takeTask(requestId: String?) -> AuthTaskItem? {
        guard let requestId = requestId else { return nil }
        tasksLock.lock()
        let index = tasks.firstIndex(where: { $0.requestId == requestId })
        let task = index.map { tasks.remove(at: $0) }
        tasksLock.unlock()
        task?.timeoutWorkItem?.cancel()
        return task
    }

    private func scheduleTokenRequestTimeout(for task: AuthTaskItem) {
        let workItem = DispatchWorkItem { [weak self, weak task] in
            guard let self = self,
                  let task = task,
                  let timedOutTask = self.tokenCorrelationStore.timeoutTask(
                    requestId: task.requestId
                  ) else {
                return
            }
            DDLogInfo("ACCOUNT_API_AUTH event=token_request_completed outcome=timeout")
            timedOutTask.callback?(nil)
        }
        task.timeoutWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + tokenRequestTimeout, execute: workItem)
    }

    private func schedulePendingConfirmationExpiration(requestId: String) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + tokenRequestTimeout
        ) { [weak self] in
            self?.tokenCorrelationStore.discardPendingConfirmation(
                requestId: requestId
            )
        }
    }
    
    func token(
        for account: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> String? {
        guard let token = CredentialsManager.getXabberAccountToken(for: account) else {
            return nil
        }

        // Tokens written by older app versions did not persist an expiry. Keep
        // those usable until the service explicitly rejects them.
        guard let expiresAt = CredentialsManager.getXabberAccountTokenExpire(for: account) else {
            return token
        }
        guard expiresAt > now else {
            clearToken(for: account)
            return nil
        }
        return token
    }
    
    func storeToken(for account: String, token: String, expire: Double) {
        CredentialsManager.shared.setXabberAccountToken(for: account, token: token)
        CredentialsManager.shared.setXabberAccountTokenExpire(for: account, expire: expire)
    }

    func clearToken(for account: String) {
        CredentialsManager.shared.removeXabberAccountToken(for: account)
        CredentialsManager.shared.removeXabberAccountTokenExpire(for: account)
    }
    
    static let xmlns: String = "https://services.xabber.com/protocol/api/services"
    
    public final func registerAccount(_ stream: XMPPStream, callback: ((String?) -> Void)? = nil) {
        guard let services = XMPPJID(string: CommonConfigManager.shared.config.xabber_account_xmpp_jid) else {
            return
        }
        let requestId = "XA: \(NanoID.new(8))"
        let account = DDXMLElement(name: "accounts", xmlns: XabberAccountManager.xmlns)
        let create = DDXMLElement(name: "create")
        account.addChild(create)
        let iq = XMPPIQ(iqType: .set, to: services, elementID: requestId, child: account)
        stream.send(iq)
        appendTask(AuthTaskItem(requestId: requestId, callback: callback))
    }
    
    struct AccountResponse: Decodable {
        let accountId: String
        let message: String
        
        enum CodingKeys: String, CodingKey {
            case accountId = "apple_account"
            case message = "message"
        }
        
        static func decode(from base64String: String) throws -> AccountResponse {
            guard let data = Data(base64Encoded: base64String) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Invalid base64 string")
                )
            }
            return try JSONDecoder().decode(AccountResponse.self, from: data)
        }
    }
    
    private func onRegisterAccount(_ stream: XMPPStream, iq: XMPPIQ) -> Bool {
        guard hasTask(requestId: iq.elementID) else {
            return false
        }
        let response_b64: String = ""
        guard let response_b64 = iq.element(forName: "response", xmlns: XabberAccountManager.xmlns)?.stringValue,
              let jid = stream.myJID?.bare,
              let account = try? AccountResponse.decode(from: response_b64) else {
            return false
        }
        
        guard let task = takeTask(requestId: iq.elementID) else {
            return false
        }
        task.callback?(account.accountId)
        CredentialsManager.shared.setXabberAccountUUID(for: jid, uuid: account.accountId)
        return true
    }
    
    private func onFailToRegisterAccount(_ stream: XMPPStream, iq: XMPPIQ) -> Bool {
        guard iq.iqType == .error else {
            return false
        }
        guard hasTask(requestId: iq.elementID) else {
            return false
        }
        let response_b64: String = ""
        guard iq.element(forName: "accounts", xmlns: XabberAccountManager.xmlns)?.element(forName: "create") != nil,
              let jid = stream.myJID?.bare else {
            return false
        }
        
        guard let task = takeTask(requestId: iq.elementID) else {
            return false
        }
        task.callback?(nil)
        CredentialsManager.shared.removeXabberAccountUUID(for: jid)
        return true
    }
    
    func requestToken(for account: String, callback: ((String?) -> Void)? = nil) -> Bool {
        let accountAPIBaseURL = CommonConfigManager.shared.config.xabber_account_api_url
        let stringUrl = accountAPIBaseURL + "xmpp_auth/code_request/"
        guard let requestedAccount = XMPPJID(string: account)?.bare,
              let accountStreamJID = AccountManager.shared
                .find(for: requestedAccount)?
                .xmppStream
                .myJID,
              accountStreamJID.bare.caseInsensitiveCompare(requestedAccount) == .orderedSame else {
            callback?(nil)
            return false
        }

        let params: [String: String] = [
            "jid": accountStreamJID.full,
            "type": "iq"
        ]
        guard let url = URL(string: stringUrl) else {
            callback?(nil)
            return false
        }

        AF.request(
            url,
            method: .post,
            parameters: params,
            encoding: JSONEncoding.default,
            headers: HTTPHeaders()
        ).responseJSON { [weak self] response in
            guard let self else {
                callback?(nil)
                return
            }
            let statusCode = response.response?.statusCode
            switch response.result {
            case .success(let value):
                guard let statusCode,
                      (200..<300).contains(statusCode),
                      let data = value as? NSDictionary,
                      let requestId = data["request_id"] as? String,
                      requestId.isNotEmpty else {
                    DDLogInfo(
                        "ACCOUNT_API_AUTH event=code_request_completed outcome=invalid_response http_status=\(statusCode ?? -1)"
                    )
                    callback?(nil)
                    return
                }
                let task = AuthTaskItem(
                    requestId: requestId,
                    account: requestedAccount,
                    callback: callback
                )
                switch self.tokenCorrelationStore.register(task) {
                case .waiting:
                    DDLogInfo(
                        "ACCOUNT_API_AUTH event=code_request_completed outcome=waiting_for_confirmation http_status=\(statusCode)"
                    )
                    self.scheduleTokenRequestTimeout(for: task)
                case .matched(let confirmation):
                    DDLogInfo(
                        "ACCOUNT_API_AUTH event=confirmation_correlated order=confirmation_first outcome=matched"
                    )
                    self.exchangeTokenCode(confirmation, task: task)
                case .accountMismatch:
                    DDLogError(
                        "ACCOUNT_API_AUTH event=confirmation_correlated outcome=account_mismatch"
                    )
                    callback?(nil)
                case .duplicate:
                    DDLogInfo(
                        "ACCOUNT_API_AUTH event=code_request_completed outcome=duplicate"
                    )
                    callback?(nil)
                }

            case .failure(let error):
                let nsError = error as NSError
                DDLogError(
                    "ACCOUNT_API_AUTH event=code_request_completed outcome=network_error error_domain=\(String(reflecting: nsError.domain)) error_code=\(nsError.code)"
                )
                callback?(nil)
            }
        }
        return true
    }

    static func isAccountTokenConfirmationURL(
        _ rawURL: String?,
        accountAPIBaseURL: String
    ) -> Bool {
        guard let rawURL,
              let actual = URLComponents(string: rawURL) else {
            return false
        }
        let separator = accountAPIBaseURL.hasSuffix("/") ? "" : "/"
        let expectedRawURL = accountAPIBaseURL
            + separator
            + "xmpp_auth/code_request/confirm"
        guard let expected = URLComponents(string: expectedRawURL) else {
            return false
        }

        func normalizedPath(_ path: String) -> String {
            "/" + path
                .split(separator: "/", omittingEmptySubsequences: true)
                .joined(separator: "/")
        }

        func effectivePort(_ components: URLComponents) -> Int? {
            if let port = components.port {
                return port
            }
            switch components.scheme?.lowercased() {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }

        return actual.scheme?.lowercased() == expected.scheme?.lowercased()
            && actual.host?.lowercased() == expected.host?.lowercased()
            && effectivePort(actual) == effectivePort(expected)
            && normalizedPath(actual.path) == normalizedPath(expected.path)
            && actual.query == nil
            && actual.fragment == nil
    }

    private func onCodeResponse(_ xmppStream: XMPPStream, with iq: XMPPIQ) -> Bool {
        guard iq.iqType == .get,
              let requestId = iq.elementID,
              let confirm = iq.element(
                forName: "confirm",
                xmlns: "http://jabber.org/protocol/http-auth"
              ),
              let code = confirm.attributeStringValue(forName: "id"),
              Self.isAccountTokenConfirmationURL(
                confirm.attributeStringValue(forName: "url"),
                accountAPIBaseURL: CommonConfigManager.shared.config.xabber_account_api_url
              ),
              let account = xmppStream.myJID?.bare else {
            return false
        }

        let acknowledgement = XMPPIQ(
            iqType: .result,
            to: iq.from,
            elementID: requestId
        )
        xmppStream.send(acknowledgement)

        let confirmation = TokenConfirmation(
            requestId: requestId,
            code: code,
            account: account
        )
        switch tokenCorrelationStore.receive(confirmation) {
        case .buffered:
            DDLogInfo(
                "ACCOUNT_API_AUTH event=confirmation_received order=confirmation_first outcome=buffered"
            )
            schedulePendingConfirmationExpiration(requestId: requestId)
        case .matched(let task):
            DDLogInfo(
                "ACCOUNT_API_AUTH event=confirmation_correlated order=registration_first outcome=matched"
            )
            exchangeTokenCode(confirmation, task: task)
        case .accountMismatch(let task):
            DDLogError(
                "ACCOUNT_API_AUTH event=confirmation_correlated outcome=account_mismatch"
            )
            task.callback?(nil)
        case .duplicate:
            DDLogInfo(
                "ACCOUNT_API_AUTH event=confirmation_received outcome=duplicate"
            )
        }
        return true
    }

    private func exchangeTokenCode(
        _ confirmation: TokenConfirmation,
        task: AuthTaskItem
    ) {
        guard confirmation.account.caseInsensitiveCompare(task.account) == .orderedSame,
              let url = URL(
                string: CommonConfigManager.shared.config.xabber_account_api_url
                    + "xmpp_auth/confirm/"
              ) else {
            task.callback?(nil)
            return
        }
        let params: [String: String] = [
            "jid": task.account,
            "code": confirmation.code
        ]

        AF.request(
            url,
            method: .post,
            parameters: params,
            encoding: JSONEncoding.default,
            headers: HTTPHeaders()
        ).responseJSON { [weak self] response in
            guard let self else {
                task.callback?(nil)
                return
            }
            let statusCode = response.response?.statusCode
            switch response.result {
            case .success(let value):
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let statusCode,
                      (200..<300).contains(statusCode),
                      let data = value as? NSDictionary,
                      let token = data["token"] as? String,
                      token.isNotEmpty,
                      let expires = data["expires"] as? String,
                      let expiresTS = formatter.date(from: expires)?.timeIntervalSince1970 else {
                    DDLogInfo(
                        "ACCOUNT_API_AUTH event=token_exchange_completed outcome=invalid_response http_status=\(statusCode ?? -1)"
                    )
                    task.callback?(nil)
                    return
                }
                self.storeToken(
                    for: task.account,
                    token: token,
                    expire: expiresTS
                )
                DDLogInfo(
                    "ACCOUNT_API_AUTH event=token_exchange_completed outcome=success http_status=\(statusCode)"
                )
                task.callback?(token)

            case .failure(let error):
                let nsError = error as NSError
                DDLogError(
                    "ACCOUNT_API_AUTH event=token_exchange_completed outcome=network_error error_domain=\(String(reflecting: nsError.domain)) error_code=\(nsError.code)"
                )
                task.callback?(nil)
            }
        }
    }
    
    func read(_ stream: XMPPStream, with iq: XMPPIQ) -> Bool {
        switch true {
            case onRegisterAccount(stream, iq: iq): return true
            case onFailToRegisterAccount(stream, iq: iq): return true
            case onCodeResponse(stream, with: iq): return true
            default: return false
        }
    }
}
