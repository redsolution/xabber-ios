import Foundation
import KissXML

/// XEP-HTTPIQ-MAM by-id transport using the exact endpoint from XMPP discovery.
/// Each instance owns one fetch and never refreshes or mutates credentials.
final class PushArchiveHTTPClient: NSObject, URLSessionDataDelegate {
    enum Failure: Equatable {
        case invalidRequest, invalidResponse, oversizedResponse, redirect
        case http(Int)
        case transport, timeout, busy
    }

    enum Outcome {
        case message(DDXMLElement)
        case xmppError(String?)
        case unauthorized
        case failure(Failure)
        case cancelled
    }

    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> DispatchWorkItem

    static let liveScheduler: Scheduler = { delay, action in
        let item = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    private let endpointURL: URL
    private let token: String
    private let archiveOwner: String
    private let configuration: URLSessionConfiguration
    private let maximumResponseSize: Int
    private let totalBudget: TimeInterval
    private let requestTimeout: TimeInterval
    private let clock: () -> TimeInterval
    private let scheduler: Scheduler
    private let callbackQueue: DispatchQueue
    private let diagnostic: ((String) -> Void)?
    // Diagnostic sinks may perform file IO or call cancel(). Keep them off the
    // transport state queue and outside cancellation/state locks.
    private let diagnosticQueue = DispatchQueue(label: "com.xabber.push-archive-http.diagnostics")
    private let stateQueue = DispatchQueue(label: "com.xabber.push-archive-http.state")
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    // Accessed only on stateQueue; URLSession delegates enqueue in delivery order.
    private var session: URLSession?
    private var currentTask: URLSessionDataTask?
    private var completion: ((Outcome) -> Void)?
    private var deadlineWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var requestID = ""
    private var requestBy: String?
    private var deadline: TimeInterval = 0
    private var response: HTTPURLResponse?
    private var buffer = Data()
    private var attempt = 0
    private var hasStarted = false
    private var hasFinished = false

    init?(
        endpointURL: URL, token: String, archiveOwner: String,
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseSize: Int = 1024 * 1024,
        totalBudget: TimeInterval = 8,
        requestTimeout: TimeInterval = 6.5,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduler: @escaping Scheduler = PushArchiveHTTPClient.liveScheduler,
        callbackQueue: DispatchQueue = .global(qos: .utility),
        diagnostic: ((String) -> Void)? = nil
    ) {
        guard Self.validEndpointURL(endpointURL), Self.validToken(token), !archiveOwner.isEmpty,
              maximumResponseSize > 0, totalBudget.isFinite, totalBudget > 0,
              requestTimeout.isFinite, requestTimeout > 0 else { return nil }
        self.endpointURL = endpointURL
        self.token = token
        self.archiveOwner = archiveOwner
        self.configuration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        self.maximumResponseSize = maximumResponseSize
        self.totalBudget = totalBudget
        self.requestTimeout = requestTimeout
        self.clock = clock
        self.scheduler = scheduler
        self.callbackQueue = callbackQueue
        self.diagnostic = diagnostic
        super.init()
    }

    func fetch(id: String, by: String? = nil, completion: @escaping (Outcome) -> Void) {
        stateQueue.async { [self] in
            guard !hasStarted else {
                diagnose("event=busy id=\(id) by=\(by ?? "")")
                callbackQueue.async { completion(.failure(.busy)) }
                return
            }
            hasStarted = true
            self.completion = completion
            requestID = id
            requestBy = by
            diagnose("event=start endpoint=\(endpointURL.absoluteString) id=\(id) by=\(by ?? "") owner=\(archiveOwner) budget=\(totalBudget)")
            guard !isCancellationRequested else { finish(.cancelled); return }
            guard Self.makeRequest(endpointURL: endpointURL, token: token, id: id, by: by) != nil else {
                finish(.failure(.invalidRequest))
                return
            }
            deadline = clock() + totalBudget
            deadlineWork = scheduler(totalBudget) { [weak self] in
                guard let self else { return }
                self.stateQueue.async {
                    if !self.hasFinished { self.diagnose("event=deadline budget=\(self.totalBudget)") }
                    self.finish(.failure(.timeout))
                }
            }
            startAttempt()
        }
    }

    func cancel() {
        diagnose("event=cancel_requested")
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        stateQueue.async { [self] in
            if hasStarted { finish(.cancelled) }
        }
    }

    private var isCancellationRequested: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    private func startAttempt() {
        guard !hasFinished else { return }
        guard !isCancellationRequested else { finish(.cancelled); return }
        let remaining = deadline - clock()
        guard remaining > 0 else { finish(.failure(.timeout)); return }
        guard var request = Self.makeRequest(endpointURL: endpointURL, token: token, id: requestID, by: requestBy) else {
            finish(.failure(.invalidRequest))
            return
        }
        request.timeoutInterval = min(requestTimeout, remaining)
        diagnose("event=request attempt=\(attempt + 1) method=\(request.httpMethod ?? "") url=\(request.url?.absoluteString ?? "") timeout=\(request.timeoutInterval) bodyBytes=\(request.httpBody?.count ?? 0)\n\(Self.headers(request.allHTTPHeaderFields ?? [:]))\n\(Self.body(request.httpBody ?? Data()))")
        if session == nil {
            let configuration = (self.configuration.copy() as? URLSessionConfiguration) ?? self.configuration
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = min(requestTimeout, totalBudget)
            configuration.timeoutIntervalForResource = totalBudget
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        }
        response = nil
        buffer.removeAll(keepingCapacity: false)
        retryWork = nil
        let task = session?.dataTask(with: request)
        currentTask = task
        task?.resume()
    }

    private func accepts(_ task: URLSessionTask) -> Bool {
        !hasFinished && currentTask?.taskIdentifier == task.taskIdentifier
    }

    private func handleFailure(_ outcome: Outcome, transient: Bool) {
        guard !hasFinished else { return }
        diagnose("event=failure outcome=\(Self.outcomeName(outcome)) attempt=\(attempt + 1) transient=\(transient)")
        currentTask?.cancel()
        currentTask = nil
        response = nil
        buffer.removeAll(keepingCapacity: false)
        guard !isCancellationRequested else { finish(.cancelled); return }
        // One transient retry shares the absolute budget with the first attempt.
        if transient, attempt == 0, deadline - clock() > 0.2 {
            attempt += 1
            diagnose("event=retry attempt=\(attempt + 1) delay=0.2 remaining=\(deadline - clock())")
            retryWork = scheduler(0.2) { [weak self] in
                guard let self else { return }
                self.stateQueue.async { self.startAttempt() }
            }
        } else {
            finish(outcome)
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !hasFinished else { return }
        hasFinished = true
        diagnose("event=finish outcome=\(Self.outcomeName(outcome)) attempt=\(attempt + 1)")
        let completion = self.completion
        self.completion = nil
        deadlineWork?.cancel()
        retryWork?.cancel()
        deadlineWork = nil
        retryWork = nil
        currentTask?.cancel()
        currentTask = nil
        buffer.removeAll(keepingCapacity: false)
        session?.invalidateAndCancel()
        session = nil
        guard let completion else { return }
        let deliver = { [self] in
            callbackQueue.async { [self] in
                completion(isCancellationRequested ? .cancelled : outcome)
            }
        }
        if diagnostic != nil {
            // The system may terminate an NSE as soon as it delivers content.
            // Flush queued diagnostics before making the final result visible;
            // never synchronously wait on a sink that may itself call cancel().
            diagnosticQueue.async(execute: deliver)
        } else {
            deliver()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        stateQueue.async { [self] in
            guard accepts(dataTask), !isCancellationRequested else {
                completionHandler(.cancel)
                return
            }
            guard deadline - clock() > 0 else {
                completionHandler(.cancel)
                finish(.failure(.timeout))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                diagnose("event=response_invalid value=\(response)")
                completionHandler(.cancel)
                finish(.failure(.invalidResponse))
                return
            }
            diagnose("event=response attempt=\(attempt + 1) status=\(response.statusCode) url=\(response.url?.absoluteString ?? "") mime=\(response.mimeType ?? "") expectedBytes=\(response.expectedContentLength)\n\(Self.headers(response.allHeaderFields))")
            guard response.url == dataTask.originalRequest?.url else {
                diagnose("event=response_body_unavailable reason=unexpected_url_header_rejected")
                completionHandler(.cancel)
                finish(.failure(.redirect))
                return
            }
            guard response.statusCode == 200 else {
                diagnose("event=response_body_unavailable reason=status_header_rejected")
                completionHandler(.cancel)
                let outcome: Outcome
                if response.statusCode == 401 { outcome = .unauthorized }
                else if (300..<400).contains(response.statusCode) { outcome = .failure(.redirect) }
                else { outcome = .failure(.http(response.statusCode)) }
                let transient = response.statusCode == 408 || response.statusCode == 429 || (500...599).contains(response.statusCode)
                handleFailure(outcome, transient: transient)
                return
            }
            guard let mime = response.mimeType?.lowercased(),
                  ["application/xml", "text/xml"].contains(mime) else {
                diagnose("event=response_body_unavailable reason=mime_header_rejected")
                completionHandler(.cancel)
                finish(.failure(.invalidResponse))
                return
            }
            guard response.expectedContentLength <= Int64(maximumResponseSize) else {
                diagnose("event=response_body_unavailable reason=declared_size_header_rejected")
                completionHandler(.cancel)
                finish(.failure(.oversizedResponse))
                return
            }
            self.response = response
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Backpressure keeps delegate-delivered chunks from accumulating in an
        // unbounded queue while parsing/state work is in progress.
        stateQueue.sync { [self] in
            guard accepts(dataTask) else { return }
            diagnose("event=response_chunk attempt=\(attempt + 1) offset=\(buffer.count) \(Self.body(data))")
            guard !isCancellationRequested else { finish(.cancelled); return }
            guard deadline - clock() > 0 else { finish(.failure(.timeout)); return }
            guard data.count <= maximumResponseSize - buffer.count else {
                finish(.failure(.oversizedResponse))
                return
            }
            buffer.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateQueue.async { [self] in
            guard accepts(task) else { return }
            guard !isCancellationRequested else { finish(.cancelled); return }
            guard deadline - clock() > 0 else { finish(.failure(.timeout)); return }
            if let error {
                let nsError = error as NSError
                diagnose("event=transport_error attempt=\(attempt + 1) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
                let transientCodes: Set<Int> = [
                    NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                    NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed
                ]
                handleFailure(
                    .failure(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut ? .timeout : .transport),
                    transient: nsError.domain == NSURLErrorDomain && transientCodes.contains(nsError.code)
                )
                return
            }
            guard let response else { finish(.failure(.invalidResponse)); return }
            diagnose("event=response_body attempt=\(attempt + 1) \(Self.body(buffer))")
            let result = Self.decodeResponse(
                data: buffer, statusCode: response.statusCode, expectedID: requestID,
                archiveOwner: requestBy ?? archiveOwner, maximumResponseSize: maximumResponseSize
            )
            diagnose("event=parser outcome=\(Self.outcomeName(result))")
            finish(result)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        stateQueue.async { [self] in
            guard accepts(task) else { return }
            diagnose("event=redirect status=\(response.statusCode) from=\(response.url?.absoluteString ?? "") to=\(request.url?.absoluteString ?? "")\n\(Self.headers(response.allHeaderFields))")
            finish(.failure(.redirect))
        }
    }

    private func diagnose(_ event: @autoclosure () -> String) {
        guard let diagnostic else { return }
        let message = "HTTP_ARCHIVE " + event()
        diagnosticQueue.async { diagnostic(message) }
    }

    private static func headers<Key: Hashable, Value>(_ headers: [Key: Value]) -> String {
        headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }

    private static func body(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return "encoding=utf8 bytes=\(data.count)\n\(text)"
        }
        return "encoding=base64 bytes=\(data.count)\n\(data.base64EncodedString())"
    }

    private static func outcomeName(_ outcome: Outcome) -> String {
        switch outcome {
        case .message: return "message"
        case .xmppError(let condition): return "xmppError.\(condition ?? "")"
        case .unauthorized: return "unauthorized"
        case .cancelled: return "cancelled"
        case .failure(let failure): return "failure.\(failure)"
        }
    }

    static func makeRequest(endpointURL: URL, token: String, id: String, by: String?) -> URLRequest? {
        guard validEndpointURL(endpointURL), validToken(token), !id.isEmpty,
              by.map({ !$0.isEmpty }) ?? true,
              var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
              !((components.queryItems ?? []).contains { $0.name == "id" || $0.name == "by" }) else { return nil }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var pairs: [String] = []
        if let existing = components.percentEncodedQuery, !existing.isEmpty { pairs.append(existing) }
        pairs.append("id=\(encodedID)")
        if let by {
            guard let encodedBy = by.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            pairs.append("by=\(encodedBy)")
        }
        components.percentEncodedQuery = pairs.joined(separator: "&")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func validEndpointURL(_ url: URL) -> Bool {
        url.baseURL == nil && url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && token.rangeOfCharacter(from: .controlCharacters) == nil
    }

    static func decodeResponse(
        data: Data, statusCode: Int, expectedID: String, archiveOwner: String,
        maximumResponseSize: Int = 1024 * 1024
    ) -> Outcome {
        if statusCode == 401 { return .unauthorized }
        guard statusCode == 200 else { return .failure(.http(statusCode)) }
        guard maximumResponseSize > 0, data.count <= maximumResponseSize else { return .failure(.oversizedResponse) }
        guard !expectedID.isEmpty, !archiveOwner.isEmpty,
              let xml = String(data: data, encoding: .utf8), !xml.isEmpty,
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else { return .failure(.invalidResponse) }

        // Current servers can return the MAM result followed by its final IQ.
        // Admit only that correlated pair, alongside the single-document profile.
        let document = try? DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document?.rootElement()
                ?? pairedMAMMessage(xml, expectedID: expectedID, archiveOwner: archiveOwner),
              stanza(root, name: "message") || stanza(root, name: "iq"),
              ownerMatches(root.attribute(forName: "from")?.stringValue, archiveOwner) else {
            return .failure(.invalidResponse)
        }
        if stanza(root, name: "iq") {
            guard root.attribute(forName: "type")?.stringValue == "error",
                  let id = root.attribute(forName: "id")?.stringValue, !id.isEmpty,
                  children(root, named: "error").count == 1,
                  let error = children(root, named: "error").first,
                  error.uri == root.uri else { return .failure(.invalidResponse) }
            let conditions = elements(error).filter {
                $0.uri == "urn:ietf:params:xml:ns:xmpp-stanzas" && $0.localName != "text"
            }
            guard conditions.count == 1 else { return .failure(.invalidResponse) }
            let known: Set<String> = ["bad-request", "conflict", "feature-not-implemented", "forbidden", "gone", "internal-server-error", "item-not-found", "jid-malformed", "not-acceptable", "not-allowed", "not-authorized", "policy-violation", "recipient-unavailable", "redirect", "registration-required", "remote-server-not-found", "remote-server-timeout", "resource-constraint", "service-unavailable", "subscription-required", "undefined-condition", "unexpected-request"]
            let condition = (conditions.first?.localName).flatMap { known.contains($0) ? $0 : nil }
            return .xmppError(condition)
        }
        let message = root
        let results = children(message, named: "result")
        guard results.count == 1, let result = results.first, result.uri == "urn:xmpp:mam:2",
              result.attribute(forName: "id")?.stringValue == expectedID else { return .failure(.invalidResponse) }
        let forwarded = children(result, named: "forwarded")
        guard forwarded.count == 1, let forward = forwarded.first, forward.uri == "urn:xmpp:forward:0",
              children(forward, named: "delay").count <= 1 else { return .failure(.invalidResponse) }
        let inner = children(forward, named: "message")
        guard inner.count == 1, let innerMessage = inner.first,
              [nil, "jabber:client", "urn:xmpp:forward:0"].contains(innerMessage.uri) else { return .failure(.invalidResponse) }
        guard let copy = message.copy() as? DDXMLElement else { return .failure(.invalidResponse) }
        return .message(copy)
    }

    private static func pairedMAMMessage(
        _ xml: String, expectedID: String, archiveOwner: String
    ) -> DDXMLElement? {
        // This wrapper is only a bounded parsing aid. It is never a supported
        // wire envelope and cannot make arbitrary XML streams valid responses.
        guard let document = try? DDXMLDocument(xmlString: "<http-mam-pair>\(xml)</http-mam-pair>", options: 0),
              let wrapper = document.rootElement() else { return nil }
        guard let stanzas = structuralElements(wrapper), stanzas.count == 2 else { return nil }
        let message = stanzas[0]
        let iq = stanzas[1]
        let mam = "urn:xmpp:mam:2"
        let rsm = "http://jabber.org/protocol/rsm"
        guard stanza(message, name: "message"), stanza(iq, name: "iq"),
              ownerMatches(message.attribute(forName: "from")?.stringValue, archiveOwner),
              message.attribute(forName: "from")?.stringValue == iq.attribute(forName: "from")?.stringValue,
              let recipient = message.attribute(forName: "to")?.stringValue, !recipient.isEmpty,
              recipient == iq.attribute(forName: "to")?.stringValue,
              iq.attribute(forName: "type")?.stringValue == "result",
              let queryID = iq.attribute(forName: "id")?.stringValue, !queryID.isEmpty,
              let messageChildren = structuralElements(message), messageChildren.count == 1,
              let result = messageChildren.first,
              result.localName == "result", result.uri == mam,
              result.attribute(forName: "id")?.stringValue == expectedID,
              result.attribute(forName: "queryid")?.stringValue == queryID,
              structuralElements(result)?.count == 1,
              let iqChildren = structuralElements(iq), iqChildren.count == 1, let fin = iqChildren.first,
              fin.localName == "fin", fin.uri == mam,
              ["true", "1"].contains(fin.attribute(forName: "complete")?.stringValue ?? ""),
              fin.attribute(forName: "queryid")?.stringValue == queryID,
              let finChildren = structuralElements(fin), finChildren.count == 1, let set = finChildren.first,
              set.localName == "set", set.uri == rsm else { return nil }
        guard let bounds = structuralElements(set), bounds.count == 2 || bounds.count == 3,
              bounds.allSatisfy({
                  $0.uri == rsm && ["first", "last", "count"].contains($0.localName ?? "")
                      && ($0.children ?? []).allSatisfy({ $0.kind == XMLTextKind })
              }),
              children(set, named: "first").count == 1,
              children(set, named: "last").count == 1,
              children(set, named: "first").first?.stringValue == expectedID,
              children(set, named: "last").first?.stringValue == expectedID,
              children(set, named: "count").count <= 1,
              children(set, named: "count").first.map({ $0.stringValue == "1" }) ?? true else { return nil }
        return message.copy() as? DDXMLElement
    }

    /// Service metadata admits only element children and formatting whitespace.
    /// This is deliberately not applied to the forwarded message/body content.
    private static func structuralElements(_ element: DDXMLElement) -> [DDXMLElement]? {
        var result: [DDXMLElement] = []
        for node in element.children ?? [] {
            if let child = node as? DDXMLElement {
                result.append(child)
            } else if node.kind != XMLTextKind
                        || !(node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
        }
        return result
    }

    private static func elements(_ element: DDXMLElement) -> [DDXMLElement] {
        (element.children ?? []).compactMap { $0 as? DDXMLElement }
    }

    private static func children(_ element: DDXMLElement, named name: String) -> [DDXMLElement] {
        elements(element).filter { $0.localName == name }
    }

    private static func stanza(_ element: DDXMLElement, name: String) -> Bool {
        element.localName == name && (element.uri == nil || element.uri == "jabber:client")
    }

    private static func ownerMatches(_ value: String?, _ expected: String) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.split(separator: "/", maxSplits: 1).first.map(String.init)
            == expected.split(separator: "/", maxSplits: 1).first.map(String.init)
    }
}
