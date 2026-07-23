import UIKit
import XCTest
@testable import RestaurantLog

@MainActor
final class CloudSharingLifecycleTests: XCTestCase {
    func testApplicationDelegateConfiguresCloudSharingSceneDelegate() {
        let configuration = AppDelegate.sceneConfiguration(for: .windowApplication)

        XCTAssertTrue(configuration.delegateClass === SceneDelegate.self)
    }

    func testSceneDelegateHandlesWarmAndColdShareDelivery() {
        let delegate = SceneDelegate()

        XCTAssertTrue(delegate.responds(to: #selector(UIWindowSceneDelegate.windowScene(_:userDidAcceptCloudKitShareWith:))))
        XCTAssertTrue(delegate.responds(to: #selector(UISceneDelegate.scene(_:willConnectTo:options:))))
    }
}
