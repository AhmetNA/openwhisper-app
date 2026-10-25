import XCTest
import AVFoundation
import CoreBluetooth
import EventKit
@testable import OpenWhisper

@MainActor
final class PermissionsManagerTests: XCTestCase {
    func testCalendarWriteOnlyCanBeUpgradedInsteadOfBeingTreatedAsDenied() {
        XCTAssertEqual(PermissionsManager.status(EKAuthorizationStatus.writeOnly), .writeOnly)
        XCTAssertEqual(PermissionsManager.status(EKAuthorizationStatus.fullAccess), .granted)
    }

    func testSystemRestrictionsAreNotPresentedAsUserDenials() {
        XCTAssertEqual(PermissionsManager.status(AVAuthorizationStatus.restricted), .restricted)
        XCTAssertEqual(PermissionsManager.status(EKAuthorizationStatus.restricted), .restricted)
        XCTAssertEqual(PermissionsManager.status(CBManagerAuthorization.restricted), .restricted)
    }

    func testNeverRequestedAndDeniedPermissionsStayDistinct() {
        XCTAssertEqual(PermissionsManager.status(AVAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionsManager.status(AVAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionsManager.status(EKAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionsManager.status(CBManagerAuthorization.denied), .denied)
    }
}
