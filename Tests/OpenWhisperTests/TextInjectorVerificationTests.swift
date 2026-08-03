import AppKit
import ApplicationServices
import XCTest
@testable import OpenWhisper

final class TextInjectorVerificationTests: XCTestCase {
    func testUnchangedAXSnapshotIsUnverifiedInsteadOfRetryable() {
        let range = CFRange(location: 4, length: 0)
        let context = makeContext(value: "test", range: range)
        let state = makeState(value: "test", range: range)

        let verification = TextInjector().verify(state: state, against: context)

        XCTAssertEqual(verification, .unverifiedNoObservedChange)
    }

    func testSelectionMovementStillVerifiesSameValuePaste() {
        let context = makeContext(
            value: "same",
            range: CFRange(location: 0, length: 4)
        )
        let state = makeState(
            value: "same",
            range: CFRange(location: 4, length: 0)
        )

        let verification = TextInjector().verify(state: state, against: context)

        XCTAssertEqual(verification, .verified)
    }

    func testUnreadableAXValueRemainsUnverified() {
        let context = makeContext(value: nil, range: nil)
        let state = makeState(value: nil, range: nil, error: .attributeUnsupported)

        let verification = TextInjector().verify(state: state, against: context)

        XCTAssertEqual(verification, .unverifiedUnreadable)
    }

    private func makeContext(value: String?, range: CFRange?) -> PasteContext {
        PasteContext(
            targetPID: nil,
            bundleIdentifier: nil,
            applicationName: nil,
            focusedElement: nil,
            valueAtCapture: value,
            selectedRangeAtCapture: range,
            selectedTextAtCapture: nil
        )
    }

    private func makeState(
        value: String?,
        range: CFRange?,
        error: AXError = .success
    ) -> AXTextAccess.TextState {
        AXTextAccess.TextState(
            value: value,
            selectedRange: range,
            valueError: error,
            selectedRangeError: error
        )
    }
}
