//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import KissXML

class NetworkManager: NSObject, URLSessionTaskDelegate {
    private let url: URL
    private let jwt: String
    private let jid: String
    private let maxRetryCount = 1
    private let maximumResponseSize = 1 * 1024 * 1024
    private let stateQueue = DispatchQueue(label: "com.xabber.push-archive-client.state")
    private var currentTask: URLSessionDataTask?
    private var callbackTask: Task<Void, Never>?
    private var retryWorkItem: DispatchWorkItem?
    private var cancelled = false
    private var sessionInvalidated = false
    private var session: URLSession?

    private func makeSession() -> URLSession {
        if let session {
            return session
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        return session
    }
    
    public weak var delegate: PushPayloadDelegate?
    
    init?(service url: String, jid: String, jwt: String) {
        guard !url.isEmpty,
              !jwt.isEmpty,
              let url = URL(string: url),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        self.jid = jid
        self.jwt = jwt
        self.url = url
    }
    
    public final func getMessage(host: String, messageId: String, by: String?, retry: Int? = nil) {
        guard isNetworkRequestActive() else {
            return
        }
        guard var components = URLComponents(
                url: url.appendingPathComponent("archive", isDirectory: false),
                resolvingAgainstBaseURL: false
              ) else {
            notifyFailureAndFinish()
            return
        }
        components.queryItems = [URLQueryItem(name: "id", value: messageId)]
        if let by = by {
            components.queryItems?.append(URLQueryItem(name: "by", value: by))
        }
        guard let formedUrl = components.url else {
            notifyFailureAndFinish()
            return
        }
        var request = URLRequest(url: formedUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue(host, forHTTPHeaderField: "Xmpp-Domain")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        
        let task: URLSessionDataTask? = stateQueue.sync {
            guard !cancelled,
                  !sessionInvalidated,
                  currentTask == nil else {
                return nil
            }
            retryWorkItem = nil
            let task = makeSession().dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.clearCurrentTask()
                guard !self.isRequestCancelled() else { return }
                let response = response as? HTTPURLResponse
                if let data,
                   data.count <= self.maximumResponseSize,
                   let response,
                   (200..<300).contains(response.statusCode),
                   let message = String(data: data, encoding: .utf8),
                   !message.localizedCaseInsensitiveContains("<!DOCTYPE"),
                   !message.localizedCaseInsensitiveContains("<!ENTITY"),
                   let document = try? DDXMLDocument(
                        xmlString: "<root>\(message)</root>",
                        options: 0
                   ),
                   let element = document.rootElement()?.elements(forName: "message").first {
                    self.finishSession()
                    self.read(message: element)
                    return
                }

                let statusCode = response?.statusCode
                let isTransientStatus = statusCode == 408
                    || statusCode == 429
                    || statusCode.map { (500...599).contains($0) } == true
                let isTransientNetworkError = error != nil && statusCode == nil
                let attempt = retry ?? 0
                if attempt < self.maxRetryCount,
                   isTransientStatus || isTransientNetworkError {
                    self.scheduleRetry(
                        host: host,
                        messageId: messageId,
                        by: by,
                        attempt: attempt + 1
                    )
                } else {
                    self.notifyFailureAndFinish()
                }
            }
            currentTask = task
            return task
        }
        task?.resume()
    }

    public final func cancel() {
        let work: (
            URLSessionDataTask?,
            Task<Void, Never>?,
            DispatchWorkItem?,
            URLSession?
        ) = stateQueue.sync {
            let shouldInvalidateSession = !sessionInvalidated
            cancelled = true
            sessionInvalidated = true
            let work = (
                currentTask,
                callbackTask,
                retryWorkItem,
                shouldInvalidateSession ? session : nil
            )
            currentTask = nil
            callbackTask = nil
            retryWorkItem = nil
            session = nil
            return work
        }
        work.0?.cancel()
        work.1?.cancel()
        work.2?.cancel()
        work.3?.invalidateAndCancel()
    }

    private func clearCurrentTask() {
        stateQueue.sync {
            currentTask = nil
        }
    }

    private func clearCallbackTask() {
        stateQueue.sync {
            callbackTask = nil
        }
    }

    private func isRequestCancelled() -> Bool {
        stateQueue.sync { cancelled }
    }

    private func isNetworkRequestActive() -> Bool {
        stateQueue.sync { !cancelled && !sessionInvalidated }
    }

    private func scheduleRetry(
        host: String,
        messageId: String,
        by: String?,
        attempt: Int
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isNetworkRequestActive() else {
                return
            }
            self.getMessage(
                host: host,
                messageId: messageId,
                by: by,
                retry: attempt
            )
        }
        var previous: DispatchWorkItem?
        let scheduled = stateQueue.sync {
            guard !cancelled, !sessionInvalidated else {
                return false
            }
            previous = retryWorkItem
            retryWorkItem = workItem
            return true
        }
        previous?.cancel()
        if scheduled {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 0.2,
                execute: workItem
            )
        }
    }

    private func notifyFailureAndFinish() {
        guard !isRequestCancelled() else {
            return
        }
        finishSession()
        guard !isRequestCancelled() else {
            return
        }
        delegate?.networkManager(self, didDisconnectWithError: "archive unavailable")
    }

    private func finishSession() {
        var retry: DispatchWorkItem?
        let sessionToFinish: URLSession? = stateQueue.sync {
            guard !sessionInvalidated else {
                return nil
            }
            sessionInvalidated = true
            currentTask = nil
            retry = retryWorkItem
            retryWorkItem = nil
            let session = self.session
            self.session = nil
            return session
        }
        retry?.cancel()
        sessionToFinish?.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard !isRequestCancelled(),
              let redirectedURL = request.url,
              redirectedURL.scheme?.lowercased() == "https",
              redirectedURL.host?.caseInsensitiveCompare(url.host ?? "") == .orderedSame else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
    
    private final func read(message stanza: DDXMLElement) {
        guard let preview = PushNotificationArchiveParser.parseArchivedMessage(stanza, owner: jid) else {
            notifyFailureAndFinish()
            return
        }
        stateQueue.sync {
            guard !cancelled else {
                return
            }
            callbackTask?.cancel()
            callbackTask = Task { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      !self.isRequestCancelled() else {
                    return
                }
                defer { self.clearCallbackTask() }
                await self.delegate?.networkManager(self, didUpdateContent: preview)
            }
        }
    }
    
    internal func getGrouchatUserNickname(_ references: [DDXMLElement]) -> String? {
        if let user = references.first(where: { ($0.attribute(forName: "type")?.stringValue ?? "none") == "mutable" })?.elements(forName: "user").first {
            return user.elements(forName: "nickname").first?.stringValue
        }
        return nil
    }
    
    internal func getGrouchatUserJid(_ references: [DDXMLElement]) -> String? {
        if let user = references.first(where: { ($0.attribute(forName: "type")?.stringValue ?? "none") == "mutable" })?.elements(forName: "user").first {
            return user.elements(forName: "jid").first?.stringValue
        }
        return nil
    }

    private func verificationRequestMessage(from message: DDXMLElement) -> DDXMLElement? {
        if containsTrustRequest(message) {
            return message
        }

        guard let notification = message.elements(forName: "notification").first(where: { $0.xmlns() == "urn:xabber:xen:0" }),
              let forwarded = notification.elements(forName: "forwarded").first(where: { $0.xmlns() == "urn:xmpp:forward:0" || $0.xmlns() == nil }),
              let innerMessage = forwarded.elements(forName: "message").first,
              containsTrustRequest(innerMessage) else {
            return nil
        }

        if let originalFrom = originalFromAddress(in: message),
           let forwardedFrom = innerMessage.attribute(forName: "from")?.stringValue,
           !jidMatches(originalFrom, forwardedFrom) {
            return nil
        }

        return innerMessage
    }

    private func containsTrustRequest(_ message: DDXMLElement) -> Bool {
        guard let trust = message.elements(forName: "trust").first(where: { $0.xmlns() == "urn:xmpp:trust:0" }) else {
            return false
        }
        return !trust.elements(forName: "request").isEmpty
    }

    private func originalFromAddress(in message: DDXMLElement) -> String? {
        guard let addresses = message.elements(forName: "addresses").first(where: { $0.xmlns() == "http://jabber.org/protocol/address" }) else {
            return nil
        }
        return addresses
            .elements(forName: "address")
            .first(where: { $0.attribute(forName: "type")?.stringValue == "ofrom" })?
            .attribute(forName: "jid")?
            .stringValue
    }

    private func jidMatches(_ lhs: String, _ rhs: String) -> Bool {
        return lhs == rhs || bareJid(lhs) == bareJid(rhs)
    }

    private func bareJid(_ jid: String) -> String {
        return jid.split(separator: "/").first.map(String.init) ?? jid
    }
    
    func getReferenceType(_ ref: DDXMLElement) -> String? {
        if !ref.elements(forName: "voice-message").isEmpty {
            return "voice"
        } else if !ref.elements(forName: "file-sharing").isEmpty {
            return "media"
        }
        return nil
    }
}

extension String {
    func xmlEscaping(reverse: Bool) -> String {
        var out = self
        let symbols: [String: String] = [
            "<": "&lt;",
            ">": "&gt;",
            "\"": "&quot;",
            "\'": "&apos;",
        ]
        out = out.replacingOccurrences(of: reverse ? "&amp;" : "&",
                                       with: reverse ? "&" : "&amp;",
                                       options: [],
                                       range: Range<String.Index>(NSRange(location: 0,
                                                                          length: out.count), in: out))
        symbols.forEach {
            out = out.replacingOccurrences(of: reverse ? $0.value : $0.key,
                                           with: reverse ? $0.key : $0.value,
                                           options: [],
                                           range: Range<String.Index>(NSRange(location: 0,
                                                                              length: out.count), in: out))
        }
        return out
    }
       
    func excludeFromBody(_ references: [DDXMLElement], groupchat: DDXMLElement?) -> String {
        var out: String = self.xmlEscaping(reverse: false)
        var mutableReferences: [DDXMLElement] = references
        if let groupchatRef = groupchat {
            mutableReferences.append(groupchatRef)
        }
        if self.isEmpty { return self }
        for reference in mutableReferences
            .sorted(by: { return (Int($0.attribute(forName: "begin")?.stringValue ?? "0") ?? 0) < (Int($1.attribute(forName: "begin")?.stringValue ?? "0") ?? 0) }) {
            if reference.xmlns() != "https://xabber.com/protocol/references" { continue }
            let offset = self.xmlEscaping(reverse: false).count - out.count
            var begin = (Int(reference.attribute(forName: "begin")?.stringValue ?? "0") ?? 0) - offset
            var end = (Int(reference.attribute(forName: "end")?.stringValue ?? "0") ?? 0) - offset// + 1
            let kind = reference.attribute(forName: "type")?.stringValue ?? "none"
            if end > out.count {
                end = out.count - 1
            }
            if begin < 0 {
                begin = 0
            }
            if begin >= end { continue }
            switch kind {
            case "mutable":
                if let range = Range<String.Index>(NSRange(begin..<end), in: out) {
                    out.removeSubrange(range)
                }
            default:
                break
            }
        }
        return out.xmlEscaping(reverse: true)
    }
}

protocol PushPayloadDelegate: AnyObject {
    func networkManager(_ manager: NetworkManager, didDisconnectWithError error: String)
    func networkManager(
        _ manager: NetworkManager,
        didUpdateContent preview: PushNotificationPreview
    ) async
    func didReceiveSync(stanza: String)
}
