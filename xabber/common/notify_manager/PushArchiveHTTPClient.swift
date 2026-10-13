import Foundation
import KissXML

/// Shared transport for the current server's base URL plus /archive API.
/// Each instance owns one fetch and never refreshes or mutates credentials.
final class PushArchiveHTTPClient: NSObject, URLSessionDataDelegate {
    enum Failure: Equatable {
        case invalidRequest, invalidResponse, oversizedResponse, redirect
        case http(Int)
        case transport, timeout, busy
    }

    enum Outcome {
        case message(DDXMLElement)
        case empty
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

    private let baseURL: URL
    private let token: String
    private let archiveOwner: String
    private let configuration: URLSessionConfiguration
    private let maximumResponseSize: Int
    private let totalBudget: TimeInterval
    private let requestTimeout: TimeInterval
    private let clock: () -> TimeInterval
    private let scheduler: Scheduler
    private let callbackQueue: DispatchQueue
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
        baseURL: URL, token: String, archiveOwner: String,
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseSize: Int = 1024 * 1024,
        totalBudget: TimeInterval = 8,
        requestTimeout: TimeInterval = 6.5,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduler: @escaping Scheduler = PushArchiveHTTPClient.liveScheduler,
        callbackQueue: DispatchQueue = .global(qos: .utility)
    ) {
        guard Self.validBaseURL(baseURL), Self.validToken(token), !archiveOwner.isEmpty,
              maximumResponseSize > 0, totalBudget.isFinite, totalBudget > 0,
              requestTimeout.isFinite, requestTimeout > 0 else { return nil }
        self.baseURL = baseURL
        self.token = token
        self.archiveOwner = archiveOwner
        self.configuration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        self.maximumResponseSize = maximumResponseSize
        self.totalBudget = totalBudget
        self.requestTimeout = requestTimeout
        self.clock = clock
        self.scheduler = scheduler
        self.callbackQueue = callbackQueue
        super.init()
    }

    func fetch(id: String, by: String? = nil, completion: @escaping (Outcome) -> Void) {
        stateQueue.async { [self] in
            guard !hasStarted else {
                callbackQueue.async { completion(.failure(.busy)) }
                return
            }
            hasStarted = true
            self.completion = completion
            requestID = id
            requestBy = by
            guard !isCancellationRequested else { finish(.cancelled); return }
            guard Self.makeRequest(baseURL: baseURL, token: token, id: id, by: by) != nil else {
                finish(.failure(.invalidRequest))
                return
            }
            deadline = clock() + totalBudget
            deadlineWork = scheduler(totalBudget) { [weak self] in
                guard let self else { return }
                self.stateQueue.async { self.finish(.failure(.timeout)) }
            }
            startAttempt()
        }
    }

    func cancel() {
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
        guard var request = Self.makeRequest(baseURL: baseURL, token: token, id: requestID, by: requestBy) else {
            finish(.failure(.invalidRequest))
            return
        }
        request.timeoutInterval = min(requestTimeout, remaining)
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
        currentTask?.cancel()
        currentTask = nil
        response = nil
        buffer.removeAll(keepingCapacity: false)
        guard !isCancellationRequested else { finish(.cancelled); return }
        // One transient retry shares the absolute budget with the first attempt.
        if transient, attempt == 0, deadline - clock() > 0.2 {
            attempt += 1
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
        callbackQueue.async { [self] in
            completion(isCancellationRequested ? .cancelled : outcome)
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
                completionHandler(.cancel)
                finish(.failure(.invalidResponse))
                return
            }
            guard response.url == dataTask.originalRequest?.url else {
                completionHandler(.cancel)
                finish(.failure(.redirect))
                return
            }
            guard response.statusCode == 200 else {
                completionHandler(.cancel)
                let outcome: Outcome
                if response.statusCode == 401 { outcome = .unauthorized }
                else if (300..<400).contains(response.statusCode) { outcome = .failure(.redirect) }
                else { outcome = .failure(.http(response.statusCode)) }
                let transient = response.statusCode == 408 || response.statusCode == 429 || (500...599).contains(response.statusCode)
                handleFailure(outcome, transient: transient)
                return
            }
            guard response.expectedContentLength <= Int64(maximumResponseSize) else {
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
            let result = Self.decodeResponse(
                data: buffer, statusCode: response.statusCode, expectedID: requestID,
                archiveOwner: requestBy ?? archiveOwner, maximumResponseSize: maximumResponseSize
            )
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
            finish(.failure(.redirect))
        }
    }

    static func makeRequest(baseURL: URL, token: String, id: String, by: String?) -> URLRequest? {
        guard validBaseURL(baseURL), validToken(token), !id.isEmpty,
              by.map({ !$0.isEmpty }) ?? true,
              var components = URLComponents(url: baseURL.appendingPathComponent("archive", isDirectory: false), resolvingAgainstBaseURL: false),
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
        return request
    }

    private static func validBaseURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
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

        let roots: [DDXMLElement]
        if let document = try? DDXMLDocument(xmlString: xml, options: 0), let root = document.rootElement() {
            roots = [root]
        } else if let document = try? DDXMLDocument(xmlString: "<archive-envelope>\(xml)</archive-envelope>", options: 0),
                  let root = document.rootElement(), let nodes = root.children,
                  nodes.allSatisfy({ node in
                      node is DDXMLElement || (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || node.xmlString.hasPrefix("<!--") || node.xmlString.hasPrefix("<?")
                  }) {
            roots = nodes.compactMap { $0 as? DDXMLElement }
        } else { return .failure(.invalidResponse) }
        guard !roots.isEmpty, roots.count <= 2,
              roots.allSatisfy({ stanza($0, name: "message") || stanza($0, name: "iq") }) else { return .failure(.invalidResponse) }
        let messages = roots.filter { $0.localName == "message" }
        let finals = roots.filter { $0.localName == "iq" }
        guard messages.count <= 1, finals.count <= 1,
              roots.allSatisfy({ ownerMatches($0.attribute(forName: "from")?.stringValue, archiveOwner) }) else { return .failure(.invalidResponse) }

        if let final = finals.first, final.attribute(forName: "type")?.stringValue == "error" {
            guard messages.isEmpty, let id = final.attribute(forName: "id")?.stringValue, !id.isEmpty,
                  children(final, named: "error").count == 1,
                  let error = children(final, named: "error").first,
                  error.uri == nil || error.uri == "jabber:client" else { return .failure(.invalidResponse) }
            let conditions = elements(error).filter { $0.uri == "urn:ietf:params:xml:ns:xmpp-stanzas" && $0.localName != "text" }
            guard conditions.count <= 1 else { return .failure(.invalidResponse) }
            let known: Set<String> = ["bad-request", "conflict", "feature-not-implemented", "forbidden", "gone", "internal-server-error", "item-not-found", "jid-malformed", "not-acceptable", "not-allowed", "not-authorized", "policy-violation", "recipient-unavailable", "redirect", "registration-required", "remote-server-not-found", "remote-server-timeout", "resource-constraint", "service-unavailable", "subscription-required", "undefined-condition", "unexpected-request"]
            let condition = (conditions.first?.localName).flatMap { known.contains($0) ? $0 : nil }
            return .xmppError(condition)
        }

        var finalID: String?
        if let final = finals.first {
            let finishes = children(final, named: "fin")
            guard final.attribute(forName: "type")?.stringValue == "result",
                  let id = final.attribute(forName: "id")?.stringValue, !id.isEmpty,
                  finishes.count == 1, let fin = finishes.first, fin.uri == "urn:xmpp:mam:2",
                  children(final, named: "error").isEmpty,
                  (fin.attribute(forName: "queryid")?.stringValue).map({ $0 == id }) ?? true else { return .failure(.invalidResponse) }
            finalID = id
        }
        guard let message = messages.first else { return finalID == nil ? .failure(.invalidResponse) : .empty }
        if finals.count == 1, roots.last?.localName != "iq" { return .failure(.invalidResponse) }
        let results = children(message, named: "result")
        guard results.count == 1, let result = results.first, result.uri == "urn:xmpp:mam:2",
              result.attribute(forName: "id")?.stringValue == expectedID,
              finalID.map({ result.attribute(forName: "queryid")?.stringValue == $0 }) ?? true else { return .failure(.invalidResponse) }
        let forwarded = children(result, named: "forwarded")
        guard forwarded.count == 1, let forward = forwarded.first, forward.uri == "urn:xmpp:forward:0",
              children(forward, named: "delay").count <= 1 else { return .failure(.invalidResponse) }
        let inner = children(forward, named: "message")
        guard inner.count == 1, let innerMessage = inner.first,
              [nil, "jabber:client", "urn:xmpp:forward:0"].contains(innerMessage.uri) else { return .failure(.invalidResponse) }
        guard let copy = message.copy() as? DDXMLElement else { return .failure(.invalidResponse) }
        return .message(copy)
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
