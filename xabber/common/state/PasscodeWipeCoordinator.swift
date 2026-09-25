import Foundation
import UIKit
import RealmSwift
import Security
import UserNotifications
import Kingfisher
import CocoaLumberjack

/// The marker is deliberately cleared only after every local cleanup operation
/// and its verification succeeds. Repeating the operation after a crash is safe.
final class PasscodeWipeTransaction {
    private let marker: PasscodeWipeMarkerStore
    private let cleanup: () throws -> Void

    init(marker: PasscodeWipeMarkerStore, cleanup: @escaping () throws -> Void) {
        self.marker = marker
        self.cleanup = cleanup
    }

    func begin() throws {
        try marker.markPending()
        try resumeIfNeeded()
    }

    func resumeIfNeeded() throws {
        guard try marker.readPending() else { return }
        try cleanup()
        try marker.clearPending()
    }
}

enum PasscodeWipeError: Error {
    case missingKeychainService
    case keychain(OSStatus)
    case realmStillContainsAccounts
    case realmStillContainsData
    case realmFileUnavailable
    case realmFilesStillPresent
    case defaultsUnavailable
    case defaultsStillContainValues
    case fileStillExists
    case notificationsStillPresent
    case notificationVerificationTimedOut
}

enum PasscodeWipeRealmCleaner {
    static func clear(configuration: Realm.Configuration = .defaultConfiguration) throws {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            try realm.write {
                realm.deleteAll()
            }
            try verifyEmpty(realm)
        }
        guard configuration.inMemoryIdentifier == nil else { return }
        guard configuration.fileURL != nil else { throw PasscodeWipeError.realmFileUnavailable }
        // Realm's API refuses deletion while another Realm instance is still
        // open. That failure keeps wipePending set so a cold launch can retry
        // before account and UI managers reopen the database.
        _ = try Realm.deleteFiles(for: configuration)
        // Check and remove any sidecar files left behind by Realm.
        let fileManager = FileManager.default
        for url in diskFileURLs(configuration: configuration) {
            if try fileExists(at: url, fileManager: fileManager) {
                try fileManager.removeItem(at: url)
            }
        }
        try verifyFilesAbsent(configuration: configuration)
    }

    static func diskFileURLs(configuration: Realm.Configuration) -> [URL] {
        guard configuration.inMemoryIdentifier == nil,
              let url = configuration.fileURL else { return [] }
        let path = url.path
        return [
            url,
            URL(fileURLWithPath: path + ".note"),
            URL(fileURLWithPath: path + ".management", isDirectory: true),
            URL(fileURLWithPath: path + ".lock")
        ]
    }

    static func verifyFilesAbsent(configuration: Realm.Configuration = .defaultConfiguration) throws {
        guard configuration.inMemoryIdentifier == nil else {
            try autoreleasepool {
                let realm = try Realm(configuration: configuration)
                try verifyEmpty(realm)
            }
            return
        }
        guard configuration.fileURL != nil else { throw PasscodeWipeError.realmFileUnavailable }
        for url in diskFileURLs(configuration: configuration) {
            guard try !fileExists(at: url, fileManager: .default) else {
                throw PasscodeWipeError.realmFilesStillPresent
            }
        }
    }

    private static func fileExists(at url: URL, fileManager: FileManager) throws -> Bool {
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
                return false
            }
            throw error
        }
    }
}

final class PasscodeWipeCoordinator {
    static let shared = PasscodeWipeCoordinator()

    private let marker = PasscodeWipeMarkerStore.live()
    private let cleanupQueue = DispatchQueue(label: "com.xabber.passcode-wipe", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isRunning = false
    private var completions: [(Bool) -> Void] = []

    private init() {}

    var isPending: Bool { marker.isPendingOrUnavailable }

    /// Persisted synchronously before scheduling any destructive work.
    @discardableResult
    func beginWipe(completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        do {
            try marker.markPending()
        } catch {
            DDLogError("Passcode wipe: unable to persist terminal marker")
            DispatchQueue.main.async { completion(false) }
            return false
        }
        resumeIfNeeded(completion: completion)
        return true
    }

    func resumeIfNeeded(completion: @escaping (Bool) -> Void) {
        do {
            guard try marker.readPending() else {
                DispatchQueue.main.async { completion(true) }
                return
            }
        } catch {
            DDLogError("Passcode wipe: terminal marker cannot be read")
            DispatchQueue.main.async { completion(false) }
            return
        }

        stateLock.lock()
        completions.append(completion)
        let shouldStart = !isRunning
        if shouldStart { isRunning = true }
        stateLock.unlock()
        guard shouldStart else { return }

        let stopAccounts = { [self] in
            AccountManager.shared.prepareForPasscodeWipe()
            NotifyManager.shared.clearAllNotifications()
            cleanupQueue.async { [self] in
                let succeeded: Bool
                do {
                    let transaction = PasscodeWipeTransaction(marker: marker) {
                        try self.clearLocalData()
                    }
                    try transaction.resumeIfNeeded()
                    succeeded = true
                } catch {
                    DDLogError("Passcode wipe: local cleanup failed; will resume on next launch")
                    succeeded = false
                }
                DispatchQueue.main.async { [self] in
                    stateLock.lock()
                    let callbacks = completions
                    completions.removeAll()
                    isRunning = false
                    stateLock.unlock()
                    callbacks.forEach { $0(succeeded) }
                }
            }
        }
        if Thread.isMainThread {
            stopAccounts()
        } else {
            DispatchQueue.main.async(execute: stopAccounts)
        }
    }

    private func clearLocalData() throws {
        try PasscodeWipeRealmCleaner.clear()
        try clearKeychainService()
        try clearOwnedFiles()
        try clearDefaults()
        try verifyNotificationsCleared()
        try PasscodeWipeRealmCleaner.verifyFilesAbsent()
        try verifyKeychainServiceEmpty()
        // The enrollment marker is a separate backup-eligible file. Keep it
        // until all other data has been verified, then remove it with PIN keys.
        try PasscodeCredentialStore.shared.clear()
    }

    private func keychainQueries() throws -> [[String: Any]] {
        let service = CredentialsManager.uniqueServiceName()
        guard !service.isEmpty else { throw PasscodeWipeError.missingKeychainService }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let accessGroup = CredentialsManager.uniqueKeychainAccessGroup()
        guard !accessGroup.isEmpty else { return [base] }
        var grouped = base
        grouped[kSecAttrAccessGroup as String] = accessGroup
        return [grouped, base]
    }

    private func clearKeychainService() throws {
        for query in try keychainQueries() {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PasscodeWipeError.keychain(status)
            }
        }
        try verifyKeychainServiceEmpty()
    }

    private func verifyKeychainServiceEmpty() throws {
        for query in try keychainQueries() {
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            guard status == errSecItemNotFound else {
                throw PasscodeWipeError.keychain(status)
            }
        }
    }

    private func clearDefaults() throws {
        let suite = CredentialsManager.uniqueAccessGroup()
        guard !suite.isEmpty,
              let groupDefaults = UserDefaults(suiteName: suite),
              let appID = Bundle.main.bundleIdentifier,
              !appID.isEmpty else {
            throw PasscodeWipeError.defaultsUnavailable
        }
        groupDefaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.removePersistentDomain(forName: appID)
        guard groupDefaults.synchronize(),
              UserDefaults.standard.synchronize(),
              groupDefaults.persistentDomain(forName: suite)?.isEmpty != false,
              UserDefaults.standard.persistentDomain(forName: appID)?.isEmpty != false else {
            throw PasscodeWipeError.defaultsStillContainValues
        }
    }

    private func clearOwnedFiles() throws {
        let fileManager = FileManager.default
        ImageCache.default.memoryStorage.removeAll()
        do {
            try ImageCache.default.diskStorage.removeAll()
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                throw error
            }
        }
        let configuration = Realm.Configuration.defaultConfiguration
        let realmFile = configuration.inMemoryIdentifier == nil ? configuration.fileURL : nil
        let protectedRealmURLs: Set<URL> = realmFile.map { url in
            let path = url.path
            return Set([
                url,
                URL(fileURLWithPath: path + ".lock"),
                URL(fileURLWithPath: path + ".management", isDirectory: true),
                URL(fileURLWithPath: path + ".note")
            ])
        } ?? []

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let appEnrollmentDirectory = appSupport?
            .appendingPathComponent("PasscodeSecurity", isDirectory: true)
        let roots: [URL?] = [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            appSupport,
            fileManager.temporaryDirectory
        ]
        for root in roots.compactMap({ $0 }) {
            try removeContents(of: root, protecting: protectedRealmURLs.union([appEnrollmentDirectory].compactMap { $0 }))
        }

        let groupID = CredentialsManager.uniqueAccessGroup()
        if !groupID.isEmpty,
           let groupRoot = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            guard let markerURL = marker.markerURL else {
                throw PasscodeWipeMarkerStore.MarkerError.unavailable
            }
            try removeContents(
                of: groupRoot,
                protecting: [
                    markerURL,
                    groupRoot.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                ]
            )
        } else if !groupID.isEmpty,
                  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            throw PasscodeWipeMarkerStore.MarkerError.unavailable
        }

    }

    private func removeContents(of directory: URL, protecting protectedURLs: Set<URL>) throws {
        let fileManager = FileManager.default
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return
            }
            throw error
        }

        for child in contents {
            let standardized = child.standardizedFileURL
            if protectedURLs.contains(standardized) { continue }
            let containsProtectedDescendant = protectedURLs.contains { protected in
                protected.path.hasPrefix(standardized.path + "/")
            }
            if containsProtectedDescendant {
                try removeContents(of: child, protecting: protectedURLs)
                continue
            }
            try fileManager.removeItem(at: child)
            guard !fileManager.fileExists(atPath: child.path) else {
                throw PasscodeWipeError.fileStillExists
            }
        }
    }

    private func verifyNotificationsCleared() throws {
        let center = UNUserNotificationCenter.current()
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var pendingCount: Int?
        var deliveredCount: Int?
        center.getPendingNotificationRequests { requests in
            resultLock.lock()
            pendingCount = requests.count
            resultLock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw PasscodeWipeError.notificationVerificationTimedOut
        }
        center.getDeliveredNotifications { notifications in
            resultLock.lock()
            deliveredCount = notifications.count
            resultLock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw PasscodeWipeError.notificationVerificationTimedOut
        }
        guard pendingCount == 0 && deliveredCount == 0 else {
            throw PasscodeWipeError.notificationsStillPresent
        }
    }
}

private extension PasscodeWipeRealmCleaner {
    static func verifyEmpty(_ realm: Realm) throws {
        guard realm.objects(AccountStorageItem.self).isEmpty else {
            throw PasscodeWipeError.realmStillContainsAccounts
        }
        for schema in realm.schema.objectSchema where !schema.isEmbedded {
            guard realm.dynamicObjects(schema.className).isEmpty else {
                throw PasscodeWipeError.realmStillContainsData
            }
        }
    }
}
