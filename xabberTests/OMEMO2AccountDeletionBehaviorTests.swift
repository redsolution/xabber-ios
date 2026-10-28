import Foundation
import RealmSwift
import Security
import XCTest
@testable import xabber

final class OMEMO2AccountDeletionBehaviorTests: XCTestCase {
    func testAccountCryptoRemovalPropagatesProtectedStateFailureAndRollsBackCallerTransaction() throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "omemo-removal-failure-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let owner = "removed-\(UUID().uuidString.lowercased())@example.test"
        let otherOwner = "retained-\(UUID().uuidString.lowercased())@example.test"
        let removedRows = rows(owner: owner)
        let retainedRows = rows(owner: otherOwner)
        try realm.write { realm.add(removedRows + retainedRows) }
        let optOut = try XCTUnwrap(removedRows.last as? OMEMO2OptOutStorageItem)
        let originalReason = optOut.reason
        var protectedRemovalOwners: [String] = []

        XCTAssertThrowsError(try realm.write {
            optOut.reason = "must roll back"
            try OmemoManager.removeAccountData(
                for: owner,
                commitTransaction: false,
                removeProtectedState: { suppliedOwner in
                    protectedRemovalOwners.append(suppliedOwner)
                    throw ProtectedStateDeletionFailure.rejected
                }
            )
        }) { error in
            XCTAssertEqual(error as? ProtectedStateDeletionFailure, .rejected)
        }

        XCTAssertEqual(protectedRemovalOwners, [owner])
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertEqual(optOut.reason, originalReason)
        for row in removedRows + retainedRows {
            XCTAssertFalse(row.isInvalidated, "A failed credential deletion must preserve \(type(of: row))")
        }
        XCTAssertEqual(realm.objects(OMEMO2OptOutStorageItem.self).filter("owner == %@", otherOwner).count, 1)
    }

    func testCommittedAccountCryptoRemovalDeletesOnlyItsOwnProjectionsAndBothProtectedGenerations() throws {
        try checkRemoval(commitTransaction: true)
    }

    func testAccountCryptoRemovalInsideCallerTransactionPreservesTransactionAndOtherOwner() throws {
        try checkRemoval(commitTransaction: false)
    }

    private func checkRemoval(commitTransaction: Bool) throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment),
            "Real Keychain deletion must use the isolated hosted-test service")
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "omemo-removal-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let owner = "removed-\(UUID().uuidString.lowercased())@example.test"
        let otherOwner = "retained-\(UUID().uuidString.lowercased())@example.test"
        let credentials = CredentialsManager.shared
        defer {
            for jid in [owner, otherOwner] {
                try? credentials.removeOMEMO2State(for: jid)
                credentials.removeIdentityKey(for: jid)
                credentials.removeDeviceId(for: jid)
                credentials.removePreKey(for: jid, id: 7)
                credentials.removeSignedPreKey(for: jid, id: 1)
            }
        }
        for jid in [owner, otherOwner] {
            try credentials.setOMEMO2State(Data("native:\(jid)".utf8), for: jid)
            var retired = retiredQuery(jid)
            retired[kSecValueData as String] = Data("retired:\(jid)".utf8)
            retired[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            XCTAssertEqual(SecItemAdd(retired as CFDictionary, nil), errSecSuccess)
            credentials.setIdentityKey(for: jid, publicKey: Data([1, 2]), privateKey: Data([3, 4]))
            credentials.setDeviceId(42, for: jid)
            credentials.setRegistrationId(84, for: jid)
            credentials.setPreKey(for: jid, id: 7, key: Data([5, 6]))
            credentials.setSignedPreKey(for: jid, id: 1, key: Data([7, 8]))
        }
        let removedRows = rows(owner: owner)
        let retainedRows = rows(owner: otherOwner)
        try realm.write { realm.add(removedRows + retainedRows) }
        let retainedPrimaryKeys = retainedRows.map { $0.value(forKey: "primary") as! String }
        // Verify that all credential families were actually admitted before
        // deletion; an unavailable write cannot create a vacuous success.
        for jid in [owner, otherOwner] {
            XCTAssertEqual(try credentials.getOMEMO2State(for: jid), Data("native:\(jid)".utf8))
            XCTAssertEqual(try credentials.getRetiredOMEMO2StateForPolicyMigration(for: jid), Data("retired:\(jid)".utf8))
            XCTAssertEqual(credentials.getIdentityKeyPublicKey(for: jid), Data([1, 2]))
            XCTAssertEqual(credentials.getIdentityKeyPrivateKey(for: jid), Data([3, 4]))
            XCTAssertEqual(credentials.getDeviceId(for: jid), 42)
            XCTAssertEqual(credentials.getRegistrationId(for: jid), 84)
            XCTAssertEqual(credentials.getPreKey(for: jid, id: 7), Data([5, 6]))
            XCTAssertEqual(credentials.getSignedPreKey(for: jid, id: 1), Data([7, 8]))
        }

        if commitTransaction {
            OmemoManager.remove(for: owner, commitTransaction: true)
            XCTAssertFalse(realm.isInWriteTransaction)
        } else {
            try realm.write {
                OmemoManager.remove(for: owner, commitTransaction: false)
                XCTAssertTrue(realm.isInWriteTransaction)
                // The caller still owns the transaction after crypto cleanup.
                (retainedRows.last as! OMEMO2OptOutStorageItem).reason = "caller completed"
            }
        }

        for row in removedRows {
            XCTAssertTrue(row.isInvalidated, "\(type(of: row)) must be removed with the account")
        }
        for (index, row) in retainedRows.enumerated() {
            XCTAssertFalse(row.isInvalidated, "The same peer/device under another owner must remain")
            XCTAssertEqual(row.value(forKey: "primary") as? String, retainedPrimaryKeys[index])
            XCTAssertEqual(row.value(forKey: "owner") as? String, otherOwner)
        }
        XCTAssertEqual(realm.objects(OMEMO2OptOutStorageItem.self).filter("owner == %@", owner).count, 0)
        XCTAssertEqual(realm.objects(OMEMO2OptOutStorageItem.self).filter("owner == %@", otherOwner).count, 1)
        if !commitTransaction {
            XCTAssertEqual(realm.objects(OMEMO2OptOutStorageItem.self).filter("owner == %@", otherOwner).first?.reason,
                "caller completed")
        }
        XCTAssertNil(try credentials.getOMEMO2State(for: owner))
        XCTAssertNil(try credentials.getRetiredOMEMO2StateForPolicyMigration(for: owner))
        XCTAssertNil(credentials.getIdentityKeyPublicKey(for: owner))
        XCTAssertNil(credentials.getIdentityKeyPrivateKey(for: owner))
        XCTAssertNil(credentials.getDeviceId(for: owner))
        XCTAssertNil(credentials.getRegistrationId(for: owner))
        XCTAssertNil(credentials.getPreKey(for: owner, id: 7))
        XCTAssertNil(credentials.getSignedPreKey(for: owner, id: 1))
        XCTAssertEqual(try credentials.getOMEMO2State(for: otherOwner), Data("native:\(otherOwner)".utf8))
        XCTAssertEqual(try credentials.getRetiredOMEMO2StateForPolicyMigration(for: otherOwner), Data("retired:\(otherOwner)".utf8))
        XCTAssertEqual(credentials.getIdentityKeyPublicKey(for: otherOwner), Data([1, 2]))
        XCTAssertEqual(credentials.getIdentityKeyPrivateKey(for: otherOwner), Data([3, 4]))
        XCTAssertEqual(credentials.getDeviceId(for: otherOwner), 42)
        XCTAssertEqual(credentials.getRegistrationId(for: otherOwner), 84)
        XCTAssertEqual(credentials.getPreKey(for: otherOwner, id: 7), Data([5, 6]))
        XCTAssertEqual(credentials.getSignedPreKey(for: otherOwner, id: 1), Data([7, 8]))
        // Repeated teardown remains harmless for the surviving account.
        if commitTransaction { OmemoManager.remove(for: owner, commitTransaction: true) }
        else { try realm.write { OmemoManager.remove(for: owner, commitTransaction: false) } }
        XCTAssertEqual(try credentials.getOMEMO2State(for: otherOwner), Data("native:\(otherOwner)".utf8))
        XCTAssertTrue(retainedRows.allSatisfy { !$0.isInvalidated })
    }

    private func rows(owner: String) -> [Object] {
        let peer = "same-peer@example.test"
        let identity = SignalIdentityStorageItem()
        identity.deviceId = 42
        identity.cryptoBackend = XabberOMEMO2Storage.backend
        identity.protocolProfile = XabberOMEMO2Storage.profile
        let device = SignalDeviceStorageItem()
        device.deviceId = 42
        device.state = .trusted
        let preKey = SignalPreKeysStorageItem()
        preKey.deviceId = 42
        preKey.pkId = 7
        let session = SessionRecordStorageItem()
        session.deviceId = 42
        session.record = Data([9])
        let list = OMEMO2DeviceListStorageItem()
        list.isKnown = true
        list.deviceIDs.append(42)
        let trust = SignalTrustedIdentityStoreageItem()
        trust.deviceId = 42
        trust.identity = Data([1, 2])
        let sender = SignalSenderKeyStoreageItem()
        sender.deviceId = 42
        sender.senderKey = Data([10])
        let optOut = OMEMO2OptOutStorageItem()
        optOut.decisionRaw = OMEMO2OptOutPolicy.Decision.pending.rawValue
        optOut.reason = "pending peer request"
        let result: [Object] = [identity, device, preKey, session, list, trust, sender, optOut]
        for (index, row) in result.enumerated() {
            row.setValue(owner, forKey: "owner")
            row.setValue(peer, forKey: "jid")
            row.setValue("\(owner):\(index)", forKey: "primary")
        }
        return result
    }

    private func retiredQuery(_ owner: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: CredentialsManager.uniqueServiceName(),
         kSecAttrAccount as String: [owner, XabberOMEMO2Storage.profile, "state-v1"].prp(),
         kSecAttrSynchronizable as String: false]
    }
}

private enum ProtectedStateDeletionFailure: Error, Equatable {
    case rejected
}
