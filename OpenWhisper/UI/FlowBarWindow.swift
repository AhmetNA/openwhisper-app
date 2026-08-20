import AppKit
import SwiftUI
import QuartzCore

/// `NSView.acceptsFirstMouse(for:)` defaults to `false`, which means the very first click on a
/// non-key window is, by default, consumed just to bring the window forward/key and never
/// reaches the view underneath -- the click would silently do nothing. Overriding it to `true`
/// on the panel's content-hosting view lets a tap on "Bu benim sesimdi" (see
/// `FlowBarView.rejectedRecordingOfferContent`) fire on the first click. Combined with
/// `.nonactivatingPanel` (set in `createPanel`), this still never activates the owning app or
/// steals keyboard focus from whatever the user is dictating into.
private final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class FlowBarController {
    private var panel: NSPanel?
    private weak var appState: AppState?
    /// Tracks our own show/hide intent (independent of the panel's animated alpha), so a
    /// stale `hide()` completion can't `orderOut` a bar that's since been re-shown — e.g. a
    /// dictation ending and a new one starting in quick succession.
    private var isShown = false
    /// SwiftUI updates fitting size on the next main-loop turn after a recording-state change.
    /// A second, coalesced measurement keeps wider content centered.
    private var recenterScheduled = false

    init(appState: AppState) {
        self.appState = appState
        // Pre-create panel at app startup for zero-latency hotkey display
        createPanel()
    }

    /// Show the flow bar. Idempotent — calling it again while already shown (e.g. the
    /// recording → transcribing transition) is a no-op so it doesn't refade in and flicker.
    func show() {
        let tShowStart = CACurrentMediaTime()
        let elapsedFromFn = (tShowStart - GlobalHotkey.lastFnPressUptime) * 1000
        owLog("[Perf] [FlowBarShowStart] FlowBar show() called (+\(String(format: "%.2f", elapsedFromFn))ms from Fn press), panel exists: \(panel != nil)")

        if panel == nil {
            createPanel()
            centerPanelOnScreen()
        }
        if !isShown {
            isShown = true
            owLog("[FlowBar] panel frame: \(panel?.frame ?? .zero)")
            panel?.alphaValue = 1
            // The menu-bar app is normally inactive while the user dictates into another app.
            // orderFrontRegardless keeps the nonactivating overlay visible without stealing
            // keyboard focus from that target app, including while it owns a fullscreen Space.
            panel?.orderFrontRegardless()
        }
        recenterAfterContentLayout()

        let tShowEnd = CACurrentMediaTime()
        let totalElapsed = (tShowEnd - GlobalHotkey.lastFnPressUptime) * 1000
        let showFnDuration = (tShowEnd - tShowStart) * 1000
        owLog("[Perf] [FlowBarShowEnd] FlowBar show() completed: execution duration = \(String(format: "%.2f", showFnDuration))ms (+\(String(format: "%.2f", totalElapsed))ms after Fn press)")
    }

    /// Hide the flow bar. Idempotent, and safe to race with a subsequent `show()` — the
    /// completion handler only orders the window out if we're still meant to be hidden.
    func hide() {
        guard isShown else { return }
        isShown = false
        let panelRef = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.isShown {
                    panelRef?.orderOut(nil)
                }
            }
        })
    }

    /// Center panel horizontally on the main screen based on its exact content width
    private func centerPanelOnScreen() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        if let hostingView = panel.contentView {
            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize
            if fittingSize.width > 0 && fittingSize.height > 0 {
                panel.setContentSize(fittingSize)
            }
        }
        let screenFrame = screen.visibleFrame
        let panelWidth = panel.frame.width
        let x = round(screenFrame.midX - (panelWidth / 2.0))
        let y = screenFrame.minY + 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        owLog("[FlowBar] Centered at (\(x), \(y)) with width \(panelWidth) on screen \(screenFrame)")
    }

    /// Re-measure after Observation/SwiftUI has rendered the new state (such as the
    /// wider "transcribing" label) rather than reusing the waveform's former width.
    private func recenterAfterContentLayout() {
        guard !recenterScheduled else { return }
        recenterScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recenterScheduled = false
            guard self.isShown else { return }
            self.centerPanelOnScreen()
            let tLayout = CACurrentMediaTime()
            let layoutElapsed = (tLayout - GlobalHotkey.lastFnPressUptime) * 1000
            owLog("[Perf] [FlowBarLayoutDone] FlowBar recenter/layout completed (+\(String(format: "%.2f", layoutElapsed))ms after Fn press)")
        }
    }

    /// Show a brief "done" flash, then shrink back to idle pill
    func flashDone() {
        // Flow bar stays visible — it just animates back to idle state via SwiftUI
        // (recordingState goes back to .idle, FlowBarView reacts)
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar  // Above floating windows
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // These are two independent axes in NSWindowCollectionBehavior, not alternatives:
        // `.canJoinAllApplications` is the app-grouping axis (at most one of Primary /
        // Auxiliary / CanJoinAllApplications), while `.fullScreenAuxiliary` is the fullscreen
        // axis (at most one of FullScreenPrimary / FullScreenAuxiliary / FullScreenNone).
        // Setting only the former left the fullscreen axis at its default, which is why the
        // flow bar was invisible while another app owned a fullscreen Space.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary
        ]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        if let appState {
            let flowBarView = FlowBarView()
                .environment(appState)
                .fixedSize()
            let hostingView = ClickableHostingView(rootView: flowBarView)
            panel.contentView = hostingView
        }

        self.panel = panel
        centerPanelOnScreen()
    }
}
