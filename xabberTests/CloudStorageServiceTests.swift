import XCTest
@testable import xabber

final class CloudStorageServiceTests: XCTestCase {
    private var owner: String!
    private let baseURL = URL(string: "https://storage.example/api/")!
    private var client: CloudStorageServiceFakeAPIClient!
    private var manager: XabberUploadManager!

    override func setUp() {
        super.setUp()
        owner = "cloud-storage-service-\(UUID().uuidString)@external.example"
        client = CloudStorageServiceFakeAPIClient()
        XabberUploadManager.quotaAPIClient = client
        XabberUploadManager.tokenExpiredTestingHandler = nil
        XabberUploadManager.networkPathMonitorFactory = { nil }

        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.clearPersistedState()
        configuration.storeBasicGalleryURL(baseURL.absoluteString)
        configuration.storeToken("basic-token", galleryType: .basic, baseURL: baseURL)
        manager = XabberUploadManager(withOwner: owner)
    }

    override func tearDown() {
        manager = nil
        AccountGalleryConfiguration(owner: owner).clearPersistedState()
        XabberUploadManager.quotaAPIClient = AlamofireCloudStorageQuotaAPIClient()
        XabberUploadManager.tokenExpiredTestingHandler = nil
        XabberUploadManager.networkPathMonitorFactory = { AccountNWPathMonitor() }
        client = nil
        owner = nil
        super.tearDown()
    }

    func testCleanupRequestsContainEndpointTokenPercentPageAndAvatarExclusion() throws {
        let preview = try XCTUnwrap(
            AlamofireCloudStorageQuotaAPIClient.cleanupPreviewRequest(
                baseURL: baseURL,
                token: "preview-token",
                percent: 25,
                page: 3
            )
        )
        let deletion = try XCTUnwrap(
            AlamofireCloudStorageQuotaAPIClient.cleanupDeleteRequest(
                baseURL: baseURL,
                token: "delete-token",
                percent: 75
            )
        )

        XCTAssertEqual(preview.httpMethod, "GET")
        XCTAssertEqual(
            preview.url?.absoluteString,
            "https://storage.example/api/v1/files/percent/25/?page=3&exclude_avatars=true"
        )
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(preview.url), resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "page", value: "3"),
            URLQueryItem(name: "exclude_avatars", value: "true")
        ])
        XCTAssertEqual(preview.value(forHTTPHeaderField: "Authorization"), "Bearer preview-token")

        XCTAssertEqual(deletion.httpMethod, "DELETE")
        XCTAssertEqual(deletion.url?.absoluteString, "https://storage.example/api/v1/files/percent/75/")
        XCTAssertEqual(deletion.value(forHTTPHeaderField: "Authorization"), "Bearer delete-token")
        XCTAssertEqual(deletion.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(deletion.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        XCTAssertEqual(json, ["exclude_avatars": true])
    }

    func testFilePageAcceptsResultsAndCountAndUsesSelectedContext() {
        client.fileResponse = .response(statusCode: 200, value: [
            "results": [["id": 7]],
            "count": "1",
            "obj_per_page": 50,
            "total_pages": 1
        ])
        var received: Result<CloudStorageListPage, CloudStorageListLoadError>?

        manager.getFilesPage(type: .audio, page: 4) { received = $0 }

        XCTAssertEqual(client.fileCalls.count, 1)
        XCTAssertEqual(client.fileCalls.first?.baseURL, baseURL)
        XCTAssertEqual(client.fileCalls.first?.token, "basic-token")
        XCTAssertEqual(client.fileCalls.first?.type, .audio)
        XCTAssertEqual(client.fileCalls.first?.page, 4)
        switch received {
        case .success(let page):
            XCTAssertEqual(page.items.first?["id"] as? Int, 7)
            XCTAssertEqual(page.totalObjects, 1)
            XCTAssertEqual(page.objectsPerPage, 50)
            XCTAssertEqual(page.totalPages, 1)
            XCTAssertEqual(page.page, 4)
        default:
            XCTFail("Expected a decoded file page")
        }
    }

    func testAvatarPageCompletesWithEmptySuccess() {
        client.avatarResponse = .response(statusCode: 200, value: [
            "items": [],
            "total_objects": 0,
            "obj_per_page": 50,
            "total_pages": 0
        ])
        var received: Result<CloudStorageListPage, CloudStorageListLoadError>?

        manager.getAvatarsPage(page: 1) { received = $0 }

        switch received {
        case .success(let page):
            XCTAssertTrue(page.items.isEmpty)
            XCTAssertEqual(page.totalObjects, 0)
            XCTAssertEqual(page.totalPages, 1)
        default:
            XCTFail("Empty storage must be a terminal success")
        }
    }

    func testFilePageServerAndMalformedResponsesCompleteWithTypedErrors() {
        client.fileResponse = .failure(statusCode: 503, error: nil)
        var serverError: CloudStorageListLoadError?
        manager.getFilesPage(type: .file, page: 1) { result in
            if case .failure(let error) = result { serverError = error }
        }

        client.fileResponse = .response(statusCode: 200, value: ["count": 1])
        var malformedError: CloudStorageListLoadError?
        manager.getFilesPage(type: .file, page: 1) { result in
            if case .failure(let error) = result { malformedError = error }
        }

        XCTAssertEqual(serverError, .server(statusCode: 503))
        XCTAssertEqual(malformedError, .invalidResponse)
    }

    func testUnavailableListAlwaysCompletes() {
        let unavailableOwner = "unavailable-\(UUID().uuidString)@external.example"
        AccountGalleryConfiguration(owner: unavailableOwner).clearPersistedState()
        let unavailableManager = XabberUploadManager(withOwner: unavailableOwner)
        var completionCount = 0
        var receivedError: CloudStorageListLoadError?

        unavailableManager.getFilesPage(type: .file, page: 1) { result in
            completionCount += 1
            if case .failure(let error) = result { receivedError = error }
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(receivedError, .unavailable)
        AccountGalleryConfiguration(owner: unavailableOwner).clearPersistedState()
    }

    func testCleanupPlanRejectsUnsupportedPercentAndCapturesFullContext() throws {
        let invalid = manager.makeCleanupPlan(percent: 50 + 10)
        if case .failure(let error) = invalid {
            XCTAssertEqual(error, .invalidResponse)
        } else {
            XCTFail("Unsupported cleanup target must fail")
        }

        let plan = try manager.makeCleanupPlan(percent: 50).get()

        XCTAssertEqual(plan.percent, 50)
        XCTAssertEqual(plan.context.owner, owner)
        XCTAssertEqual(plan.context.baseURL, baseURL)
        XCTAssertEqual(plan.context.token, "basic-token")
    }

    func testCleanupPreviewUsesCapturedPlanAndAcceptsEmptyPage() throws {
        client.cleanupResponse = .response(statusCode: 200, value: [
            "results": [],
            "count": 0,
            "obj_per_page": 50,
            "total_pages": 0
        ])
        let plan = try manager.makeCleanupPlan(percent: 25).get()
        var received: Result<CloudStorageListPage, CloudStorageListLoadError>?

        manager.getFilesToDelete(plan: plan, page: 2) { received = $0 }

        XCTAssertEqual(client.cleanupCalls.count, 1)
        XCTAssertEqual(client.cleanupCalls.first?.baseURL, baseURL)
        XCTAssertEqual(client.cleanupCalls.first?.token, "basic-token")
        XCTAssertEqual(client.cleanupCalls.first?.percent, 25)
        XCTAssertEqual(client.cleanupCalls.first?.page, 2)
        XCTAssertEqual(try? received?.get().items.count, 0)
    }

    func testLateCleanupPreviewAfterTokenRotationCompletesAsStaleOnce() throws {
        client.holdCleanupResponse = true
        let plan = try manager.makeCleanupPlan(percent: 75).get()
        var completionCount = 0
        var receivedError: CloudStorageListLoadError?

        manager.getFilesToDelete(plan: plan, page: 1) { result in
            completionCount += 1
            if case .failure(let error) = result { receivedError = error }
        }
        AccountGalleryConfiguration(owner: owner).storeToken(
            "rotated-token",
            galleryType: .basic,
            baseURL: baseURL
        )
        client.completeCleanupTwice(
            .response(statusCode: 200, value: ["items": [], "total_objects": 0])
        )

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(receivedError, .staleSelection)
    }

    func testCleanupDeleteCompletesOnceAndRefreshesQuotaOnlyForSuccess() throws {
        client.deleteResponseHandler = { completion in
            completion(.response(statusCode: 204, value: [:]))
            completion(.failure(statusCode: nil, error: URLError(.networkConnectionLost)))
        }
        let plan = try manager.makeCleanupPlan(percent: 50).get()
        var completionCount = 0
        var receivedResult: Result<Void, CloudStorageListLoadError>?

        manager.deleteMedia(using: plan) {
            completionCount += 1
            receivedResult = $0
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertNotNil(try? receivedResult?.get())
        XCTAssertEqual(client.deleteCalls.count, 1)
        XCTAssertEqual(client.deleteCalls.first?.baseURL, baseURL)
        XCTAssertEqual(client.deleteCalls.first?.token, "basic-token")
        XCTAssertEqual(client.deleteCalls.first?.percent, 50)
        XCTAssertEqual(client.statsCallCount, 1)
    }

    func testCleanupDeleteUnauthorizedReauthsAndDoesNotRefreshQuota() throws {
        client.deleteResponseHandler = { completion in
            completion(.failure(statusCode: 401, error: URLError(.userAuthenticationRequired)))
        }
        let plan = try manager.makeCleanupPlan(percent: 25).get()
        var expiredContexts: [CloudStorageGalleryRequestContext] = []
        XabberUploadManager.tokenExpiredTestingHandler = { expiredContexts.append($0) }
        var receivedError: CloudStorageListLoadError?

        manager.deleteMedia(using: plan) { result in
            if case .failure(let error) = result { receivedError = error }
        }

        XCTAssertEqual(receivedError, .unauthorized)
        XCTAssertEqual(expiredContexts, [plan.context])
        XCTAssertEqual(client.statsCallCount, 0)
    }

    func testCleanupDeleteRejectsRotatedTokenBeforeRequest() throws {
        let plan = try manager.makeCleanupPlan(percent: 75).get()
        AccountGalleryConfiguration(owner: owner).storeToken(
            "rotated-token",
            galleryType: .basic,
            baseURL: baseURL
        )
        var receivedError: CloudStorageListLoadError?

        manager.deleteMedia(using: plan) { result in
            if case .failure(let error) = result { receivedError = error }
        }

        XCTAssertEqual(receivedError, .staleSelection)
        XCTAssertTrue(client.deleteCalls.isEmpty)
        XCTAssertEqual(client.statsCallCount, 0)
    }

    func testCleanupDeleteUsesSelectedPremiumEndpointForExternalAccount() throws {
        let premiumURL = URL(string: "https://premium-storage.example/api/")!
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.reconcilePremiumGalleryAvailability(
            isAvailable: true,
            storageURL: premiumURL.absoluteString
        )
        configuration.storeToken(
            "premium-token",
            galleryType: .premium,
            baseURL: premiumURL
        )
        let plan = try manager.makeCleanupPlan(percent: 25).get()
        var result: Result<Void, CloudStorageListLoadError>?

        manager.deleteMedia(using: plan) { result = $0 }

        XCTAssertNotNil(try? result?.get())
        XCTAssertEqual(plan.context.galleryType, .premium)
        XCTAssertEqual(client.deleteCalls.count, 1)
        XCTAssertEqual(client.deleteCalls.first?.baseURL, premiumURL)
        XCTAssertEqual(client.deleteCalls.first?.token, "premium-token")
        XCTAssertEqual(client.deleteCalls.first?.percent, 25)
        XCTAssertEqual(client.statsCallCount, 1)
    }

    func testCleanupDeleteServerAndTransportFailuresDoNotRefreshQuota() throws {
        let plan = try manager.makeCleanupPlan(percent: 75).get()
        client.deleteResponseHandler = { $0(.failure(statusCode: 500, error: nil)) }
        var serverError: CloudStorageListLoadError?
        manager.deleteMedia(using: plan) { result in
            if case .failure(let error) = result { serverError = error }
        }

        client.deleteResponseHandler = { $0(.failure(statusCode: nil, error: URLError(.notConnectedToInternet))) }
        var transportError: CloudStorageListLoadError?
        manager.deleteMedia(using: plan) { result in
            if case .failure(let error) = result { transportError = error }
        }

        XCTAssertEqual(serverError, .server(statusCode: 500))
        XCTAssertEqual(transportError, .transport)
        XCTAssertEqual(client.statsCallCount, 0)
    }

    func testDeleteFileRoutesAvatarAndRefreshesQuotaOnlyForSuccess() {
        client.fileDeleteResponse = .response(statusCode: 204, value: nil)
        var avatarResult: Result<Void, CloudStorageListLoadError>?
        manager.deleteFile(fileID: 11, isAvatar: true) { avatarResult = $0 }

        client.fileDeleteResponse = .failure(statusCode: 500, error: nil)
        var fileError: CloudStorageListLoadError?
        manager.deleteFile(fileID: 22, isAvatar: false) { result in
            if case .failure(let error) = result { fileError = error }
        }

        XCTAssertNotNil(try? avatarResult?.get())
        XCTAssertEqual(fileError, .server(statusCode: 500))
        XCTAssertEqual(client.fileDeleteCalls.map(\.fileID), [11, 22])
        XCTAssertEqual(client.fileDeleteCalls.map(\.isAvatar), [true, false])
        XCTAssertEqual(client.statsCallCount, 1)
    }
}

private final class CloudStorageServiceFakeAPIClient: CloudStorageQuotaAPIClient {
    struct FileCall {
        let baseURL: URL
        let token: String
        let type: MimeIconTypes
        let page: Int
    }

    struct CleanupCall {
        let baseURL: URL
        let token: String
        let percent: Int
        let page: Int
    }

    struct DeleteCall {
        let baseURL: URL
        let token: String
        let percent: Int
    }

    var fileResponse: CloudStorageQuotaAPIResponse = .response(statusCode: 200, value: ["items": []])
    var avatarResponse: CloudStorageQuotaAPIResponse = .response(statusCode: 200, value: ["items": []])
    var cleanupResponse: CloudStorageQuotaAPIResponse = .response(statusCode: 200, value: ["items": []])
    var holdCleanupResponse = false
    var fileDeleteResponse: CloudStorageQuotaAPIResponse = .response(statusCode: 204, value: nil)
    var deleteResponseHandler: (@escaping (CloudStorageQuotaAPIResponse) -> Void) -> Void = {
        $0(.response(statusCode: 204, value: [:]))
    }
    private var pendingCleanup: ((CloudStorageQuotaAPIResponse) -> Void)?
    private(set) var fileCalls: [FileCall] = []
    private(set) var avatarCalls: [(baseURL: URL, token: String, page: Int)] = []
    private(set) var cleanupCalls: [CleanupCall] = []
    private(set) var deleteCalls: [DeleteCall] = []
    private(set) var fileDeleteCalls: [(fileID: Int, isAvatar: Bool)] = []
    private(set) var statsCallCount = 0

    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        statsCallCount += 1
        completion(.failure(statusCode: nil, error: URLError(.notConnectedToInternet)))
    }

    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, traceID: String, timeoutInterval: TimeInterval, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func uploadFile(baseURL: URL, token: String, data: Data, filename: String, fileMimeType: String, galleryMediaType: String, metadata: [String: String]?, context: String, traceID: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func deleteMedia(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        fileDeleteCalls.append((fileID, false))
        completion(fileDeleteResponse)
    }

    func deleteAvatar(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        fileDeleteCalls.append((fileID, true))
        completion(fileDeleteResponse)
    }

    func deleteGallery(baseURL: URL, token: String, jid: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func getFiles(baseURL: URL, token: String, type: MimeIconTypes, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        fileCalls.append(.init(baseURL: baseURL, token: token, type: type, page: page))
        completion(fileResponse)
    }

    func getAvatars(baseURL: URL, token: String, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        avatarCalls.append((baseURL, token, page))
        completion(avatarResponse)
    }

    func getFilesToDelete(baseURL: URL, token: String, percent: Int, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        cleanupCalls.append(.init(baseURL: baseURL, token: token, percent: percent, page: page))
        if holdCleanupResponse {
            pendingCleanup = completion
        } else {
            completion(cleanupResponse)
        }
    }

    func deleteMediaFor(baseURL: URL, token: String, percent: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        deleteCalls.append(.init(baseURL: baseURL, token: token, percent: percent))
        deleteResponseHandler(completion)
    }

    func deleteMediaForAll(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func completeCleanupTwice(_ response: CloudStorageQuotaAPIResponse) {
        pendingCleanup?(response)
        pendingCleanup?(response)
    }
}
