import Foundation
import RealmSwift
import XMPPFramework

/// Public error categories enter the existing preparation/send failure path.
/// No transport payload or private state is retained in an error.
internal enum OMEMO2ManagedPublicationError: Error, Equatable {
    case authenticationRequired
    case invalidMetadata
    case policyBlocked
    case membershipMissing
    case unavailable
}

/// Detached, current-session authority; never supplied by Realm's Devices UI.
internal final class OMEMO2ManagedDevicesPublication {
    struct Binding: Equatable {
        let owner: String
        let fullJID: String
        let deviceID: String?
        let authGeneration: UInt64
        let managerGeneration: UInt64
        let localSID: Int // zero only while the protected aggregate is absent.
        let streamID: ObjectIdentifier
        func sameAuthentication(as other: Binding) -> Bool {
            owner == other.owner && fullJID == other.fullJID && deviceID == other.deviceID &&
                authGeneration == other.authGeneration && streamID == other.streamID
        }
    }
    struct Signature: Equatable { let binding: Binding; let serverSID: Int? }
    final class Authorization {
        weak var stream: XMPPStream?
        let signature: Signature
        let snapshot: OMEMO2RegistrationSnapshot
        init(stream: XMPPStream, binding: Binding, serverSID: Int?, snapshot: OMEMO2RegistrationSnapshot) {
            self.stream = stream; self.snapshot = snapshot; signature = .init(binding: binding, serverSID: serverSID)
        }
    }
    enum Intent { case startup, publication, withdrawal, policyRefresh }
    struct Device { let id: String; let sid: Int? }
    final class Flow {
        let binding: Binding
        let intent: Intent
        let serverSID: Int?
        let snapshot: OMEMO2RegistrationSnapshot?
        var membership: Set<Int>?
        var membershipToken: UUID?
        var preparedIdentity: Data?
        var preparedSnapshot: OMEMO2RegistrationSnapshot?
        init(binding: Binding, intent: Intent, serverSID: Int?, snapshot: OMEMO2RegistrationSnapshot?) {
            self.binding = binding; self.intent = intent; self.serverSID = serverSID; self.snapshot = snapshot
        }
    }
    enum IdentityPurpose { case initial, retained, oldPending, targetPending }
    enum Operation {
        case metadata(Intent)
        case membership(Flow)
        case identity(Flow, Int, IdentityPurpose)
        case confirmation(Authorization, Data)
        case retract(Int)
    }
    final class Request {
        weak var stream: XMPPStream?
        let id: String
        let binding: Binding
        let operation: Operation
        let snapshot: OMEMO2RegistrationSnapshot?
        let startedAt: Date
        init(stream: XMPPStream, id: String, binding: Binding, operation: Operation, snapshot: OMEMO2RegistrationSnapshot?, startedAt: Date) {
            self.stream = stream; self.id = id; self.binding = binding; self.snapshot = snapshot
            self.operation = operation; self.startedAt = startedAt
        }
    }
    var generation: UInt64 = 0
    var pending: Request?
    var authorization: Authorization?
    var setupAuthorization: Authorization?
    var ready: Authorization?
    var publications: [String: Authorization] = [:]
    // Preserve a confirmed policy block across manager resets. Only a different
    // actually accepted authentication can make it obsolete.
    var blocked: Signature?
    var policyBlocks: [Int: Signature] = [:]
    var policyRefreshValidated: Bool?
    var withdrawalRequested = false
    var mustCheckOwnIdentity = false
    var lastError: Error?
    var membershipWitness: (token: UUID, ids: Set<Int>)?
}

extension OmemoManager {
    private static let devicesMetadataNamespace = "https://xabber.com/protocol/devices#items"
    private static let devicesNamespace = "https://xabber.com/protocol/devices"

    internal func managedDevicesBinding(on stream: XMPPStream, localSID: Int) -> OMEMO2ManagedDevicesPublication.Binding? {
        guard omemo2Storage?.owner == owner, stream.isAuthenticated, !stream.isDisconnected,
              stream.myJID?.bare == owner, let full = stream.myJID?.full, stream.myJID?.resource?.isEmpty == false,
              let devices = AccountManager.shared.find(for: owner)?.devices,
              let uuid = devices.authenticatedDeviceID(on: stream),
              let epoch = devices.authenticatedSessionGeneration(on: stream) else { return nil }
        return .init(owner: owner, fullJID: full, deviceID: uuid, authGeneration: epoch,
            managerGeneration: omemo2ManagedDevicesPublication.generation, localSID: localSID,
            streamID: ObjectIdentifier(stream))
    }

    internal var isManagedDevicesReady: Bool {
        omemo2MaintenanceLock.lock()
        defer { omemo2MaintenanceLock.unlock() }
        guard let proof = omemo2ManagedDevicesPublication.ready, let stream = proof.stream,
              let current = managedDevicesBinding(on: stream, localSID: proof.signature.binding.localSID) else { return false }
        return current == proof.signature.binding && managedDevicesProofStateCurrent(proof)
    }

    internal func resetManagedDevicesPublication() {
        let state = omemo2ManagedDevicesPublication
        discardManagedDevicesRequest()
        for id in state.publications.keys {
            queryIds.remove(id); omemo2BundlePublications.removeValue(forKey: id)
            omemo2BundlePublicationStartedAt.removeValue(forKey: id)
        }
        state.authorization = nil; state.setupAuthorization = nil; state.ready = nil
        state.publications.removeAll(); state.withdrawalRequested = false
        state.membershipWitness = nil; state.lastError = nil; state.policyRefreshValidated = nil; state.generation &+= 1
    }

    internal func beginManagedDevicesRegistration(on stream: XMPPStream) {
        omemo2MaintenanceLock.lock()
        defer { scheduleOMEMO2PublicationMaintenance(); omemo2MaintenanceLock.unlock() }
        guard isOwnOMEMOEnabled else { return }
        let state = omemo2ManagedDevicesPublication
        do {
            let sid = try omemo2Storage?.registrationSnapshot()?.deviceID ?? 0
            guard let binding = managedDevicesBinding(on: stream, localSID: sid) else {
                stopManagedDevicesOperation(OMEMO2ManagedPublicationError.authenticationRequired); return
            }
            guard !managedDevicesPolicyBlocked(binding) else { return }
            if let pending = state.pending, pending.stream === stream, pending.binding == binding { return }
            guard state.publications.isEmpty else { return }
            discardManagedDevicesRequest(); state.ready = nil; state.authorization = nil; state.lastError = nil
            requestManagedDevicesMetadata(on: stream, binding: binding, intent: .startup)
        } catch { stopManagedDevicesOperation(error) }
    }

    /// A metadata result grants one write only. Every subsequent publication,
    /// including ordinary OPK updates, starts another current Devices read.
    internal func prepareManagedDevicesPublication(on stream: XMPPStream, localSID: Int) -> Bool {
        let state = omemo2ManagedDevicesPublication
        guard let binding = managedDevicesBinding(on: stream, localSID: localSID) else {
            stopManagedDevicesOperation(OMEMO2ManagedPublicationError.authenticationRequired); return false
        }
        guard !managedDevicesPolicyBlocked(binding) else { return false }
        if let ready = state.ready, !managedDevicesProofStateCurrent(ready) {
            stopManagedDevicesOperation(OMEMO2StorageError.identityRecoveryRequired); return false
        }
        if let proof = state.authorization, proof.stream === stream, proof.signature.binding == binding {
            guard managedDevicesProofStateCurrent(proof) else {
                stopManagedDevicesOperation(OMEMO2StorageError.identityRecoveryRequired); return false
            }
            return true
        }
        if state.pending != nil || !state.publications.isEmpty { return false }
        state.withdrawalRequested = false; state.lastError = nil
        requestManagedDevicesMetadata(on: stream, binding: binding, intent: .publication)
        return false
    }

    internal func recordManagedDevicesPublication(_ id: String, on stream: XMPPStream, localSID: Int) -> Bool {
        let state = omemo2ManagedDevicesPublication
        guard let proof = state.authorization, proof.stream === stream,
              currentManagedDevicesBinding(proof.signature.binding, on: stream),
              proof.signature.binding.localSID == localSID, managedDevicesProofStateCurrent(proof),
              !managedDevicesPolicyBlocked(proof.signature.binding) else { return false }
        state.publications[id] = proof; state.authorization = nil
        return true
    }

    internal func validManagedDevicesPublicationReply(_ iq: XMPPIQ, on stream: XMPPStream?, id: String) -> Bool {
        guard let proof = omemo2ManagedDevicesPublication.publications[id], let stream else { return false }
        return proof.stream === stream && validManagedDevicesEnvelope(iq, binding: proof.signature.binding) &&
            currentManagedDevicesBinding(proof.signature.binding, on: stream) && managedDevicesProofStateCurrent(proof)
    }

    internal func finishManagedDevicesPublication(_ iq: XMPPIQ, id: String, acceptedHash: Data? = nil) {
        let state = omemo2ManagedDevicesPublication
        guard let proof = state.publications.removeValue(forKey: id), let stream = proof.stream else { return }
        state.authorization = nil
        if iq.iqType == .error {
            if managedDevicesErrorCondition(iq) == "policy-violation" {
                state.blocked = proof.signature
                state.policyBlocks[proof.signature.binding.localSID] = proof.signature
                state.policyRefreshValidated = nil
                stopManagedDevicesOperation(OMEMO2ManagedPublicationError.policyBlocked)
                // Exactly one diagnostic refresh; its contents cannot lift the
                // block or authorize another ID in this authentication.
                requestManagedDevicesMetadata(on: stream, binding: proof.signature.binding, intent: .policyRefresh)
            } else { failManagedDevicesOperation() }
        } else if let acceptedHash, isOwnOMEMOEnabled {
            requestManagedDevicesMembership(on: stream, binding: proof.signature.binding,
                operation: .confirmation(proof, acceptedHash))
        }
        if !isOwnOMEMOEnabled, state.withdrawalRequested { beginManagedDevicesWithdrawal(on: stream) }
    }

    internal func beginManagedDevicesWithdrawal(on stream: XMPPStream) {
        let state = omemo2ManagedDevicesPublication
        state.withdrawalRequested = true; state.authorization = nil; state.ready = nil; state.mustCheckOwnIdentity = true
        guard let sid = try? omemo2Storage?.localBundle().deviceID else { state.withdrawalRequested = false; return }
        guard let binding = managedDevicesBinding(on: stream, localSID: sid) else {
            if let primary = AccountManager.shared.find(for: owner)?.xmppStream,
               primary !== stream, managedDevicesBinding(on: primary, localSID: sid) != nil {
                beginManagedDevicesWithdrawal(on: primary)
            } else { stopManagedDevicesOperation(OMEMO2ManagedPublicationError.authenticationRequired) }
            return
        }
        omemo2MaintenancePublicationStream = stream
        if !state.publications.isEmpty { return }
        if let pending = state.pending {
            if case .retract = pending.operation { return }
            if case .metadata(.withdrawal) = pending.operation, pending.stream === stream, pending.binding == binding { return }
        }
        discardManagedDevicesRequest()
        requestManagedDevicesMetadata(on: stream, binding: binding, intent: .withdrawal)
    }

    internal func handleManagedDevicesPublicationReply(_ iq: XMPPIQ, on stream: XMPPStream) -> Bool {
        omemo2MaintenanceLock.lock()
        var afterUnlock: (() -> Void)?
        defer {
            scheduleOMEMO2PublicationMaintenance()
            omemo2MaintenanceLock.unlock()
            // Queue after the whole transport callback unwinds, including
            // synchronous test transports or another recursive caller frame.
            if let afterUnlock, let account = AccountManager.shared.find(for: owner) {
                account.queue.async(execute: afterUnlock)
            }
        }
        let state = omemo2ManagedDevicesPublication
        guard let request = state.pending, iq.elementID == request.id,
              iq.iqType == .result || iq.iqType == .error, request.stream === stream,
              validManagedDevicesEnvelope(iq, binding: request.binding),
              currentManagedDevicesBinding(request.binding, on: stream) else { return false }
        discardManagedDevicesRequest()
        do {
            switch request.operation {
            case .metadata(let intent):
                if intent == .policyRefresh {
                    state.policyRefreshValidated = false
                    if iq.iqType == .result, let devices = try? decodeManagedDevicesMetadata(iq),
                       let uuid = request.binding.deviceID, let current = devices.first(where: { $0.id == uuid }),
                       current.sid.map({ sid in !devices.contains { $0.id != uuid && $0.sid == sid } }) ?? true {
                        state.policyRefreshValidated = true
                    }
                    shouldPublicate = false; omemo2PublicationRetryAt = nil; return true
                }
                guard iq.iqType == .result else { failManagedDevicesOperation(); return true }
                let devices = try decodeManagedDevicesMetadata(iq)
                guard let uuid = request.binding.deviceID, let current = devices.first(where: { $0.id == uuid }) else {
                    throw OMEMO2ManagedPublicationError.invalidMetadata
                }
                let siblings = devices.filter { $0.id != uuid }
                guard current.sid.map({ sid in !siblings.contains { $0.sid == sid } }) ?? true else {
                    throw OMEMO2StorageError.devicesStateIDMismatch
                }
                if intent == .withdrawal {
                    guard !isOwnOMEMOEnabled else { beginManagedDevicesRegistration(on: stream); return true }
                    state.withdrawalRequested = false
                    // An explicit disable may delete only the retained local
                    // SID, never a different mapped SID or a sibling's item.
                    if let sid = current.sid {
                        guard sid == request.binding.localSID else { throw OMEMO2StorageError.devicesStateIDMismatch }
                        state.withdrawalRequested = true
                        requestManagedDevicesRetraction(on: stream, binding: request.binding, sid: sid)
                    }
                    return true
                }
                guard isOwnOMEMOEnabled else { beginManagedDevicesWithdrawal(on: stream); return true }
                guard !managedDevicesPolicyBlocked(request.binding) else { return true }
                guard !siblings.contains(where: { $0.sid == request.binding.localSID && request.binding.localSID > 0 }) else {
                    throw OMEMO2StorageError.devicesStateIDMismatch
                }
                guard let storage = omemo2Storage else { throw OMEMO2StorageError.stateUnavailable }
                let snapshot = try storage.registrationSnapshot()
                guard managedDevicesSnapshotContinues(request.snapshot, current: snapshot) else { throw OMEMO2StorageError.identityRecoveryRequired }
                let flow = OMEMO2ManagedDevicesPublication.Flow(binding: request.binding, intent: intent, serverSID: current.sid, snapshot: snapshot)
                if let snapshot, let assigned = current.sid, snapshot.deviceID != assigned, !snapshot.isUnusedPending {
                    throw OMEMO2StorageError.devicesStateIDMismatch
                }
                if intent == .startup || snapshot == nil || (current.sid != nil && snapshot?.deviceID != current.sid) {
                    requestManagedDevicesMembership(on: stream, binding: request.binding, operation: .membership(flow))
                } else { try prepareManagedDevicesFlow(flow, on: stream) }
            case .membership(let flow):
                guard isOwnOMEMOEnabled else { beginManagedDevicesWithdrawal(on: stream); return true }
                let ids = try decodeManagedDevicesMembership(iq)
                flow.membership = ids; let token = UUID(); flow.membershipToken = token
                state.membershipWitness = (token, ids)
                try prepareManagedDevicesFlow(flow, on: stream)
            case .identity(let flow, let sid, let purpose):
                guard isOwnOMEMOEnabled else { beginManagedDevicesWithdrawal(on: stream); return true }
                let published = try decodeManagedDevicesIdentity(iq, sid: sid)
                try completeManagedDevicesIdentity(flow, on: stream, published: published, purpose: purpose)
            case .confirmation(let proof, let hash):
                guard isOwnOMEMOEnabled else { beginManagedDevicesWithdrawal(on: stream); return true }
                let ids = try decodeManagedDevicesMembership(iq)
                guard ids.contains(proof.signature.binding.localSID) else { throw OMEMO2ManagedPublicationError.membershipMissing }
                guard let storage = omemo2Storage else { throw OMEMO2StorageError.stateUnavailable }
                let bundle = try storage.localBundle()
                let current = { [weak self, weak stream] () -> Bool in
                    guard let self, let stream,
                          self.currentManagedDevicesBinding(proof.signature.binding, on: stream),
                          self.managedDevicesProofStateCurrent(proof), let bundle = try? storage.localBundle(),
                          let xml = try? OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(bundle)).compactXMLString else { return false }
                    return Data(xml.utf8).sha256Data == hash
                }
                guard current() else {
                    state.ready = nil; shouldPublicate = true; omemo2PublicationRetryAt = nil; return true
                }
                try storage.markRegistrationConfirmed(deviceID: bundle.deviceID, identityKey: bundle.identityKey, isCurrent: current)
                state.ready = proof; state.lastError = nil; state.mustCheckOwnIdentity = false
                isOmemoPrepared = true; shouldPublicate = false; omemo2PublicationRetryAt = nil
                // Control preparation enters sessionQueue before maintenance.
                // Do not project membership or flush controls while holding the
                // maintenance lock; both can enter that queue synchronously.
                afterUnlock = { [weak self, weak stream] in
                    guard let self, let stream, self.managedDevicesReadyEffectsCurrent(proof, on: stream) else { return }
                    self.projectManagedDevicesMembership(iq)
                    guard self.managedDevicesReadyEffectsCurrent(proof, on: stream) else { return }
                    self.omemo2PreKeyCleanup.retryEligibleCleanup()
                    guard self.managedDevicesReadyEffectsCurrent(proof, on: stream) else { return }
                    self.flushOMEMO2Controls()
                    guard self.managedDevicesReadyEffectsCurrent(proof, on: stream) else { return }
                    AccountManager.shared.find(for: self.owner)?.trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(bundle.deviceID))
                }
            case .retract:
                state.withdrawalRequested = false
                guard iq.iqType == .result else { stopManagedDevicesOperation(OMEMO2ManagedPublicationError.unavailable); return true }
                if isOwnOMEMOEnabled { beginManagedDevicesRegistration(on: stream) }
            }
        } catch { stopManagedDevicesOperation(error) }
        return true
    }

    private func prepareManagedDevicesFlow(_ flow: OMEMO2ManagedDevicesPublication.Flow, on stream: XMPPStream) throws {
        guard currentManagedDevicesBinding(flow.binding, on: stream), isOwnOMEMOEnabled else { throw OMEMO2StorageError.staleRegistration }
        if let snapshot = flow.snapshot {
            if let assigned = flow.serverSID, assigned != snapshot.deviceID {
                guard snapshot.isUnusedPending, let members = flow.membership, !members.contains(snapshot.deviceID) else {
                    throw OMEMO2StorageError.devicesStateIDMismatch
                }
                requestManagedDevicesIdentity(on: stream, flow: flow, sid: snapshot.deviceID, purpose: .oldPending)
            } else if flow.intent == .startup || snapshot.registrationPending || flow.serverSID == nil ||
                        !isManagedDevicesReady || omemo2ManagedDevicesPublication.mustCheckOwnIdentity {
                requestManagedDevicesIdentity(on: stream, flow: flow, sid: snapshot.deviceID, purpose: .retained)
            } else { try finishManagedDevicesFlow(flow, on: stream, sid: snapshot.deviceID) }
        } else if let assigned = flow.serverSID {
            requestManagedDevicesIdentity(on: stream, flow: flow, sid: assigned, purpose: .initial)
        } else {
            guard let members = flow.membership else { throw OMEMO2ManagedPublicationError.membershipMissing }
            var candidate: Int?
            for _ in 0..<256 {
                let id = omemo2FreshDeviceIDGenerator?() ?? Int(arc4random_uniform(UInt32(Int32.max)) + 1)
                guard id > 0, id <= Int(Int32.max) else { throw OMEMO2StorageError.invalidDeviceID }
                if !members.contains(id) { candidate = id; break }
            }
            guard let candidate else { throw OMEMO2StorageError.invalidDeviceID }
            try initializeManagedDevicesFlow(flow, on: stream, sid: candidate)
        }
    }

    private func completeManagedDevicesIdentity(_ flow: OMEMO2ManagedDevicesPublication.Flow, on stream: XMPPStream,
        published: Data?, purpose: OMEMO2ManagedDevicesPublication.IdentityPurpose) throws {
        guard currentManagedDevicesBinding(flow.binding, on: stream), isOwnOMEMOEnabled else { throw OMEMO2StorageError.staleRegistration }
        switch purpose {
        case .initial:
            guard published == nil, let sid = flow.serverSID else { throw OMEMO2StorageError.identityRecoveryRequired }
            try initializeManagedDevicesFlow(flow, on: stream, sid: sid)
        case .retained:
            guard let snapshot = flow.snapshot, let storage = omemo2Storage,
                  let current = try storage.registrationSnapshot(), current.deviceID == snapshot.deviceID,
                  current.hasSameIdentity(as: snapshot),
                  published == nil || published == snapshot.identityKey else { throw OMEMO2StorageError.identityRecoveryRequired }
            try finishManagedDevicesFlow(flow, on: stream, sid: snapshot.deviceID)
        case .oldPending:
            guard published == nil, let sid = flow.serverSID else { throw OMEMO2StorageError.devicesStateIDMismatch }
            requestManagedDevicesIdentity(on: stream, flow: flow, sid: sid, purpose: .targetPending)
        case .targetPending:
            guard let snapshot = flow.snapshot, let sid = flow.serverSID, let storage = omemo2Storage else { throw OMEMO2StorageError.stateUnavailable }
            let oldAbsent = { [weak self] () -> Bool in
                guard let self, let witness = self.omemo2ManagedDevicesPublication.membershipWitness,
                      witness.token == flow.membershipToken else { return false }
                return !witness.ids.contains(snapshot.deviceID)
            }
            _ = try storage.adoptPendingDeviceID(sid, expected: snapshot, oldIDAbsent: oldAbsent,
                publishedOldIdentity: nil, publishedTargetIdentity: published,
                externalStateUnused: { [weak self] in self?.managedDevicesExternalStateUnused() == true },
                isCurrent: { [weak self, weak stream] in
                    guard let self, let stream else { return false }
                    return self.currentManagedDevicesBinding(flow.binding, on: stream) && self.isOwnOMEMOEnabled
                })
            try finishManagedDevicesFlow(flow, on: stream, sid: sid, changedID: true)
        }
    }

    private func initializeManagedDevicesFlow(_ flow: OMEMO2ManagedDevicesPublication.Flow, on stream: XMPPStream, sid: Int) throws {
        guard let storage = omemo2Storage else { throw OMEMO2StorageError.stateUnavailable }
        let created = try storage.prepare(deviceID: sid, isCurrent: { [weak self, weak stream] in
            guard let self, let stream else { return false }
            return self.isOwnOMEMOEnabled && self.currentManagedDevicesBinding(flow.binding, on: stream)
        })
        flow.preparedIdentity = created.identityKey
        guard let snapshot = try storage.registrationSnapshot(), snapshot.identityKey == created.identityKey else {
            throw OMEMO2StorageError.identityRecoveryRequired
        }
        flow.preparedSnapshot = snapshot
        try finishManagedDevicesFlow(flow, on: stream, sid: sid, changedID: true)
    }

    internal func validateManagedDevicesSetupSnapshot(_ flow: OMEMO2ManagedDevicesPublication.Flow,
        current: OMEMO2RegistrationSnapshot) throws {
        if let expected = flow.snapshot ?? flow.preparedSnapshot {
            guard current.hasSameIdentity(as: expected) else { throw OMEMO2StorageError.identityRecoveryRequired }
        } else {
            guard let expected = flow.preparedIdentity, current.identityKey == expected else {
                throw OMEMO2StorageError.identityRecoveryRequired
            }
        }
    }

    private func finishManagedDevicesFlow(_ flow: OMEMO2ManagedDevicesPublication.Flow, on stream: XMPPStream,
        sid: Int, changedID: Bool = false) throws {
        guard let binding = managedDevicesBinding(on: stream, localSID: sid),
              binding.sameAuthentication(as: flow.binding), binding.managerGeneration == flow.binding.managerGeneration else {
            throw OMEMO2StorageError.staleRegistration
        }
        if flow.intent == .startup || changedID || localStore.localDeviceId() != sid {
            guard let snapshot = try omemo2Storage?.registrationSnapshot() else { throw OMEMO2StorageError.stateUnavailable }
            try validateManagedDevicesSetupSnapshot(flow, current: snapshot)
            omemo2ManagedDevicesPublication.setupAuthorization = .init(stream: stream, binding: binding, serverSID: flow.serverSID, snapshot: snapshot)
            configureLocal(stream, for: sid)
        } else {
            guard let snapshot = try omemo2Storage?.registrationSnapshot(),
                  flow.snapshot.map({ snapshot.hasSameIdentity(as: $0) }) ?? true else { throw OMEMO2StorageError.identityRecoveryRequired }
            omemo2ManagedDevicesPublication.authorization = .init(stream: stream, binding: binding, serverSID: flow.serverSID, snapshot: snapshot)
            try sendOwnDeviceBundle(stream, createNode: false)
        }
    }

    internal func consumeManagedDevicesSetup(on stream: XMPPStream, localSID: Int) -> Bool {
        let state = omemo2ManagedDevicesPublication
        guard let proof = state.setupAuthorization, proof.stream === stream,
              proof.signature.binding.localSID == localSID,
              currentManagedDevicesBinding(proof.signature.binding, on: stream), managedDevicesProofStateCurrent(proof) else { return false }
        return true
    }

    /// Capture once before guarded maintenance. The callback deliberately does
    /// not acquire maintenanceLock while the storage owner lock is held.
    internal func managedDevicesMaintenanceGuard() throws -> () -> Bool {
        guard let proof = omemo2ManagedDevicesPublication.ready, let stream = proof.stream,
              currentManagedDevicesBinding(proof.signature.binding, on: stream), managedDevicesProofStateCurrent(proof) else {
            throw omemo2ManagedDevicesPublication.lastError ?? OMEMO2StorageError.stateUnavailable
        }
        return { [weak self, weak stream] in
            guard let self, let stream else { return false }
            return self.omemo2ManagedDevicesPublication.ready === proof &&
                self.currentManagedDevicesBinding(proof.signature.binding, on: stream) && self.managedDevicesProofStateCurrent(proof)
        }
    }

    internal func managedDevicesSetupStateIsCurrent(on stream: XMPPStream) -> Bool {
        guard let proof = omemo2ManagedDevicesPublication.setupAuthorization, proof.stream === stream else { return false }
        return currentManagedDevicesBinding(proof.signature.binding, on: stream) && managedDevicesProofStateCurrent(proof)
    }

    internal func managedDevicesPublicationStateIsCurrent(on stream: XMPPStream) -> Bool {
        guard let proof = omemo2ManagedDevicesPublication.authorization, proof.stream === stream else { return false }
        return currentManagedDevicesBinding(proof.signature.binding, on: stream) && managedDevicesProofStateCurrent(proof)
    }

    private func managedDevicesReadyEffectsCurrent(_ proof: OMEMO2ManagedDevicesPublication.Authorization, on stream: XMPPStream) -> Bool {
        omemo2MaintenanceLock.lock()
        defer { omemo2MaintenanceLock.unlock() }
        return omemo2ManagedDevicesPublication.ready === proof &&
            currentManagedDevicesBinding(proof.signature.binding, on: stream) && managedDevicesProofStateCurrent(proof)
    }

    private func managedDevicesProofStateCurrent(_ proof: OMEMO2ManagedDevicesPublication.Authorization) -> Bool {
        guard let storage = omemo2Storage, let current = try? storage.registrationSnapshot() else { return false }
        return current.deviceID == proof.signature.binding.localSID && current.hasSameIdentity(as: proof.snapshot)
    }

    private func managedDevicesSnapshotContinues(_ expected: OMEMO2RegistrationSnapshot?, current: OMEMO2RegistrationSnapshot?) -> Bool {
        switch (expected, current) {
        case (nil, nil): return true
        case let (old?, value?): return old.deviceID == value.deviceID && old.hasSameIdentity(as: value)
        default: return false
        }
    }

    internal func invalidateManagedDevicesMembershipWitness() {
        omemo2ManagedDevicesPublication.membershipWitness = nil
    }

    private func managedDevicesExternalStateUnused() -> Bool {
        guard let realm = try? WRealm.safe() else { return false }
        // Public bundle caches do not prove local key use. Protected session,
        // admitted identity and sticky key-use evidence are checked atomically
        // by adoptPendingDeviceID; keep the separate Realm replay/opt-out gates.
        let replayUnused = realm.objects(MessageStanzaStorageItem.self)
            .filter("owner == %@ AND omemo2ReplayFingerprint != nil", owner).isEmpty
        let optOutUnused = realm.objects(OMEMO2OptOutStorageItem.self).filter("owner == %@", owner).isEmpty
        return replayUnused && optOutUnused
    }

    internal func expireManagedDevicesPublication(at time: Date) {
        let state = omemo2ManagedDevicesPublication
        if let request = state.pending, time.timeIntervalSince(request.startedAt) >= Self.omemo2PublicationIQTimeout {
            discardManagedDevicesRequest(); state.authorization = nil
            if case .metadata(.policyRefresh) = request.operation { shouldPublicate = false; omemo2PublicationRetryAt = nil }
            else {
                failManagedDevicesOperation()
                // The IQ deadline has already elapsed; release this request so
                // the current retry can obtain fresh binding metadata now.
                if isOwnOMEMOEnabled { omemo2PublicationRetryAt = nil }
            }
        }
        for id in Array(state.publications.keys) where omemo2BundlePublications[id] == nil { state.publications.removeValue(forKey: id) }
        if !isOwnOMEMOEnabled, state.withdrawalRequested, state.pending == nil,
           state.publications.isEmpty, let stream = omemo2MaintenancePublicationStream { beginManagedDevicesWithdrawal(on: stream) }
    }

    private func currentManagedDevicesBinding(_ expected: OMEMO2ManagedDevicesPublication.Binding, on stream: XMPPStream) -> Bool {
        guard managedDevicesBinding(on: stream, localSID: expected.localSID) == expected,
              let storage = omemo2Storage else { return false }
        do { return (try storage.registrationSnapshot()?.deviceID ?? 0) == expected.localSID }
        catch { return false }
    }
    private func validManagedDevicesEnvelope(_ iq: XMPPIQ, binding: OMEMO2ManagedDevicesPublication.Binding) -> Bool {
        guard iq.localName == "iq", ["", "jabber:client"].contains(iq.uri ?? ""),
              ["result", "error"].contains(iq.attributeStringValue(forName: "type") ?? "") else { return false }
        for name in ["id", "type", "from", "to"] {
            let attributes = (iq.attributes ?? []).filter { $0.localName == name }
            guard attributes.count <= 1, attributes.allSatisfy({ ($0.uri ?? "").isEmpty && !($0.name ?? "").contains(":") }) else { return false }
        }
        return (iq.from == nil || iq.from?.full == binding.owner) && (iq.to == nil || iq.to?.full == binding.fullJID)
    }
    private func managedDevicesPolicyBlocked(_ binding: OMEMO2ManagedDevicesPublication.Binding) -> Bool {
        let state = omemo2ManagedDevicesPublication
        state.policyBlocks = state.policyBlocks.filter { $0.value.binding.sameAuthentication(as: binding) }
        guard state.policyBlocks[binding.localSID] != nil else { return false }
        stopManagedDevicesOperation(OMEMO2ManagedPublicationError.policyBlocked)
        return true
    }
    private func discardManagedDevicesRequest() {
        if let request = omemo2ManagedDevicesPublication.pending { queryIds.remove(request.id) }
        omemo2ManagedDevicesPublication.pending = nil
    }
    private func ownedManagedDevicesRequest(on stream: XMPPStream, binding: OMEMO2ManagedDevicesPublication.Binding,
        operation: OMEMO2ManagedDevicesPublication.Operation, child: DDXMLElement, type: XMPPIQ.IQType = .get) {
        let id = stream.generateUUID
        let snapshot: OMEMO2RegistrationSnapshot?
        do { snapshot = try omemo2Storage?.registrationSnapshot() }
        catch { stopManagedDevicesOperation(error); return }
        omemo2ManagedDevicesPublication.pending = .init(stream: stream, id: id, binding: binding,
            operation: operation, snapshot: snapshot, startedAt: omemo2MaintenanceNow())
        shouldPublicate = false; omemo2PublicationRetryAt = nil; queryIds.insert(id)
        stream.send(XMPPIQ(iqType: type, to: XMPPJID(string: owner), elementID: id, child: child))
    }
    private func requestManagedDevicesMetadata(on stream: XMPPStream, binding: OMEMO2ManagedDevicesPublication.Binding,
        intent: OMEMO2ManagedDevicesPublication.Intent) {
        ownedManagedDevicesRequest(on: stream, binding: binding, operation: .metadata(intent),
            child: DDXMLElement(name: "query", xmlns: Self.devicesMetadataNamespace))
    }
    private func requestManagedDevicesMembership(on stream: XMPPStream, binding: OMEMO2ManagedDevicesPublication.Binding,
        operation: OMEMO2ManagedDevicesPublication.Operation) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
        let items = DDXMLElement(name: "items"); items.addAttribute(withName: "node", stringValue: NodeType.device.rawValue)
        items.addAttribute(withName: "max_items", stringValue: "1"); pubsub.addChild(items)
        ownedManagedDevicesRequest(on: stream, binding: binding, operation: operation, child: pubsub)
    }
    private func requestManagedDevicesIdentity(on stream: XMPPStream, flow: OMEMO2ManagedDevicesPublication.Flow,
        sid: Int, purpose: OMEMO2ManagedDevicesPublication.IdentityPurpose) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
        let items = DDXMLElement(name: "items"); items.addAttribute(withName: "node", stringValue: NodeType.bundle.rawValue)
        let item = DDXMLElement(name: "item"); item.addAttribute(withName: "id", stringValue: String(sid))
        items.addChild(item); pubsub.addChild(items)
        ownedManagedDevicesRequest(on: stream, binding: flow.binding, operation: .identity(flow, sid, purpose), child: pubsub)
    }
    private func requestManagedDevicesRetraction(on stream: XMPPStream, binding: OMEMO2ManagedDevicesPublication.Binding, sid: Int) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
        let retract = DDXMLElement(name: "retract"); retract.addAttribute(withName: "node", stringValue: NodeType.bundle.rawValue)
        let item = DDXMLElement(name: "item"); item.addAttribute(withName: "id", stringValue: String(sid))
        retract.addChild(item); pubsub.addChild(retract)
        ownedManagedDevicesRequest(on: stream, binding: binding, operation: .retract(sid), child: pubsub, type: .set)
    }
    private func managedDevicesElements(_ node: DDXMLElement) -> [DDXMLElement] {
        (node.children ?? []).compactMap { $0 as? DDXMLElement }
    }
    private func managedDevicesContainer(_ node: DDXMLElement) throws {
        guard (node.children ?? []).allSatisfy({ $0.kind != XMLTextKind || ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw OMEMO2ManagedPublicationError.invalidMetadata
        }
    }
    private func decodeManagedDevicesMetadata(_ iq: XMPPIQ) throws -> [OMEMO2ManagedDevicesPublication.Device] {
        try managedDevicesContainer(iq)
        guard !(iq.rootDocument?.children ?? []).contains(where: { $0.kind == XMLDTDKind }) else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        let payload = managedDevicesElements(iq)
        guard payload.count == 1, payload[0].localName == "query", payload[0].uri == Self.devicesMetadataNamespace else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        let query = payload[0]; try managedDevicesContainer(query)
        let nodes = managedDevicesElements(query)
        guard nodes.count <= 512 else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        let fields: Set<String> = ["client", "info", "type", "public-label", "expire", "ip", "last-auth", "resource", "omemo-id"]
        var seen = Set<String>(); var result: [OMEMO2ManagedDevicesPublication.Device] = []
        for node in nodes {
            try managedDevicesContainer(node)
            let attributes = (node.attributes ?? []).filter { $0.localName == "id" }
            guard node.localName == "device", node.uri == Self.devicesNamespace, attributes.count == 1,
                  (attributes[0].uri ?? "").isEmpty, !(attributes[0].name ?? "").contains(":"),
                  let id = attributes[0].stringValue, !id.isEmpty, id.utf8.count <= 256,
                  !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(id).inserted else { throw OMEMO2ManagedPublicationError.invalidMetadata }
            var sid: Int?; var hasSID = false
            for field in managedDevicesElements(node) {
                guard field.uri == Self.devicesNamespace, let name = field.localName, fields.contains(name), managedDevicesElements(field).isEmpty else {
                    throw OMEMO2ManagedPublicationError.invalidMetadata
                }
                if name == "omemo-id" {
                    guard !hasSID, let text = field.stringValue,
                          let parsed = try? OMEMO2BundleCodec.keyID(text), String(parsed) == text else { throw OMEMO2ManagedPublicationError.invalidMetadata }
                    sid = Int(parsed); hasSID = true
                }
            }
            result.append(.init(id: id, sid: sid))
        }
        return result
    }
    private func managedDevicesItems(_ iq: XMPPIQ, node: String) throws -> DDXMLElement {
        let payload = managedDevicesElements(iq)
        guard payload.count == 1, payload[0].localName == "pubsub", payload[0].uri == OMEMO2DeviceListCodec.pubsub else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        let children = managedDevicesElements(payload[0])
        guard children.count == 1, children[0].localName == "items", children[0].uri == OMEMO2DeviceListCodec.pubsub,
              children[0].attributeStringValue(forName: "node") == node else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        return children[0]
    }
    private func managedDevicesErrorCondition(_ iq: XMPPIQ) -> String? {
        let errors = managedDevicesElements(iq).filter { $0.localName == "error" && ["", "jabber:client"].contains($0.uri ?? "") }
        guard errors.count == 1 else { return nil }
        let conditions = managedDevicesElements(errors[0]).filter { $0.uri == "urn:ietf:params:xml:ns:xmpp-stanzas" && $0.localName != "text" }
        guard conditions.count == 1 else { return nil }; return conditions[0].localName
    }
    private func decodeManagedDevicesIdentity(_ iq: XMPPIQ, sid: Int) throws -> Data? {
        if iq.iqType == .error {
            guard managedDevicesErrorCondition(iq) == "item-not-found" else { throw OMEMO2ManagedPublicationError.unavailable }
            return nil
        }
        let items = try managedDevicesItems(iq, node: NodeType.bundle.rawValue)
        let entries = managedDevicesElements(items)
        if entries.isEmpty { return nil }
        guard entries.count == 1, entries[0].localName == "item", entries[0].uri == OMEMO2DeviceListCodec.pubsub,
              entries[0].attributeStringValue(forName: "id") == String(sid) else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        let bundles = managedDevicesElements(entries[0]).filter { $0.localName == "bundle" }
        guard bundles.count == 1, bundles[0].uri == Self.xmlns else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        let identities = managedDevicesElements(bundles[0]).filter { $0.localName == "ik" }
        guard identities.count == 1, identities[0].uri == Self.xmlns, managedDevicesElements(identities[0]).isEmpty,
              (identities[0].attributes ?? []).isEmpty, let text = identities[0].stringValue, text.utf8.count <= 256,
              let key = try? Omemo2PayloadCodec.decodeBase64(text), key.count == 32 else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        return key
    }
    private func decodeManagedDevicesMembership(_ iq: XMPPIQ) throws -> Set<Int> {
        if iq.iqType == .error {
            guard managedDevicesErrorCondition(iq) == "item-not-found" else { throw OMEMO2ManagedPublicationError.unavailable }
            return []
        }
        let items = try managedDevicesItems(iq, node: NodeType.device.rawValue)
        let entries = managedDevicesElements(items)
        if entries.isEmpty { return [] }
        guard entries.count == 1, entries[0].localName == "item", entries[0].uri == OMEMO2DeviceListCodec.pubsub else { throw OMEMO2ManagedPublicationError.invalidMetadata }
        return Set(try OMEMO2DeviceListCodec.decode(entries[0]).ids)
    }
    private func projectManagedDevicesMembership(_ iq: XMPPIQ) {
        guard let items = try? managedDevicesItems(iq, node: NodeType.device.rawValue), let item = managedDevicesElements(items).first else { return }
        _ = onContactDeviceListReceiveItem(item, jid: owner)
    }
    private func failManagedDevicesOperation() {
        let state = omemo2ManagedDevicesPublication
        state.authorization = nil; state.lastError = OMEMO2ManagedPublicationError.unavailable
        if isOwnOMEMOEnabled { shouldPublicate = true; omemo2PublicationRetryAt = omemo2MaintenanceNow().addingTimeInterval(Self.omemo2PublicationRetryInterval) }
        else { shouldPublicate = false; state.withdrawalRequested = false }
    }
    private func stopManagedDevicesOperation(_ error: Error) {
        let state = omemo2ManagedDevicesPublication
        state.authorization = nil; state.ready = nil; state.lastError = error; state.withdrawalRequested = false
        shouldPublicate = false; omemo2PublicationRetryAt = nil
    }
}
