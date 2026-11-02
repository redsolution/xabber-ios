import Foundation
import XMPPFramework

/// Ephemeral server authorization. It is deliberately separate from the UI's
/// mutable Devices projection and from protected OMEMO identity/session state.
internal final class OMEMO2ManagedDevicesPublication {
    struct Binding: Equatable {
        let owner: String
        let fullJID: String
        let deviceID: String? // nil only for an actually accepted legacy HOTP session.
        let authGeneration: UInt64
        let managerGeneration: UInt64
        let localSID: Int
        let streamID: ObjectIdentifier
    }
    struct Signature: Equatable {
        let binding: Binding
        let serverSID: Int?
    }
    final class Authorization {
        weak var stream: XMPPStream?
        let signature: Signature
        init(stream: XMPPStream, binding: Binding, serverSID: Int?) {
            self.stream = stream
            self.signature = Signature(binding: binding, serverSID: serverSID)
        }
    }
    enum Operation {
        case metadata(afterRetraction: Int?)
        case retract(oldSID: Int)
    }
    final class Request {
        weak var stream: XMPPStream?
        let id: String
        let binding: Binding
        let operation: Operation
        let startedAt: Date
        init(stream: XMPPStream, id: String, binding: Binding, operation: Operation, startedAt: Date) {
            self.stream = stream; self.id = id; self.binding = binding
            self.operation = operation; self.startedAt = startedAt
        }
    }
    var generation: UInt64 = 0
    var pending: Request?
    var authorization: Authorization?
    var publications: [String: Authorization] = [:]
    var blocked: Signature?
    var withdrawalRequested = false
}

extension OmemoManager {
    private static let devicesMetadataNamespace = "https://xabber.com/protocol/devices#items"
    private static let devicesNamespace = "https://xabber.com/protocol/devices"

    internal func managedDevicesBinding(on stream: XMPPStream, localSID: Int) -> OMEMO2ManagedDevicesPublication.Binding? {
        guard omemo2Storage?.owner == owner,
              stream.isAuthenticated, !stream.isDisconnected,
              stream.myJID?.bare == owner, let full = stream.myJID?.full,
              stream.myJID?.resource?.isEmpty == false,
              let devices = AccountManager.shared.find(for: owner)?.devices,
              let epoch = devices.authenticatedSessionGeneration(on: stream) else { return nil }
        let uuid = devices.authenticatedDeviceID(on: stream)
        guard uuid != nil || devices.authenticatedLegacyHOTP(on: stream) else { return nil }
        return .init(owner: owner, fullJID: full, deviceID: uuid,
            authGeneration: epoch, managerGeneration: omemo2ManagedDevicesPublication.generation,
            localSID: localSID, streamID: ObjectIdentifier(stream))
    }

    internal func resetManagedDevicesPublication() {
        let state = omemo2ManagedDevicesPublication
        if let request = state.pending { queryIds.remove(request.id) }
        for id in state.publications.keys {
            queryIds.remove(id); omemo2BundlePublications.removeValue(forKey: id)
            omemo2BundlePublicationStartedAt.removeValue(forKey: id)
        }
        state.pending = nil; state.authorization = nil; state.publications.removeAll()
        state.blocked = nil; state.withdrawalRequested = false; state.generation &+= 1
    }

    /// Returns true only after a current strong metadata proof (or accepted
    /// legacy HOTP compatibility proof). A queued lookup is not publication.
    internal func prepareManagedDevicesPublication(on stream: XMPPStream, localSID: Int) -> Bool {
        let state = omemo2ManagedDevicesPublication
        state.withdrawalRequested = false
        guard let binding = managedDevicesBinding(on: stream, localSID: localSID) else {
            shouldPublicate = true
            omemo2PublicationRetryAt = omemo2MaintenanceNow().addingTimeInterval(Self.omemo2PublicationRetryInterval)
            return false
        }
        for id in Array(state.publications.keys) where omemo2BundlePublications[id] == nil { state.publications.removeValue(forKey: id) }
        if binding.deviceID == nil, state.blocked?.binding == binding {
            shouldPublicate = false; omemo2PublicationRetryAt = nil; return false
        }
        if let pending = state.pending {
            if case .retract = pending.operation { return false }
            if pending.stream === stream, pending.binding == binding { return false }
        }
        if !state.publications.isEmpty { return false }
        if let proof = state.authorization, proof.stream === stream,
           proof.signature.binding == binding, state.blocked != proof.signature { return true }
        discardManagedDevicesRequest()
        state.authorization = nil
        if binding.deviceID == nil {
            let proof = OMEMO2ManagedDevicesPublication.Authorization(stream: stream, binding: binding, serverSID: nil)
            guard state.blocked != proof.signature else { shouldPublicate = false; omemo2PublicationRetryAt = nil; return false }
            state.authorization = proof
            return true
        }
        requestManagedDevicesMetadata(on: stream, binding: binding, afterRetraction: nil)
        return false
    }

    internal func recordManagedDevicesPublication(_ id: String, on stream: XMPPStream, localSID: Int) -> Bool {
        let state = omemo2ManagedDevicesPublication
        guard let proof = state.authorization, proof.stream === stream,
              managedDevicesBinding(on: stream, localSID: localSID) == proof.signature.binding,
              state.blocked != proof.signature else { return false }
        state.publications[id] = proof
        return true
    }

    internal func validManagedDevicesPublicationReply(_ iq: XMPPIQ, on stream: XMPPStream?, id: String) -> Bool {
        guard let proof = omemo2ManagedDevicesPublication.publications[id], let stream else { return false }
        return proof.stream === stream && validManagedDevicesEnvelope(iq, binding: proof.signature.binding) &&
            currentManagedDevicesBinding(proof.signature.binding, on: stream)
    }

    internal func finishManagedDevicesPublication(_ iq: XMPPIQ, id: String) {
        let state = omemo2ManagedDevicesPublication
        guard let proof = state.publications.removeValue(forKey: id) else { return }
        if iq.iqType == .error,
           iq.element(forName: "error")?.element(forName: "policy-violation", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas") != nil {
            state.authorization = nil
            state.blocked = proof.signature
            if proof.signature.binding.deviceID == nil {
                shouldPublicate = false; omemo2PublicationRetryAt = nil
            }
        } else if iq.iqType == .result, let stream = proof.stream {
            state.authorization = .init(stream: stream, binding: proof.signature.binding,
                serverSID: proof.signature.binding.localSID)
            state.blocked = nil
        }
        if !isOwnOMEMOEnabled, state.withdrawalRequested, let stream = proof.stream {
            beginManagedDevicesWithdrawal(on: stream)
        }
    }

    internal func beginManagedDevicesWithdrawal(on stream: XMPPStream) {
        let state = omemo2ManagedDevicesPublication
        state.withdrawalRequested = true
        state.authorization = nil
        guard let sid = try? omemo2Storage?.localBundle().deviceID else { return }
        guard let binding = managedDevicesBinding(on: stream, localSID: sid) else {
            if let primary = AccountManager.shared.find(for: owner)?.xmppStream,
               primary !== stream, managedDevicesBinding(on: primary, localSID: sid) != nil {
                beginManagedDevicesWithdrawal(on: primary)
            }
            return
        }
        omemo2MaintenancePublicationStream = stream
        // An already-issued publication must finish before a withdrawal reads
        // its mapping; otherwise a delayed publish could recreate a removed item.
        if !state.publications.isEmpty { return }
        if let request = state.pending {
            if case .retract = request.operation { return }
            if request.stream === stream, request.binding == binding { return }
        }
        discardManagedDevicesRequest()
        if binding.deviceID == nil {
            // Explicit user disable retains the legacy own-SID withdrawal. It
            // never guesses a Devices UUID or performs migration cleanup.
            requestManagedDevicesRetraction(on: stream, binding: binding, sid: sid)
        } else {
            requestManagedDevicesMetadata(on: stream, binding: binding, afterRetraction: nil)
        }
    }

    internal func handleManagedDevicesPublicationReply(_ iq: XMPPIQ, on stream: XMPPStream) -> Bool {
        omemo2MaintenanceLock.lock()
        defer { scheduleOMEMO2PublicationMaintenance(); omemo2MaintenanceLock.unlock() }
        let state = omemo2ManagedDevicesPublication
        guard let request = state.pending, iq.elementID == request.id,
              iq.iqType == .result || iq.iqType == .error,
              request.stream === stream,
              validManagedDevicesEnvelope(iq, binding: request.binding),
              currentManagedDevicesBinding(request.binding, on: stream) else { return false }
        discardManagedDevicesRequest()
        guard iq.iqType == .result else { failManagedDevicesOperation(); return true }
        switch request.operation {
        case .retract(let oldSID):
            state.authorization = nil
            if request.binding.deviceID == nil {
                state.withdrawalRequested = false
                if isOwnOMEMOEnabled { shouldPublicate = true; omemo2PublicationRetryAt = nil }
            } else if !isOwnOMEMOEnabled {
                state.withdrawalRequested = false
            } else {
                requestManagedDevicesMetadata(on: stream, binding: request.binding, afterRetraction: oldSID)
            }
        case .metadata(let afterRetraction):
            guard let metadata = decodeManagedDevicesMetadata(iq),
                  let uuid = request.binding.deviceID,
                  let current = metadata.first(where: { $0.id == uuid }) else {
                failManagedDevicesOperation(); return true
            }
            let siblings = metadata.filter { $0.id != uuid }
            guard (!isOwnOMEMOEnabled || !siblings.contains(where: { $0.sid == request.binding.localSID })),
                  current.sid.map({ old in !siblings.contains { $0.sid == old } }) ?? true else {
                blockManagedDevicesOperation(binding: request.binding, serverSID: current.sid); return true
            }
            if !isOwnOMEMOEnabled {
                state.withdrawalRequested = true
                if let old = current.sid { requestManagedDevicesRetraction(on: stream, binding: request.binding, sid: old) }
                else { state.withdrawalRequested = false }
            } else if let old = current.sid, old != request.binding.localSID {
                guard afterRetraction == nil else {
                    blockManagedDevicesOperation(binding: request.binding, serverSID: old); return true
                }
                requestManagedDevicesRetraction(on: stream, binding: request.binding, sid: old)
            } else {
                let proof = OMEMO2ManagedDevicesPublication.Authorization(stream: stream, binding: request.binding, serverSID: current.sid)
                guard state.blocked != proof.signature else { shouldPublicate = false; omemo2PublicationRetryAt = nil; return true }
                state.authorization = proof; state.withdrawalRequested = false
                do { try sendOwnDeviceBundle(stream, createNode: false) }
                catch { failManagedDevicesOperation() }
            }
        }
        return true
    }

    internal func expireManagedDevicesPublication(at time: Date) {
        let state = omemo2ManagedDevicesPublication
        if let request = state.pending, time.timeIntervalSince(request.startedAt) >= Self.omemo2PublicationIQTimeout {
            discardManagedDevicesRequest(); state.authorization = nil
            if isOwnOMEMOEnabled { shouldPublicate = true; omemo2PublicationRetryAt = nil }
            else { state.withdrawalRequested = false }
        }
        for id in Array(state.publications.keys) where omemo2BundlePublications[id] == nil { state.publications.removeValue(forKey: id) }
        if !isOwnOMEMOEnabled, state.withdrawalRequested, state.pending == nil,
           state.publications.isEmpty, let stream = omemo2MaintenancePublicationStream {
            beginManagedDevicesWithdrawal(on: stream)
        }
    }

    private func currentManagedDevicesBinding(_ expected: OMEMO2ManagedDevicesPublication.Binding, on stream: XMPPStream) -> Bool {
        guard let sid = try? omemo2Storage?.localBundle().deviceID, sid == expected.localSID else { return false }
        return managedDevicesBinding(on: stream, localSID: sid) == expected
    }

    private func validManagedDevicesEnvelope(_ iq: XMPPIQ, binding: OMEMO2ManagedDevicesPublication.Binding) -> Bool {
        // Requests explicitly address own bare JID; a client resource cannot
        // impersonate that server-side PEP/Devices service.
        iq.from?.full == binding.owner && iq.to?.full == binding.fullJID
    }

    private func discardManagedDevicesRequest() {
        if let request = omemo2ManagedDevicesPublication.pending { queryIds.remove(request.id) }
        omemo2ManagedDevicesPublication.pending = nil
    }

    private func requestManagedDevicesMetadata(on stream: XMPPStream,
        binding: OMEMO2ManagedDevicesPublication.Binding, afterRetraction: Int?) {
        guard currentManagedDevicesBinding(binding, on: stream) else { return }
        let id = stream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: Self.devicesMetadataNamespace)
        omemo2ManagedDevicesPublication.pending = .init(stream: stream, id: id, binding: binding,
            operation: .metadata(afterRetraction: afterRetraction), startedAt: omemo2MaintenanceNow())
        shouldPublicate = false; omemo2PublicationRetryAt = nil; queryIds.insert(id)
        stream.send(XMPPIQ(iqType: .get, to: XMPPJID(string: owner), elementID: id, child: query))
    }

    private func requestManagedDevicesRetraction(on stream: XMPPStream,
        binding: OMEMO2ManagedDevicesPublication.Binding, sid: Int) {
        guard currentManagedDevicesBinding(binding, on: stream) else { return }
        let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
        let retract = DDXMLElement(name: "retract"); retract.addAttribute(withName: "node", stringValue: NodeType.bundle.rawValue)
        let item = DDXMLElement(name: "item"); item.addAttribute(withName: "id", stringValue: String(sid))
        retract.addChild(item); pubsub.addChild(retract)
        let id = stream.generateUUID
        omemo2ManagedDevicesPublication.pending = .init(stream: stream, id: id, binding: binding,
            operation: .retract(oldSID: sid), startedAt: omemo2MaintenanceNow())
        shouldPublicate = false; omemo2PublicationRetryAt = nil; queryIds.insert(id)
        stream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: owner), elementID: id, child: pubsub))
    }

    private struct ManagedMetadataDevice { let id: String; let sid: Int? }
    private func decodeManagedDevicesMetadata(_ iq: XMPPIQ) -> [ManagedMetadataDevice]? {
        let queries = SCEReceivePolicy.children(of: iq, named: "query", xmlns: Self.devicesMetadataNamespace)
        guard queries.count == 1 else { return nil }
        let nodes = (queries[0].children ?? []).compactMap { $0 as? DDXMLElement }
        guard !nodes.isEmpty, nodes.count <= 512 else { return nil }
        var seen = Set<String>(); var result: [ManagedMetadataDevice] = []
        for node in nodes {
            guard node.localName == "device", node.uri == Self.devicesNamespace,
                  let id = node.attributeStringValue(forName: "id"), !id.isEmpty,
                  id.utf8.count <= 256, seen.insert(id).inserted else { return nil }
            let ids = (node.children ?? []).compactMap { $0 as? DDXMLElement }.filter { $0.localName == "omemo-id" }
            guard ids.count <= 1 else { return nil }
            var sid: Int?
            if let element = ids.first {
                guard element.uri == Self.devicesNamespace,
                      !(element.children ?? []).contains(where: { $0 is DDXMLElement }),
                      let text = element.stringValue,
                      let parsed = try? OMEMO2BundleCodec.keyID(text), String(parsed) == text else { return nil }
                sid = Int(parsed)
            }
            result.append(.init(id: id, sid: sid))
        }
        return result
    }

    private func failManagedDevicesOperation() {
        let state = omemo2ManagedDevicesPublication
        state.authorization = nil
        if isOwnOMEMOEnabled {
            shouldPublicate = true
            omemo2PublicationRetryAt = omemo2MaintenanceNow().addingTimeInterval(Self.omemo2PublicationRetryInterval)
        } else { shouldPublicate = false; state.withdrawalRequested = false }
    }

    private func blockManagedDevicesOperation(binding: OMEMO2ManagedDevicesPublication.Binding, serverSID: Int?) {
        omemo2ManagedDevicesPublication.authorization = nil
        omemo2ManagedDevicesPublication.blocked = .init(binding: binding, serverSID: serverSID)
        omemo2ManagedDevicesPublication.withdrawalRequested = false
        shouldPublicate = false; omemo2PublicationRetryAt = nil
    }
}
