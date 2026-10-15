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

    init?(credentials: PushCredentialRecord) {
        let now = Date()
        guard let grant = credentials.httpArchive,
              grant.isUsable(forAccount: credentials.jid, host: credentials.host, now: now),
              credentials.tokenExpiresAt.map({ $0 > now }) == true,
              let url = URL(string: grant.endpoint),
              let client = PushArchiveHTTPClient(endpointURL: url, token: grant.token,
                                                archiveOwner: credentials.jid,
                                                diagnostic: PushExtensionDiagnostics.sink) else {
            PushExtensionDiagnostics.log("event=archive_client_rejected owner=\(credentials.jid)")
            return nil
        }
        self.client = client
        self.jid = credentials.jid
        PushExtensionDiagnostics.log("event=archive_client_ready endpoint=\(url.absoluteString)")
    }

    func getMessage(messageId: String, by: String?) {
        PushExtensionDiagnostics.log("event=archive_adapter_fetch id=\(messageId) by=\(by ?? "none")")
        stateLock.lock()
        guard !cancelled, !hasStarted else { stateLock.unlock(); return }
        hasStarted = true
        stateLock.unlock()
        // Use only the discovered by-id endpoint and its MAM-scoped token.
        client.fetch(id: messageId, by: by) { [weak self] outcome in
            self?.receive(outcome)
        }
    }

    func cancel() {
        PushExtensionDiagnostics.log("event=archive_adapter_cancel")
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
        PushExtensionDiagnostics.log("event=archive_adapter_outcome value=\(outcome)")
        stateLock.lock()
        guard !cancelled, !didReceiveOutcome else { stateLock.unlock(); return }
        didReceiveOutcome = true
        stateLock.unlock()
        switch outcome {
        case .message(let message):
            guard let preview = PushNotificationArchiveParser.parseHTTPArchivedMessage(message, owner: jid) else {
                PushExtensionDiagnostics.log("event=archive_preview_rejected\n\(message.xmlString(withOptions: 0))")
                if isActive { delegate?.networkManager(self, didDisconnectWithError: "archive unavailable") }
                return
            }
            PushExtensionDiagnostics.log("event=archive_preview_parsed route=\(preview.route) body=\(preview.body)")
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
        case .xmppError, .failure:
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
