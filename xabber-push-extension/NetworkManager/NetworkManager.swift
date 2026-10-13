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

/// NSE presentation adapter; the shared client owns HTTP validation and lifetime.
final class NetworkManager {
    private let client: PushArchiveHTTPClient
    private let jid: String
    private let stateLock = NSLock()
    private var hasStarted = false
    private var cancelled = false
    private var didReceiveOutcome = false
    private var callbackTask: Task<Void, Never>?

    weak var delegate: PushPayloadDelegate?

    init?(service url: String, jid: String, jwt: String) {
        guard let url = URL(string: url),
              let client = PushArchiveHTTPClient(baseURL: url, token: jwt, archiveOwner: jid) else { return nil }
        self.client = client
        self.jid = jid
    }

    func getMessage(host: String, messageId: String, by: String?, retry: Int? = nil) {
        stateLock.lock()
        guard !cancelled, !hasStarted else { stateLock.unlock(); return }
        hasStarted = true
        stateLock.unlock()
        // The server selects the account from the bearer token; Xmpp-Domain is
        // not an authorization input. Retry is internal to the shared client.
        client.fetch(id: messageId, by: by) { [weak self] outcome in
            self?.receive(outcome)
        }
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let task = callbackTask
        callbackTask = nil
        stateLock.unlock()
        client.cancel()
        task?.cancel()
    }

    private var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !cancelled
    }

    private func receive(_ outcome: PushArchiveHTTPClient.Outcome) {
        stateLock.lock()
        guard !cancelled, !didReceiveOutcome else { stateLock.unlock(); return }
        didReceiveOutcome = true
        stateLock.unlock()
        switch outcome {
        case .message(let message):
            guard let preview = PushNotificationArchiveParser.parseHTTPArchivedMessage(message, owner: jid) else {
                if isActive { delegate?.networkManager(self, didDisconnectWithError: "archive unavailable") }
                return
            }
            stateLock.lock()
            guard !cancelled else { stateLock.unlock(); return }
            callbackTask = Task { [weak self] in
                guard let self, !Task.isCancelled, self.isActive else { return }
                defer { self.clearCallbackTask() }
                await self.delegate?.networkManager(self, didUpdateContent: preview)
            }
            stateLock.unlock()
        case .unauthorized:
            if isActive { delegate?.networkManagerDidRejectAuthorization(self) }
        case .cancelled:
            break
        case .empty, .xmppError, .failure:
            if isActive { delegate?.networkManager(self, didDisconnectWithError: "archive unavailable") }
        }
    }

    private func clearCallbackTask() {
        stateLock.lock()
        callbackTask = nil
        stateLock.unlock()
    }
}

protocol PushPayloadDelegate: AnyObject {
    func networkManager(_ manager: NetworkManager, didDisconnectWithError error: String)
    func networkManagerDidRejectAuthorization(_ manager: NetworkManager)
    func networkManager(_ manager: NetworkManager, didUpdateContent preview: PushNotificationPreview) async
    func didReceiveSync(stanza: String)
}

extension PushPayloadDelegate {
    func networkManagerDidRejectAuthorization(_ manager: NetworkManager) {
        networkManager(manager, didDisconnectWithError: "archive unavailable")
    }
}
