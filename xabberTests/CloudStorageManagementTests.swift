import XCTest
@testable import xabber

final class CloudStorageManagementTests: XCTestCase {
    func testCategoryLayoutMatchesAttachmentTypeScreenMetrics() {
        XCTAssertEqual(CloudStorageCategoryLayoutPolicy.spacing, InfoScreenFooterView.cellSpacing)
        XCTAssertEqual(CloudStorageCategoryLayoutPolicy.numberOfColumns, InfoScreenFooterView.numberOfCells)
        XCTAssertEqual(
            CloudStorageCategoryLayoutPolicy.sectionInsets,
            UIEdgeInsets(
                top: 12,
                left: InfoScreenFooterView.cellSpacing,
                bottom: 15,
                right: InfoScreenFooterView.cellSpacing
            )
        )
        XCTAssertEqual(
            CloudStorageCategoryLayoutPolicy.gridItemWidth(containerWidth: 390),
            119.33,
            accuracy: 0.001
        )
        XCTAssertEqual(CloudStorageCategoryLayoutPolicy.listItemWidth(containerWidth: 390), 374)
        XCTAssertEqual(CloudStorageCategoryLayoutPolicy.listItemHeight, 60)
    }

    func testCleanupOptionsAreExactlyRequestedTargets() {
        XCTAssertEqual(CloudStorageCleanupPolicy.supportedPercents, [25, 50, 75])
        XCTAssertTrue(CloudStorageCleanupPolicy.isEnabled(percent: 25, currentFreePercent: 24))
        XCTAssertFalse(CloudStorageCleanupPolicy.isEnabled(percent: 25, currentFreePercent: 25))
        XCTAssertTrue(CloudStorageCleanupPolicy.isEnabled(percent: 75, currentFreePercent: 74))
        XCTAssertFalse(CloudStorageCleanupPolicy.isEnabled(percent: 75, currentFreePercent: 75))
        XCTAssertTrue(CloudStorageCleanupPolicy.hasEnabledTarget(currentFreePercent: 74))
        XCTAssertFalse(CloudStorageCleanupPolicy.hasEnabledTarget(currentFreePercent: 75))
    }

    func testFreePercentageUsesRawQuotaAndClampsInvalidValues() {
        XCTAssertEqual(CloudStorageCleanupPolicy.freePercentage(quotaBytes: 1_000, usedBytes: 750), 25)
        XCTAssertEqual(CloudStorageCleanupPolicy.freePercentage(quotaBytes: 1_000, usedBytes: 1_500), 0)
        XCTAssertEqual(CloudStorageCleanupPolicy.freePercentage(quotaBytes: 1_000, usedBytes: -1), 100)
        XCTAssertEqual(CloudStorageCleanupPolicy.freePercentage(quotaBytes: 0, usedBytes: 100), 0)
        XCTAssertEqual(CloudStorageCleanupPolicy.freePercentage(quotaBytes: -1, usedBytes: 100), 0)
        XCTAssertEqual(CloudStorageCleanupPolicy.freePercentage(quotaBytes: Int.max, usedBytes: 1), 99)
    }

    func testQuotaRowsUseRawCountsAndCorrectVoiceCategory() {
        let item = AccountQuotaStorageItem()
        item.imagesBytes = 1_024
        item.imagesCount = 2
        item.videosBytes = 2_048
        item.videosCount = 3
        item.filesBytes = 3_072
        item.filesCount = 4
        item.audioBytes = 99_999
        item.audioCount = 99
        item.voicesBytes = 4_096
        item.voicesCount = 5
        item.avatarsBytes = 5_120
        item.avatarsCount = 6

        let rows = CloudStorageQuotaCategoryPresentation.rows(from: item)

        XCTAssertEqual(rows["images"], .init(count: 2, bytes: 1_024))
        XCTAssertEqual(rows["videos"], .init(count: 3, bytes: 2_048))
        XCTAssertEqual(rows["files"], .init(count: 4, bytes: 3_072))
        XCTAssertEqual(rows["audio"], .init(count: 5, bytes: 4_096))
        XCTAssertEqual(rows["avatars"], .init(count: 6, bytes: 5_120))
        XCTAssertEqual(rows["audio"]?.detailText, "5 \u{00b7} 4 KiB")
    }

    func testPagedLoaderRequestsPagesSequentiallyAndRemovesDuplicateIDs() {
        let loader = CloudStoragePagedLoader()
        var requestedPages: [Int] = []
        var result: Result<[NSDictionary], CloudStorageListLoadError>?

        loader.loadAll(fetchPage: { page, completion in
            requestedPages.append(page)
            switch page {
            case 1:
                completion(.success(.init(
                    items: [["id": 1], ["id": 2]],
                    totalObjects: 4,
                    objectsPerPage: 2,
                    totalPages: 3,
                    page: page
                )))
            case 2:
                completion(.success(.init(
                    items: [["id": 2], ["id": 3]],
                    totalObjects: 4,
                    objectsPerPage: 2,
                    totalPages: 3,
                    page: page
                )))
            default:
                completion(.success(.init(
                    items: [["id": 4]],
                    totalObjects: 4,
                    objectsPerPage: 2,
                    totalPages: 3,
                    page: page
                )))
            }
        }, completion: { result = $0 })

        XCTAssertEqual(requestedPages, [1, 2, 3])
        XCTAssertEqual(try? result?.get().compactMap { $0["id"] as? Int }, [1, 2, 3, 4])
    }

    func testPagedLoaderCompletesForEmptyStorage() {
        let loader = CloudStoragePagedLoader()
        var result: Result<[NSDictionary], CloudStorageListLoadError>?

        loader.loadAll(fetchPage: { page, completion in
            completion(.success(.init(
                items: [],
                totalObjects: 0,
                objectsPerPage: 50,
                totalPages: 0,
                page: page
            )))
        }, completion: { result = $0 })

        XCTAssertEqual(try? result?.get().count, 0)
    }

    func testPagedLoaderStopsAtFirstFailureAndCompletesOnce() {
        let loader = CloudStoragePagedLoader()
        var requestedPages: [Int] = []
        var completions = 0
        var receivedError: CloudStorageListLoadError?

        loader.loadAll(fetchPage: { page, completion in
            requestedPages.append(page)
            if page == 1 {
                completion(.success(.init(
                    items: [["id": 1]],
                    totalObjects: 3,
                    objectsPerPage: 1,
                    totalPages: 3,
                    page: page
                )))
            } else {
                completion(.failure(.server(statusCode: 500)))
            }
        }, completion: { result in
            completions += 1
            if case .failure(let error) = result {
                receivedError = error
            }
        })

        XCTAssertEqual(requestedPages, [1, 2])
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(receivedError, .server(statusCode: 500))
    }

    func testItemMapperHandlesNSNumberSizeAndClassifiesContextBeforeMime() throws {
        let payload: NSDictionary = [
            "id": NSNumber(value: 42),
            "file": "https://gallery.example/avatar.jpg",
            "name": "avatar.jpg",
            "size": NSNumber(value: 2_048),
            "media_type": "image/jpeg",
            "context": "avatar",
            "created_at": "2026-08-13T10:20:30.000+0000"
        ]

        let item = try XCTUnwrap(CloudStorageItemPresentation.make(from: payload))

        XCTAssertEqual(item.fileId, 42)
        XCTAssertEqual(item.kind, .avatar)
        XCTAssertEqual(item.size, "2 KiB")
    }

    func testItemMapperUsesSafePlaceholdersForOptionalFileFields() throws {
        let payload: NSDictionary = [
            "id": "7",
            "file": "https://gallery.example/file",
            "media_type": "application/octet-stream"
        ]

        let item = try XCTUnwrap(CloudStorageItemPresentation.make(from: payload, preferredType: .file))

        XCTAssertEqual(item.fileId, 7)
        XCTAssertEqual(item.fileName, "File")
        XCTAssertEqual(item.size, "0 KiB")
    }

    func testItemGroupingKeepsEveryCloudStorageCategory() {
        func payload(
            id: Int,
            path: String,
            mediaType: String,
            context: String? = nil
        ) -> NSDictionary {
            var value: [String: Any] = [
                "id": id,
                "file": "https://gallery.example/\(path)",
                "media_type": mediaType,
                "created_at": "2026-08-13T10:20:30Z"
            ]
            value["context"] = context
            return value as NSDictionary
        }

        let groups = CloudStorageItemPresentation.grouped([
            payload(id: 1, path: "image.jpg", mediaType: "image/jpeg"),
            payload(id: 2, path: "video.mp4", mediaType: "video/mp4"),
            payload(id: 3, path: "document.pdf", mediaType: "application/pdf"),
            payload(id: 4, path: "voice.ogg", mediaType: "audio/ogg", context: "voice"),
            payload(id: 5, path: "avatar.jpg", mediaType: "image/jpeg", context: "avatar")
        ])

        XCTAssertEqual(groups.compactMap { $0.first?.kind }, [
            .image, .video, .file, .voice, .avatar
        ])
    }
}
