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

    func testBackgroundContextTracksInjectedUTF16Span() {
        let context = makeContext(
            value: "a😀b",
            range: CFRange(location: 1, length: 2)
        )

        let injected = context.contextForInjectedText("x")

        XCTAssertEqual(injected?.valueAtCapture, "axb")
        XCTAssertEqual(injected?.selectedRangeAtCapture?.location, 1)
        XCTAssertEqual(injected?.selectedRangeAtCapture?.length, 1)
        XCTAssertEqual(injected?.selectedTextAtCapture, "x")
    }

    func testBackgroundContextAdvancesReplacementSpan() {
        let context = makeContext(
            value: "before text after",
            range: CFRange(location: 7, length: 4)
        ).contextForInjectedText("text")!

        let replaced = context.contextAfterReplacingInjectedText(with: "clean")

        XCTAssertEqual(replaced?.valueAtCapture, "before clean after")
        XCTAssertEqual(replaced?.selectedRangeAtCapture?.location, 7)
        XCTAssertEqual(replaced?.selectedRangeAtCapture?.length, 5)
        XCTAssertEqual(replaced?.selectedTextAtCapture, "clean")
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
