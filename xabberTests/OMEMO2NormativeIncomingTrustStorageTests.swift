import Foundation
import XCTest
@testable import xabber

final class OMEMO2NormativeIncomingTrustStorageTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failWrites = false

        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }

    private enum ValidationFailure: Error { case invalidSCE }

    func testAuthenticatedIdentityIsDeliveredOnlyAfterCommitOutsideLockBeforeCleanup() throws {
        let peer = "n09-callback-peer-\(UUID().uuidString.lowercased())@example.test"
        let owner = "n09-callback-local-\(UUID().uuidString.lowercased())@example.test"
        let memory = Memory()
        let receiver = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let receiverBundle = try receiver.prepare(deviceID: 42, preKeyCount: 8)
        let sender = try XabberOMEMO2Storage(owner: peer, persistence: Memory())
        let senderBundle = try sender.prepare(deviceID: 41, preKeyCount: 8)
        let preKey = try XCTUnwrap(receiverBundle.preKeys.first)
        try sender.initiateSession(jid: owner, deviceID: 42,
            bundle: OMEMO2Bundle(identityKey: receiverBundle.identityKey,
                signedPreKey: receiverBundle.signedPreKey, signedPreKeyID: receiverBundle.signedPreKeyID,
                signature: receiverBundle.signature, preKey: preKey.publicKey, preKeyID: preKey.id))
        let plaintext = Data(repeating: 0, count: 32)
        let ciphertext = try sender.encrypt(plaintext, jid: owner, deviceID: 42)
        let before = memory.records[owner]
        var identities: [Data] = []
        var events: [String] = []
        receiver.authenticatedReceiveDidCommit = { events.append("cleanup") }
        let authenticatedIdentity: (Data) -> Void = { key in
            identities.append(key)
            events.append("identity")
            XCTAssertNotEqual(memory.records[owner], before, "The protected write must precede identity delivery")
            // A second thread must acquire the same owner lock while this
            // callback is running; bounded waiting also exposes a held lock.
            let readCompleted = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = try? receiver.localBundle()
                readCompleted.signal()
            }
            XCTAssertEqual(readCompleted.wait(timeout: .now() + 2), .success)
        }

        XCTAssertThrowsError(try receiver.decrypt(ciphertext, jid: peer, deviceID: 41,
            authenticatedIdentity: authenticatedIdentity, validating: { _ in throw ValidationFailure.invalidSCE }))
        XCTAssertEqual(memory.records[owner], before)
        XCTAssertTrue(identities.isEmpty)
        XCTAssertTrue(events.isEmpty)

        memory.failWrites = true
        XCTAssertThrowsError(try receiver.decrypt(ciphertext, jid: peer, deviceID: 41,
            authenticatedIdentity: authenticatedIdentity))
        XCTAssertEqual(memory.records[owner], before)
        XCTAssertTrue(identities.isEmpty)
        XCTAssertTrue(events.isEmpty)

        memory.failWrites = false
        let decrypted = try receiver.decrypt(ciphertext, jid: peer, deviceID: 41,
            authenticatedIdentity: authenticatedIdentity)
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertEqual(identities, [senderBundle.identityKey])
        XCTAssertEqual(events, ["identity", "cleanup"])
    }
}
