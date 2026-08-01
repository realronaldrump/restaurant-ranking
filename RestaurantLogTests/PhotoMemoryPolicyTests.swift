import XCTest
@testable import RestaurantLog

final class PhotoMemoryPolicyTests: XCTestCase {
    func testConcurrencyIsClampedToTheSupportedRange() {
        XCTAssertEqual(PhotoMemoryPolicy.clampedConcurrency(-4), 1)
        XCTAssertEqual(PhotoMemoryPolicy.clampedConcurrency(2), 2)
        XCTAssertEqual(
            PhotoMemoryPolicy.clampedConcurrency(Int.max),
            PhotoMemoryPolicy.maximumConcurrentProcessing
        )
    }

    func testSourceFileLimitRejectsNegativeAndOversizedInputs() {
        XCTAssertFalse(PhotoMemoryPolicy.acceptsSourceFile(byteCount: -1))
        XCTAssertTrue(
            PhotoMemoryPolicy.acceptsSourceFile(
                byteCount: Int64(PhotoMemoryPolicy.maximumSourceFileBytes)
            )
        )
        XCTAssertFalse(
            PhotoMemoryPolicy.acceptsSourceFile(
                byteCount: Int64(PhotoMemoryPolicy.maximumSourceFileBytes) + 1
            )
        )
    }

    func testAssetDimensionsArePreflightedWithoutOverflow() {
        XCTAssertTrue(PhotoMemoryPolicy.acceptsAsset(pixelWidth: 8_064, pixelHeight: 6_048))
        XCTAssertFalse(PhotoMemoryPolicy.acceptsAsset(pixelWidth: Int.max, pixelHeight: 2))
        XCTAssertFalse(PhotoMemoryPolicy.acceptsAsset(pixelWidth: 0, pixelHeight: 4_032))
    }

    func testPreparedPhotoBudgetBoundsIndividualAndAggregateRetention() {
        XCTAssertTrue(
            PhotoMemoryPolicy.canRetainPreparedPhoto(
                currentBytes: PhotoMemoryPolicy.maximumPreparedPhotoBytes,
                fullBytes: 0,
                thumbnailBytes: 0
            )
        )
        XCTAssertFalse(
            PhotoMemoryPolicy.canRetainPreparedPhoto(
                currentBytes: 0,
                fullBytes: PhotoMemoryPolicy.maximumPreparedPhotoBytes + 1,
                thumbnailBytes: 0
            )
        )
        XCTAssertFalse(
            PhotoMemoryPolicy.canRetainPreparedPhoto(
                currentBytes: PhotoMemoryPolicy.maximumPreparedOutputBytes,
                fullBytes: 1,
                thumbnailBytes: 0
            )
        )
    }

    func testPreparedPhotoBudgetRejectsIntegerOverflow() {
        XCTAssertFalse(
            PhotoMemoryPolicy.canRetainPreparedPhoto(
                currentBytes: Int.max,
                fullBytes: Int.max,
                thumbnailBytes: Int.max
            )
        )
    }
}
