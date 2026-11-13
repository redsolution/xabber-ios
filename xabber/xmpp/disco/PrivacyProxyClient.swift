import Foundation
import XMPPFramework

enum PrivacyProxyClientError: Error, Equatable {
    case unavailable
    case invalidSource
    case invalidResponse
    case confirmationTimedOut
    case httpStatus(Int)
}

actor PrivacyProxyClient {
    static let shared = PrivacyProxyClient(
        contextForOwner: AccountProxyAuthenticationContext.load,
        transport: PrivacyProxyHTTPTransport.send
    )

    struct Context {
        let endpoint: URL
        let stream: XMPPStream
        let fullJID: String
        let authenticationGeneration: UInt64?
        let isCurrent: () async -> Bool
        let acknowledge: (XMPPIQ) async -> Bool

        var key: ContextKey {
            ContextKey(
                endpoint: endpoint,
                stream: ObjectIdentifier(stream),
                fullJID: fullJID,
                authenticationGeneration: authenticationGeneration
            )
        }
    }

    struct ContextKey: Equatable {
        let endpoint: URL
        let stream: ObjectIdentifier
        let fullJID: String
        let authenticationGeneration: UInt64?
    }

    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private struct CodeRequest: Encodable {
        let jid: String
        let type = "iq"
    }

    private struct CodeResponse: Decodable {
        let requestID: String
        let apiJID: String

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case apiJID = "api_jid"
        }
    }

    private struct ConfirmRequest: Encodable {
        let jid: String
        let code: String
    }

    private struct TokenResponse: Decodable {
        let token: String
        let expires: String
    }

    private struct URLResponse: Decodable {
        let url: URL
    }

    private struct Token {
        let id = UUID()
        let value: String
        let expires: Date
        let context: ContextKey
    }

    private struct Authorization {
        let id: UUID
        let context: ContextKey
        let task: Task<Token, Error>
    }

    private let contextForOwner: (String) async -> Context?
    private let transport: Transport
    private let confirmationTimeout: TimeInterval
    private nonisolated let confirmations = PrivacyProxyConfirmations()
    private var tokens: [String: Token] = [:]
    private var authorizations: [String: Authorization] = [:]

    init(
        contextForOwner: @escaping (String) async -> Context?,
        transport: @escaping Transport,
        confirmationTimeout: TimeInterval = 10
    ) {
        self.contextForOwner = contextForOwner
        self.transport = transport
        self.confirmationTimeout = confirmationTimeout
    }

    func resolve(originalURL: URL, owner: String) async throws -> URL {
        guard let source = Self.sourceURL(originalURL) else { throw PrivacyProxyClientError.invalidSource }
        guard let owner = XMPPJID(string: owner)?.bare,
              let context = await contextForOwner(owner) else {
            throw PrivacyProxyClientError.unavailable
        }

        var token = try await authorizationToken(for: owner, context: context)
        var (data, response) = try await lookup(source, context: context, token: token)
        if response.statusCode == 401 {
            discard(token, owner: owner)
            token = try await authorizationToken(for: owner, context: context)
            (data, response) = try await lookup(source, context: context, token: token)
            if response.statusCode == 401 {
                discard(token, owner: owner)
            }
        }
        try Self.requireSuccess(response)
        let result = try JSONDecoder().decode(URLResponse.self, from: data).url
        guard Self.isProxiedFileURL(result, endpoint: context.endpoint) else {
            throw PrivacyProxyClientError.invalidResponse
        }
        guard await context.isCurrent() else { throw PrivacyProxyClientError.unavailable }
        try Task.checkCancellation()
        return result
    }

    nonisolated func read(_ iq: XMPPIQ, from stream: XMPPStream, owner: String) -> Bool {
        confirmations.receive(iq, stream: stream, owner: owner)
    }

    nonisolated func streamDidDisconnect(_ stream: XMPPStream, owner: String) {
        let streamID = ObjectIdentifier(stream)
        confirmations.cancel(owner: owner, streamID: streamID)
        Task { await invalidate(owner: owner, streamID: streamID) }
    }

    private func invalidate(owner: String, streamID: ObjectIdentifier) {
        if authorizations[owner]?.context.stream == streamID {
            authorizations.removeValue(forKey: owner)?.task.cancel()
        }
        if tokens[owner]?.context.stream == streamID {
            tokens.removeValue(forKey: owner)
        }
    }

    private func discard(_ token: Token, owner: String) {
        if tokens[owner]?.id == token.id {
            tokens.removeValue(forKey: owner)
        }
    }

    private func lookup(
        _ source: URL,
        context: Context,
        token: Token
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard await context.isCurrent(),
              let url = Self.lookupURL(source: source, endpoint: context.endpoint) else {
            throw PrivacyProxyClientError.unavailable
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
        return try await transport(request)
    }

    private func authorizationToken(for owner: String, context: Context) async throws -> Token {
        try Task.checkCancellation()
        guard await context.isCurrent() else { throw PrivacyProxyClientError.unavailable }
        if let token = tokens[owner],
           token.context == context.key,
           token.expires.timeIntervalSinceNow > 30 {
            return token
        }
        let authorization: Authorization
        if let active = authorizations[owner], active.context == context.key {
            authorization = active
        } else {
            tokens.removeValue(forKey: owner)
            authorizations.removeValue(forKey: owner)?.task.cancel()
            let id = UUID()
            let task = Task { try await self.authorize(owner: owner, context: context, id: id) }
            authorization = Authorization(id: id, context: context.key, task: task)
            authorizations[owner] = authorization
        }

        do {
            let token = try await authorization.task.value
            if authorizations[owner]?.id == authorization.id {
                authorizations.removeValue(forKey: owner)
                tokens[owner] = token
            }
            return token
        } catch {
            if authorizations[owner]?.id == authorization.id {
                authorizations.removeValue(forKey: owner)
            }
            throw error
        }
    }

    private func authorize(owner: String, context: Context, id: UUID) async throws -> Token {
        try Task.checkCancellation()
        guard await context.isCurrent(), authorizations[owner]?.id == id else {
            throw PrivacyProxyClientError.unavailable
        }
        let stream = confirmations.begin(owner: owner, context: context, id: id)
        defer { confirmations.finish(owner: owner, id: id) }

        let request = try Self.makePOST(
            context.endpoint.appendingPathComponent("xmpp_auth/code_request", isDirectory: true),
            body: CodeRequest(jid: context.fullJID)
        )
        let (codeData, codeHTTP) = try await transport(request)
        try Self.requireSuccess(codeHTTP)
        let codeResponse = try JSONDecoder().decode(CodeResponse.self, from: codeData)
        guard !codeResponse.requestID.isEmpty,
              let apiJID = XMPPJID(string: codeResponse.apiJID) else {
            throw PrivacyProxyClientError.invalidResponse
        }

        confirmations.expect(owner: owner, id: id, requestID: codeResponse.requestID, sender: apiJID)
        let timeout = Task { [confirmations, confirmationTimeout] in
            do {
                try await Task.sleep(nanoseconds: UInt64(confirmationTimeout * 1_000_000_000))
                confirmations.finish(owner: owner, id: id)
            } catch {}
        }
        defer { timeout.cancel() }

        for await confirmation in stream {
            try Task.checkCancellation()
            guard confirmation.requestID == codeResponse.requestID,
                  PrivacyProxyConfirmations.matchesSender(confirmation.sender, expected: apiJID) else { continue }
            guard await context.acknowledge(confirmation.acknowledgement) else {
                throw PrivacyProxyClientError.unavailable
            }
            let exchange = try Self.makePOST(
                context.endpoint.appendingPathComponent("xmpp_auth/confirm", isDirectory: true),
                body: ConfirmRequest(jid: owner, code: confirmation.code)
            )
            let (tokenData, tokenHTTP) = try await transport(exchange)
            try Self.requireSuccess(tokenHTTP)
            let response = try JSONDecoder().decode(TokenResponse.self, from: tokenData)
            guard !response.token.isEmpty,
                  response.token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
                  let expires = Self.tokenExpiry(response.expires),
                  expires > Date() else {
                throw PrivacyProxyClientError.invalidResponse
            }
            try Task.checkCancellation()
            guard await context.isCurrent() else { throw PrivacyProxyClientError.unavailable }
            return Token(value: response.token, expires: expires, context: context.key)
        }
        try Task.checkCancellation()
        guard await context.isCurrent() else { throw PrivacyProxyClientError.unavailable }
        throw PrivacyProxyClientError.confirmationTimedOut
    }

    private static func requireSuccess(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw PrivacyProxyClientError.httpStatus(response.statusCode)
        }
    }

    private static func makePOST<T: Encodable>(_ url: URL, body: T) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func sourceURL(_ url: URL) -> URL? {
        guard var source = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = source.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              source.host?.isEmpty == false,
              source.user == nil, source.password == nil else { return nil }
        source.fragment = nil
        return source.url
    }

    private static func lookupURL(source: URL, endpoint: URL) -> URL? {
        let lookup = endpoint.appendingPathComponent("proxy/geturl", isDirectory: true)
        guard var components = URLComponents(url: lookup, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: source.absoluteString)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    static func isProxiedFileURL(_ url: URL, endpoint: URL) -> Bool {
        guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              sameHTTPSOrigin(candidate, base),
              candidate.user == nil, candidate.password == nil,
              candidate.fragment == nil else { return false }
        let prefix = endpoint.appendingPathComponent("proxy/files", isDirectory: true).path
        let path = candidate.path
        let directory = prefix.hasSuffix("/") ? prefix : prefix + "/"
        guard path.hasPrefix(directory), !path.contains("\\"), !path.contains("//") else { return false }
        let fileID = path.dropFirst(directory.count).split(separator: "/")
        return fileID.count == 1 && fileID[0] != "." && fileID[0] != ".."
    }

    fileprivate static func sameHTTPSOrigin(_ lhs: URLComponents, _ rhs: URLComponents) -> Bool {
        lhs.scheme?.lowercased() == "https" && rhs.scheme?.lowercased() == "https"
            && lhs.host?.isEmpty == false && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private static func tokenExpiry(_ value: String) -> Date? {
        let normalized = value.hasSuffix("+00:00Z") ? String(value.dropLast(7)) + "Z" : value
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }
}

/// The stream delegate admits candidates synchronously. Only the actor can
/// exchange a code after the HTTP response identifies the request and sender.
private final class PrivacyProxyConfirmations: @unchecked Sendable {
    struct Confirmation {
        let requestID: String
        let sender: XMPPJID
        let code: String
        let acknowledgement: XMPPIQ
    }

    private struct Pending {
        let id: UUID
        let streamID: ObjectIdentifier
        let fullJID: String
        let confirmURL: URL
        let continuation: AsyncStream<Confirmation>.Continuation
        var requestID: String?
        var sender: XMPPJID?
        var early: [Confirmation] = []
        var delivered = false
    }

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]

    func begin(owner: String, context: PrivacyProxyClient.Context, id: UUID) -> AsyncStream<Confirmation> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.lock()
            let previous = pending.updateValue(
                Pending(
                    id: id,
                    streamID: ObjectIdentifier(context.stream),
                    fullJID: context.fullJID,
                    confirmURL: context.endpoint.appendingPathComponent("xmpp_auth/code_request/confirm"),
                    continuation: continuation
                ),
                forKey: owner
            )
            lock.unlock()
            previous?.continuation.finish()
        }
    }

    func receive(_ iq: XMPPIQ, stream: XMPPStream, owner: String) -> Bool {
        guard iq.iqType == .get,
              let requestID = iq.elementID, !requestID.isEmpty,
              let sender = iq.from,
              let confirm = iq.element(forName: "confirm", xmlns: "http://jabber.org/protocol/http-auth"),
              let code = confirm.attributeStringValue(forName: "id"), !code.isEmpty,
              (confirm.attributeStringValue(forName: "method") ?? "POST") == "POST",
              let rawURL = confirm.attributeStringValue(forName: "url"),
              let url = URLComponents(string: rawURL) else { return false }

        lock.lock()
        defer { lock.unlock() }
        guard var operation = pending[owner],
              operation.streamID == ObjectIdentifier(stream),
              iq.to.map({ $0.full == operation.fullJID }) ?? true,
              let expectedURL = URLComponents(url: operation.confirmURL, resolvingAgainstBaseURL: false),
              Self.matchesConfirmationURL(url, expected: expectedURL) else { return false }

        let candidate = Confirmation(
            requestID: requestID,
            sender: sender,
            code: code,
            acknowledgement: XMPPIQ(iqType: .result, to: sender, elementID: requestID)
        )
        if let expectedRequestID = operation.requestID, let expectedSender = operation.sender {
            guard requestID == expectedRequestID, Self.matchesSender(sender, expected: expectedSender) else {
                return false
            }
            if !operation.delivered {
                operation.delivered = true
                pending[owner] = operation
                operation.continuation.yield(candidate)
            }
        } else {
            let duplicate = operation.early.contains { $0.requestID == requestID && $0.sender.full == sender.full }
            if !duplicate, operation.early.count < 8 {
                operation.early.append(candidate)
                pending[owner] = operation
            }
        }
        return true
    }

    func expect(owner: String, id: UUID, requestID: String, sender: XMPPJID) {
        lock.lock()
        defer { lock.unlock() }
        guard var operation = pending[owner], operation.id == id else { return }
        operation.requestID = requestID
        operation.sender = sender
        let matched = operation.early.first {
            $0.requestID == requestID && Self.matchesSender($0.sender, expected: sender)
        }
        operation.early.removeAll()
        operation.delivered = matched != nil
        pending[owner] = operation
        if let matched {
            operation.continuation.yield(matched)
        }
    }

    func finish(owner: String, id: UUID) {
        lock.lock()
        let operation = pending[owner]?.id == id ? pending.removeValue(forKey: owner) : nil
        lock.unlock()
        operation?.continuation.finish()
    }

    func cancel(owner: String, streamID: ObjectIdentifier) {
        lock.lock()
        let operation = pending[owner]?.streamID == streamID ? pending.removeValue(forKey: owner) : nil
        lock.unlock()
        operation?.continuation.finish()
    }

    static func matchesSender(_ candidate: XMPPJID, expected: XMPPJID) -> Bool {
        if expected.resource != nil {
            return candidate.full == expected.full
        }
        return candidate.bare == expected.bare
    }

    private static func matchesConfirmationURL(_ candidate: URLComponents, expected: URLComponents) -> Bool {
        guard PrivacyProxyClient.sameHTTPSOrigin(candidate, expected),
              candidate.user == nil, candidate.password == nil,
              candidate.query == nil, candidate.fragment == nil else { return false }
        let path = candidate.percentEncodedPath
        return path == expected.percentEncodedPath || path == expected.percentEncodedPath + "/"
    }
}

private struct AccountProxyAuthenticationContext {
    static func load(owner: String) async -> PrivacyProxyClient.Context? {
        guard let account = AccountManager.shared.find(for: owner) else { return nil }
        return await withCheckedContinuation { continuation in
            account.action { account, stream in
                guard AccountManager.shared.find(for: owner) === account,
                      stream.isAuthenticated, stream.isSecure, !stream.isDisconnected,
                      let jid = stream.myJID, jid.bare == owner, jid.resource?.isEmpty == false,
                      case .advertised(let endpoint) = account.disco.privacyProxyDiscovery else {
                    continuation.resume(returning: nil)
                    return
                }
                let generation = account.devices.authenticatedSessionGeneration(on: stream)
                let fullJID = jid.full

                func withCurrentStream(_ action: @escaping (XMPPStream) -> Void) async -> Bool {
                    await withCheckedContinuation { result in
                        account.action { account, current in
                            guard AccountManager.shared.find(for: owner) === account,
                                  current === stream, current.isAuthenticated, current.isSecure, !current.isDisconnected,
                                  current.myJID?.full == fullJID,
                                  account.devices.authenticatedSessionGeneration(on: current) == generation,
                                  account.disco.privacyProxyDiscovery == .advertised(endpoint) else {
                                result.resume(returning: false)
                                return
                            }
                            action(current)
                            result.resume(returning: true)
                        }
                    }
                }

                continuation.resume(returning: PrivacyProxyClient.Context(
                    endpoint: endpoint,
                    stream: stream,
                    fullJID: fullJID,
                    authenticationGeneration: generation,
                    isCurrent: { await withCurrentStream { _ in } },
                    acknowledge: { iq in await withCurrentStream { $0.send(iq) } }
                ))
            }
        }
    }
}

private final class PrivacyProxyHTTPTransport: NSObject, URLSessionTaskDelegate {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: PrivacyProxyHTTPTransport(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw PrivacyProxyClientError.invalidResponse
        }
        if !(200..<300).contains(response.statusCode) {
            bytes.task.cancel()
            return (Data(), response)
        }
        let maximumResponseBytes = 32 * 1024
        guard response.expectedContentLength <= maximumResponseBytes else {
            bytes.task.cancel()
            throw PrivacyProxyClientError.invalidResponse
        }

        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                bytes.task.cancel()
                throw PrivacyProxyClientError.invalidResponse
            }
            data.append(byte)
        }
        return (data, response)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
