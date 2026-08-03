import AppKit
import SwiftUI

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
    }

    /// Show the flow bar. Idempotent — calling it again while already shown (e.g. the
    /// recording → transcribing transition) is a no-op so it doesn't refade in and flicker.
    func show() {
        owLog("[FlowBar] show() called, panel exists: \(panel != nil)")
        if panel == nil {
            createPanel()
        }
        centerPanelOnScreen()
        if !isShown {
            isShown = true
            owLog("[FlowBar] panel frame: \(panel?.frame ?? .zero)")
            panel?.alphaValue = 0
            panel?.orderFront(nil)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel?.animator().alphaValue = 1
            }
        }
        recenterAfterContentLayout()
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
