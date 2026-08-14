import UIKit
import XCTest
import Kingfisher
@testable import xabber

final class PushAvatarSnapshotPublisherTests: XCTestCase {
    private let owner = "romeo@example.com"
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PushAvatarSnapshotPublisherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testNewerTokenPreventsOlderCompletionFromReplacingSnapshot() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let publisher = makePublisher(store: store)
        let identity = contactIdentity(owner: owner)
        let oldToken = publisher.begin(identity: identity, sourceKey: "old-avatar")
        let newToken = publisher.begin(identity: identity, sourceKey: "new-avatar")
        let newImage = makeImage(color: .systemGreen)
        let oldImage = makeImage(color: .systemRed)
        let newCompletion = expectation(description: "new snapshot stored")
        let oldCompletion = expectation(description: "old snapshot rejected")

        publisher.publish(newImage, token: newToken) { result in
            XCTAssertEqual(result, .stored)
            newCompletion.fulfill()
        }
        publisher.publish(oldImage, token: oldToken) { result in
            XCTAssertEqual(result, .stale)
            oldCompletion.fulfill()
        }

        wait(for: [newCompletion, oldCompletion], timeout: 2)
        XCTAssertEqual(
            store.imageData(for: identity),
            PushNotificationAvatarStore.snapshotData(from: newImage)
        )
        XCTAssertTrue(store.hasValidSnapshot(for: identity, sourceKey: "new-avatar"))
        XCTAssertFalse(store.hasValidSnapshot(for: identity, sourceKey: "old-avatar"))
    }

    func testOwnerPurgeRejectsLateCompletionAndDoesNotRecreateDirectory() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        try store.store(
            imageData: try XCTUnwrap(makeImage(color: .systemBlue).pngData()),
            for: identity,
            sourceKey: "existing-avatar"
        )
        let writeStarted = expectation(description: "late write started")
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        let publisher = makePublisher(
            store: store,
            writer: { data, identity, sourceKey in
                writeStarted.fulfill()
                allowWriteToFinish.wait()
                try store.store(
                    imageData: data,
                    for: identity,
                    sourceKey: sourceKey
                )
            }
        )
        let lateToken = publisher.begin(identity: identity, sourceKey: "late-avatar")
        let purgeCompletion = expectation(description: "owner purged")
        let lateCompletion = expectation(description: "late snapshot rejected")

        publisher.publish(makeImage(color: .systemRed), token: lateToken) { result in
            XCTAssertEqual(result, .stale)
            lateCompletion.fulfill()
        }
        wait(for: [writeStarted], timeout: 2)
        publisher.removeAll(owner: owner) {
            purgeCompletion.fulfill()
        }
        allowWriteToFinish.signal()

        wait(for: [lateCompletion, purgeCompletion], timeout: 2)
        XCTAssertNil(store.imageData(for: identity))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.fileURL(for: identity).deletingLastPathComponent().path
            )
        )
    }

    func testMatchingSourceManifestSkipsImageEncoding() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        let existingData = try XCTUnwrap(makeImage(color: .systemPurple).pngData())
        try store.store(
            imageData: existingData,
            for: identity,
            sourceKey: "same-avatar"
        )
        let lock = NSLock()
        var encodeCount = 0
        let publisher = makePublisher(store: store, encoder: { image in
            lock.lock()
            encodeCount += 1
            lock.unlock()
            return image.pngData()
        })
        let token = publisher.begin(identity: identity, sourceKey: "same-avatar")
        let completion = expectation(description: "current snapshot skipped")

        publisher.publish(makeImage(color: .systemOrange), token: token) { result in
            XCTAssertEqual(result, .alreadyCurrent)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        lock.lock()
        let finalEncodeCount = encodeCount
        lock.unlock()
        XCTAssertEqual(finalEncodeCount, 0)
        XCTAssertEqual(store.imageData(for: identity), existingData)
    }

    func testDuplicatePendingPublishesAreCoalescedIntoSingleJob() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        let lock = NSLock()
        var encodeCount = 0
        var writeCount = 0
        let writerStarted = expectation(description: "coalesced writer started")
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        let publisher = makePublisher(
            store: store,
            encoder: { image in
                lock.lock()
                encodeCount += 1
                lock.unlock()
                return image.pngData()
            },
            writer: { data, identity, sourceKey in
                lock.lock()
                writeCount += 1
                lock.unlock()
                writerStarted.fulfill()
                allowWriteToFinish.wait()
                try store.store(
                    imageData: data,
                    for: identity,
                    sourceKey: sourceKey
                )
            }
        )
        let token = publisher.begin(identity: identity, sourceKey: "same-avatar")
        let completions = expectation(description: "all duplicate callers completed")
        completions.expectedFulfillmentCount = 3

        publisher.publish(makeImage(color: .systemGreen), token: token) { result in
            XCTAssertEqual(result, .stored)
            completions.fulfill()
        }
        wait(for: [writerStarted], timeout: 2)
        for _ in 0..<2 {
            publisher.publish(makeImage(color: .systemGreen), token: token) { result in
                XCTAssertEqual(result, .stored)
                completions.fulfill()
            }
        }
        XCTAssertEqual(publisher.pendingPublishCount, 1)
        allowWriteToFinish.signal()

        wait(for: [completions], timeout: 2)
        lock.lock()
        let finalEncodeCount = encodeCount
        let finalWriteCount = writeCount
        lock.unlock()
        XCTAssertEqual(finalEncodeCount, 1)
        XCTAssertEqual(finalWriteCount, 1)
        XCTAssertEqual(publisher.pendingPublishCount, 0)
    }

    func testInvalidationImmediatelyCancelsPendingDuplicateCallbacks() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        let writerStarted = expectation(description: "writer started")
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        let publisher = makePublisher(
            store: store,
            writer: { data, identity, sourceKey in
                writerStarted.fulfill()
                allowWriteToFinish.wait()
                try store.store(
                    imageData: data,
                    for: identity,
                    sourceKey: sourceKey
                )
            }
        )
        let token = publisher.begin(identity: identity, sourceKey: "avatar")
        let cancelledCallbacks = expectation(description: "callbacks cancelled immediately")
        cancelledCallbacks.expectedFulfillmentCount = 2

        for _ in 0..<2 {
            publisher.publish(makeImage(color: .systemBlue), token: token) { result in
                XCTAssertEqual(result, .stale)
                cancelledCallbacks.fulfill()
            }
        }
        wait(for: [writerStarted], timeout: 2)
        let removalCompleted = expectation(description: "snapshot removed")
        publisher.remove(identity: identity) {
            removalCompleted.fulfill()
        }

        let cancellationResult = XCTWaiter.wait(
            for: [cancelledCallbacks],
            timeout: 0.5
        )
        XCTAssertEqual(cancellationResult, .completed)
        XCTAssertEqual(publisher.pendingPublishCount, 0)
        allowWriteToFinish.signal()
        wait(for: [removalCompleted], timeout: 2)
    }

    func testPendingPublisherIsBoundedAndUnrelatedBeginRemainsFast() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let writeStarted = expectation(description: "first bounded write started")
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        let dropped = expectation(description: "excess snapshots dropped")
        dropped.expectedFulfillmentCount = 12
        let accepted = expectation(description: "bounded snapshots drained")
        accepted.expectedFulfillmentCount = 4
        let writerLock = NSLock()
        var writerCount = 0
        let publisher = makePublisher(
            store: store,
            maximumPendingPublishes: 4,
            writer: { data, identity, sourceKey in
                writerLock.lock()
                writerCount += 1
                let isFirstWrite = writerCount == 1
                writerLock.unlock()
                if isFirstWrite {
                    writeStarted.fulfill()
                    allowWriteToFinish.wait()
                }
                try store.storePending(
                    imageData: data,
                    for: identity,
                    sourceKey: sourceKey
                )
            }
        )

        for index in 0..<16 {
            let identity = PushNotificationAvatarIdentity(
                owner: owner,
                contactJid: "contact-\(index)@example.com"
            )
            let token = publisher.begin(
                identity: identity,
                sourceKey: "avatar-\(index)"
            )
            publisher.publish(makeImage(color: .systemCyan), token: token) { result in
                switch result {
                case .failed:
                    dropped.fulfill()
                case .stored:
                    accepted.fulfill()
                default:
                    XCTFail("Unexpected bounded publish result: \(result)")
                }
            }
        }
        wait(for: [writeStarted, dropped], timeout: 2)

        XCTAssertLessThanOrEqual(publisher.pendingPublishCount, 4)
        let startedAt = ProcessInfo.processInfo.systemUptime
        _ = publisher.begin(
            identity: PushNotificationAvatarIdentity(
                owner: owner,
                contactJid: "unrelated@example.com"
            ),
            sourceKey: "unrelated-avatar"
        )
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            0.1
        )
        allowWriteToFinish.signal()
        wait(for: [accepted], timeout: 2)
    }

    func testMissingManagedRecordRejectsPublishButExplicitTransientScopeAllowsIt() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let publisher = makePublisher(
            store: store,
            sourceRevisionProvider: { token in
                guard token.sourceScope == .unmanagedTransient else { return nil }
                return PushAvatarSnapshotRevision.make(
                    sourceKeys: [token.sourceKey],
                    metadataRevision: token.metadataRevision
                )
            }
        )
        let identity = contactIdentity(owner: owner)
        let managedToken = publisher.begin(
            identity: identity,
            sourceKey: "avatar",
            sourceScope: .managed
        )
        let transientToken = publisher.begin(
            identity: identity,
            sourceKey: "avatar",
            metadataRevision: "message-card-v1",
            sourceScope: .unmanagedTransient
        )
        let managedCompletion = expectation(description: "managed record rejected")
        let transientCompletion = expectation(description: "explicit transient stored")

        publisher.publish(makeImage(color: .systemRed), token: managedToken) { result in
            XCTAssertEqual(result, .stale)
            managedCompletion.fulfill()
        }
        publisher.publish(makeImage(color: .systemGreen), token: transientToken) { result in
            XCTAssertEqual(result, .stored)
            transientCompletion.fulfill()
        }

        wait(for: [managedCompletion, transientCompletion], timeout: 2)
        XCTAssertNotNil(store.imageData(for: identity))
    }

    func testMetadataRevisionChangesManifestRevisionEvenWhenURLIsReused() {
        let firstRevision = PushAvatarSnapshotRevision.make(
            sourceKeys: ["https://cdn.example/avatar.png"],
            metadataRevision: "hash-v1"
        )
        let secondRevision = PushAvatarSnapshotRevision.make(
            sourceKeys: ["https://cdn.example/avatar.png"],
            metadataRevision: "hash-v2"
        )
        let publisher = makePublisher(
            store: PushNotificationAvatarStore(rootURL: temporaryDirectory)
        )
        let identity = contactIdentity(owner: owner)
        let firstToken = publisher.begin(
            identity: identity,
            sourceKey: "https://cdn.example/avatar.png",
            metadataRevision: "hash-v1"
        )
        let secondToken = publisher.begin(
            identity: identity,
            sourceKey: "https://cdn.example/avatar.png",
            metadataRevision: "hash-v2"
        )

        XCTAssertNotEqual(firstRevision, secondRevision)
        XCTAssertNotEqual(firstToken, secondToken)
    }

    func testOldSameURLCompletionCannotReplaceBytesAfterMetadataRevisionChanges() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        let lock = NSLock()
        var writeCount = 0
        let oldWriteStarted = expectation(description: "old same-URL write started")
        let allowOldWriteToFinish = DispatchSemaphore(value: 0)
        let publisher = makePublisher(
            store: store,
            sourceRevisionProvider: { token in
                PushAvatarSnapshotRevision.make(
                    sourceKeys: [token.sourceKey],
                    metadataRevision: token.metadataRevision
                )
            },
            writer: { data, identity, sourceRevision in
                lock.lock()
                writeCount += 1
                let shouldBlock = writeCount == 1
                lock.unlock()
                if shouldBlock {
                    oldWriteStarted.fulfill()
                    allowOldWriteToFinish.wait()
                }
                try store.store(
                    imageData: data,
                    for: identity,
                    sourceKey: sourceRevision
                )
            }
        )
        let reusedURL = "https://cdn.example/avatar.png"
        let oldToken = publisher.begin(
            identity: identity,
            sourceKey: reusedURL,
            metadataRevision: "hash-v1"
        )
        let oldCompletion = expectation(description: "old revision cancelled")
        publisher.publish(makeImage(color: .systemRed), token: oldToken) { result in
            XCTAssertEqual(result, .stale)
            oldCompletion.fulfill()
        }
        wait(for: [oldWriteStarted], timeout: 2)

        let newToken = publisher.begin(
            identity: identity,
            sourceKey: reusedURL,
            metadataRevision: "hash-v2"
        )
        let newImage = makeImage(color: .systemGreen)
        let newCompletion = expectation(description: "new revision stored")
        publisher.publish(newImage, token: newToken) { result in
            XCTAssertEqual(result, .stored)
            newCompletion.fulfill()
        }
        allowOldWriteToFinish.signal()

        wait(for: [oldCompletion, newCompletion], timeout: 2)
        XCTAssertEqual(
            store.imageData(for: identity),
            PushNotificationAvatarStore.snapshotData(from: newImage)
        )
        XCTAssertTrue(
            store.hasValidSnapshot(
                for: identity,
                sourceKey: PushAvatarSnapshotRevision.make(
                    sourceKeys: [reusedURL],
                    metadataRevision: "hash-v2"
                )
            )
        )
    }

    func testBackfillBudgetStopsAtItemAndDeadlineBounds() {
        var countBudget = PushAvatarBackfillBudget(
            maximumCandidates: 2,
            deadlineUptime: 100
        )
        XCTAssertTrue(countBudget.claim(at: 1))
        XCTAssertTrue(countBudget.claim(at: 2))
        XCTAssertFalse(countBudget.claim(at: 3))

        var timeBudget = PushAvatarBackfillBudget(
            maximumCandidates: 10,
            deadlineUptime: 5
        )
        XCTAssertTrue(timeBudget.claim(at: 4.99))
        XCTAssertFalse(timeBudget.claim(at: 5))
    }

    func testBackfillGroupIdentityUsesResolvedBareGroupJid() throws {
        let identity = try XCTUnwrap(
            DefaultAvatarManager.pushAvatarGroupIdentity(
                owner: owner,
                storedGroupPrimary: "room_conference_example_com_owner",
                resolvedGroupJid: "room@conference.example.com",
                participantId: "member-a"
            )
        )

        XCTAssertEqual(identity.entityJid, "room@conference.example.com")
        XCTAssertNotEqual(identity.entityJid, "room_conference_example_com_owner")
    }

    func testGroupRevisionIncludesPermanentAndTemporaryAvatarHashes() {
        let first = DefaultAvatarManager.groupAvatarMetadataRevision(
            avatarHash: "permanent-v1",
            temporaryAvatarHash: "temporary-v1"
        )
        let second = DefaultAvatarManager.groupAvatarMetadataRevision(
            avatarHash: "permanent-v1",
            temporaryAvatarHash: "temporary-v2"
        )

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first?.contains("permanent-v1") == true)
        XCTAssertTrue(first?.contains("temporary-v1") == true)
    }

    func testBatchInvalidationImmediatelyTombstonesEveryGroupIdentity() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let publisher = makePublisher(store: store)
        let identities = [
            PushNotificationAvatarIdentity(
                owner: owner,
                contactJid: "room@conference.example.com"
            ),
            PushNotificationAvatarIdentity(
                owner: owner,
                groupchat: "room@conference.example.com",
                participantId: "member-a"
            ),
            PushNotificationAvatarIdentity(
                owner: owner,
                groupchat: "room@conference.example.com",
                participantId: "member-b"
            )
        ]
        let data = try XCTUnwrap(makeImage(color: .systemIndigo).pngData())
        for identity in identities {
            try store.store(imageData: data, for: identity, sourceKey: "old")
        }

        publisher.remove(identities: identities)

        XCTAssertTrue(identities.allSatisfy { store.imageData(for: $0) == nil })
    }

    func testAvatarClearTargetUsesRecipientWhenPresent() {
        XCTAssertEqual(
            AvatarUploadManager.avatarClearTargetJid(
                owner: owner,
                recipient: "room@conference.example.com"
            ),
            "room@conference.example.com"
        )
        XCTAssertEqual(
            AvatarUploadManager.avatarClearTargetJid(owner: owner, recipient: nil),
            owner
        )
    }

    func testPublisherEncodesAwayFromMainThread() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        let completion = expectation(description: "snapshot encoded")
        let lock = NSLock()
        var encodedOnMainThread: Bool?
        let publisher = makePublisher(store: store, encoder: { image in
            lock.lock()
            encodedOnMainThread = Thread.isMainThread
            lock.unlock()
            return image.pngData()
        })
        let token = publisher.begin(identity: identity, sourceKey: "async-avatar")

        publisher.publish(makeImage(color: .systemTeal), token: token) { result in
            XCTAssertEqual(result, .stored)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        lock.lock()
        let finalEncodedOnMainThread = encodedOnMainThread
        lock.unlock()
        XCTAssertEqual(finalEncodedOnMainThread, false)
    }

    func testBeginDoesNotWaitForSnapshotDiskWrite() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        let writeStarted = expectation(description: "snapshot write started")
        let publishCompletion = expectation(description: "stale write cleaned up")
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        let publisher = makePublisher(
            store: store,
            writer: { data, identity, sourceKey in
                writeStarted.fulfill()
                allowWriteToFinish.wait()
                try store.store(
                    imageData: data,
                    for: identity,
                    sourceKey: sourceKey
                )
            }
        )
        let oldToken = publisher.begin(identity: identity, sourceKey: "old-avatar")

        publisher.publish(makeImage(color: .systemRed), token: oldToken) { result in
            XCTAssertEqual(result, .stale)
            publishCompletion.fulfill()
        }
        wait(for: [writeStarted], timeout: 2)

        let beginReturned = expectation(description: "begin is not blocked by disk I/O")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = publisher.begin(identity: identity, sourceKey: "new-avatar")
            beginReturned.fulfill()
        }
        let beginResult = XCTWaiter.wait(for: [beginReturned], timeout: 0.5)
        allowWriteToFinish.signal()

        XCTAssertEqual(beginResult, .completed)
        wait(for: [publishCompletion], timeout: 2)
        XCTAssertNil(store.imageData(for: identity))
    }

    func testTokenStartedAfterOwnerPurgeIsRejectedWhenOwnerIsUnavailable() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let availabilityLock = NSLock()
        var ownerIsAvailable = true
        let publisher = makePublisher(
            store: store,
            sourceRevisionProvider: { token in
                availabilityLock.lock()
                defer { availabilityLock.unlock() }
                return ownerIsAvailable ? token.sourceKey : nil
            }
        )
        let identity = contactIdentity(owner: owner)
        let purgeCompletion = expectation(description: "owner purged")
        publisher.removeAll(owner: owner) {
            purgeCompletion.fulfill()
        }
        wait(for: [purgeCompletion], timeout: 2)
        availabilityLock.lock()
        ownerIsAvailable = false
        availabilityLock.unlock()

        let tokenAfterPurge = publisher.begin(
            identity: identity,
            sourceKey: "late-avatar"
        )
        let publishCompletion = expectation(description: "unavailable owner rejected")
        publisher.publish(makeImage(color: .systemRed), token: tokenAfterPurge) { result in
            XCTAssertEqual(result, .stale)
            publishCompletion.fulfill()
        }

        wait(for: [publishCompletion], timeout: 2)
        XCTAssertNil(store.imageData(for: identity))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.fileURL(for: identity).deletingLastPathComponent().path
            )
        )
    }

    func testStoreSeparatesOwnersGroupsAndParticipants() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let firstOwnerContact = contactIdentity(owner: owner)
        let secondOwnerContact = contactIdentity(owner: "other@example.com")
        let firstGroupParticipant = PushNotificationAvatarIdentity(
            owner: owner,
            groupchat: "first@conference.example.com",
            participantId: "member-a"
        )
        let secondGroupParticipant = PushNotificationAvatarIdentity(
            owner: owner,
            groupchat: "second@conference.example.com",
            participantId: "member-a"
        )
        let snapshots = [
            (firstOwnerContact, "contact-first", makeImage(color: .systemRed)),
            (secondOwnerContact, "contact-second", makeImage(color: .systemBlue)),
            (firstGroupParticipant, "group-first", makeImage(color: .systemGreen)),
            (secondGroupParticipant, "group-second", makeImage(color: .systemOrange))
        ]

        for (identity, sourceKey, image) in snapshots {
            try store.store(
                imageData: try XCTUnwrap(image.pngData()),
                for: identity,
                sourceKey: sourceKey
            )
        }

        for (identity, sourceKey, image) in snapshots {
            XCTAssertEqual(store.imageData(for: identity), image.pngData())
            XCTAssertTrue(store.hasValidSnapshot(for: identity, sourceKey: sourceKey))
        }
        XCTAssertEqual(Set(snapshots.map { store.fileURL(for: $0.0) }).count, snapshots.count)
    }

    func testPersistentDeletionMarkerHidesBytesUntilACommittedReplacement() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        let oldData = try XCTUnwrap(makeImage(color: .systemRed).pngData())
        let newData = try XCTUnwrap(makeImage(color: .systemGreen).pngData())
        try store.store(imageData: oldData, for: identity, sourceKey: "old")

        try store.markDeleted(identity: identity)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: identity).path))
        XCTAssertNil(store.imageData(for: identity))
        try store.store(imageData: newData, for: identity, sourceKey: "new")
        XCTAssertEqual(store.imageData(for: identity), newData)
    }

    func testPersistentOwnerDeletionMarkerIsClearedOnlyByNewOwnerBytes() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = contactIdentity(owner: owner)
        let imageData = try XCTUnwrap(makeImage(color: .systemPurple).pngData())
        try store.store(imageData: imageData, for: identity, sourceKey: "old")

        try store.markDeleted(owner: owner)

        XCTAssertNil(store.imageData(for: identity))
        store.removeAll(owner: owner)
        XCTAssertNil(store.imageData(for: identity))
        try store.store(imageData: imageData, for: identity, sourceKey: "new")
        XCTAssertEqual(store.imageData(for: identity), imageData)
    }

    func testUnavailableRootNeverReadsPredictableTemporaryFallback() throws {
        let store = PushNotificationAvatarStore(rootURL: nil)
        let identity = contactIdentity(owner: owner)
        let fallbackURL = store.fileURL(for: identity)
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(makeImage(color: .systemPink).pngData()).write(
            to: fallbackURL,
            options: .atomic
        )
        defer {
            try? FileManager.default.removeItem(
                at: fallbackURL.deletingLastPathComponent().deletingLastPathComponent()
            )
        }

        XCTAssertNil(store.imageData(for: identity))
        XCTAssertFalse(store.hasValidSnapshot(for: identity, sourceKey: "avatar"))
        XCTAssertThrowsError(
            try store.store(
                imageData: try XCTUnwrap(makeImage(color: .systemPink).pngData()),
                for: identity,
                sourceKey: "avatar"
            )
        )
    }

    func testSnapshotFailureIsBestEffortAndDoesNotMutateSourceImage() throws {
        let store = PushNotificationAvatarStore(rootURL: nil)
        let publisher = makePublisher(store: store)
        let identity = contactIdentity(owner: owner)
        let image = makeImage(color: .systemOrange)
        let originalBytes = try XCTUnwrap(image.pngData())
        let token = publisher.begin(identity: identity, sourceKey: "avatar")
        let completion = expectation(description: "best-effort snapshot failed")

        publisher.publish(image, token: token) { result in
            XCTAssertEqual(result, .failed)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        XCTAssertEqual(image.pngData(), originalBytes)
        XCTAssertNil(store.imageData(for: identity))
    }

    func testSnapshotRemovalDoesNotTouchKingfisherSourceCache() {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let publisher = makePublisher(store: store)
        let identity = contactIdentity(owner: owner)
        let cacheKey = "push-avatar-isolation-\(UUID().uuidString)"
        let image = makeImage(color: .systemMint)
        let options = KingfisherParsedOptionsInfo([.alsoPrefetchToMemory])
        ImageCache.default.store(image, forKey: cacheKey, options: options)
        XCTAssertNotNil(
            ImageCache.default.retrieveImageInMemoryCache(
                forKey: cacheKey,
                options: options
            )
        )
        let removed = expectation(description: "snapshot removal queued")

        publisher.remove(identity: identity) {
            removed.fulfill()
        }

        wait(for: [removed], timeout: 2)
        XCTAssertNotNil(
            ImageCache.default.retrieveImageInMemoryCache(
                forKey: cacheKey,
                options: options
            )
        )
        ImageCache.default.removeImage(forKey: cacheKey)
    }

    func testPushAvatarBoundaryContainsNoAddressBookWriter() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "xabber/common/contacts/CommonContactsMetadataManager.swift",
            "xabber/common/avatar_manager/DefaultAvatarManager.swift",
            "xabber/common/notify_manager/LocalRichNotificationScheduler.swift",
            "xabber/common/notify_manager/RichNotificationAttachmentLoader.swift",
            "xabber/common/notify_manager/RichNotificationPresentation.swift",
            "xabber/xmpp/avatar/AvatarReceiverManager.swift",
            "xabber/xmpp/avatar/AvatarUploadManager.swift",
            "xabber-push-extension/NotificationService.swift"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath)
            )
            XCTAssertFalse(source.contains("CNContactStore"), relativePath)
            XCTAssertFalse(source.contains("CNMutableContact"), relativePath)
            XCTAssertFalse(source.contains("CNSaveRequest"), relativePath)
            XCTAssertFalse(source.contains("import Contacts"), relativePath)
            for line in source.components(separatedBy: .newlines)
                where line.contains("contactIdentifier:") {
                XCTAssertTrue(line.contains("contactIdentifier: nil"), relativePath)
            }
            if relativePath.contains("CommonContactsMetadataManager") {
                XCTAssertFalse(source.contains("contactID"), relativePath)
                XCTAssertFalse(source.contains("\"contactId\""), relativePath)
            }
        }
    }

    func testRosterDeletionInvalidatesSharedPushAvatars() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rosterSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/roster/RosterManager.swift"
            )
        )
        XCTAssertTrue(
            rosterSource.contains("CommonContactsMetadataManager.shared.remove")
        )
    }

    private func makePublisher(
        store: PushNotificationAvatarStore,
        maximumPendingPublishes: Int = 64,
        encoder: @escaping (UIImage) -> Data? = {
            PushNotificationAvatarStore.snapshotData(from: $0)
        },
        sourceRevisionProvider: @escaping (PushAvatarSnapshotGenerationGate.Token) -> String? = {
            $0.sourceKey
        },
        writer: ((Data, PushNotificationAvatarIdentity, String) throws -> Void)? = nil
    ) -> PushAvatarSnapshotPublisher {
        PushAvatarSnapshotPublisher(
            store: store,
            queue: DispatchQueue(
                label: "com.xabber.tests.push-avatar-publisher.\(UUID().uuidString)",
                qos: .utility
            ),
            generationGate: PushAvatarSnapshotGenerationGate(),
            maximumPendingPublishes: maximumPendingPublishes,
            imageEncoder: encoder,
            sourceRevisionProvider: sourceRevisionProvider,
            snapshotWriter: writer
        )
    }

    private func contactIdentity(owner: String) -> PushNotificationAvatarIdentity {
        PushNotificationAvatarIdentity(
            owner: owner,
            contactJid: "juliet@example.com"
        )
    }

    private func makeImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }
}
