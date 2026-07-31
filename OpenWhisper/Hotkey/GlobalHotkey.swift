import Cocoa
import ApplicationServices
import CoreGraphics

final class GlobalHotkey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// What's currently driving the recording, if anything.
    /// - `idle`: nothing pressed.
    /// - `holding`: Fn/Globe held → release stops recording.
    /// - `handsFree`: Fn+Space toggled on → bare Space stops it.
    private enum Mode { case idle, holding, handsFree }
    private var mode: Mode = .idle

    private let fnKeyCode: UInt16 = 63
    private let spaceKeyCode: Int64 = 49
    private let zKeyCode: Int64 = 6

    private let onPress: () -> Void
    private let onRelease: () -> Void
    /// Fired the instant a valid Fn+Z swap gesture is recognized (Z tapped within
    /// `swapWindow` of the Fn keyDown while holding). This is the moment to silently
    /// cancel whatever recording started on this Fn-down — it involves no synthetic
    /// keystrokes, so it's safe to run immediately, Fn still physically down or not.
    private let onSwapRequest: () -> Void
    /// Fired once Fn is physically released *after* a swap was requested. The actual
    /// text replacement (backspace + paste) is deferred to this point so it never races
    /// a still-held Fn: posting synthetic Delete/Cmd+V while Fn is down risks the OS
    /// merging live Fn into the event (Fn+Delete is Forward Delete on macOS, not Backspace).
    private let onSwapCommit: () -> Void

    /// Timestamp of the most recent Fn keyDown (idle → holding transition); the swap
    /// gesture's 2s window is measured from here.
    private var fnPressTime: Date?
    private let swapWindow: TimeInterval = 2.0
    /// Whether AppState currently has a stored dictation pair to swap between. Mirrored
    /// here (rather than read live from AppState) so the CGEventTap callback — which must
    /// stay synchronous and cheap — can decide to swallow the Z key without touching
    /// MainActor-isolated state.
    private var swapAvailable = false
    /// Set true the instant a swap gesture is recognized; cleared when the deferred
    /// Fn-up commit fires. While true, any further Z keyDowns (autorepeat from the still-held
    /// key) are also swallowed rather than leaking into the focused app.
    private var pendingSwap = false

    init(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onSwapRequest: @escaping () -> Void,
        onSwapCommit: @escaping () -> Void
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onSwapRequest = onSwapRequest
        self.onSwapCommit = onSwapCommit
    }

    /// Called by AppState whenever it gains/loses a stored raw/cleaned dictation pair.
    func setSwapAvailable(_ available: Bool) {
        swapAvailable = available
    }

    /// Check and optionally prompt for Accessibility permissions.
    /// Uses a real functional test (AXUIElement) instead of trusting AXIsProcessTrusted(),
    /// which can return stale results with ad-hoc or self-signed binaries.
    static func checkAccessibility(prompt: Bool) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        if result == .success || result == .noValue {
            owLog("[GlobalHotkey] Accessibility real test: PASS (AXUIElement result=\(result.rawValue))")
            return true
        }

        if AXIsProcessTrusted() {
            owLog("[GlobalHotkey] AXIsProcessTrusted=true (but AXUIElement failed with \(result.rawValue))")
            return true
        }

        owLog("[GlobalHotkey] Accessibility NOT granted (AXUIElement=\(result.rawValue), AXIsProcessTrusted=false)")

        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    /// Register monitors for Fn/Globe hold-to-talk and Fn+Space hands-free toggle.
    func register() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        installSpaceEventTap()
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        removeSpaceEventTap()
    }

    // MARK: - Fn/Globe (hold-to-talk)

    private func handleFlagsChanged(_ event: NSEvent) {
        // flagsChanged fires for the Fn/Globe key itself with keyCode 63; guarding on the
        // keyCode (in addition to the .function flag) keeps arrow-key/function-flag noise out,
        // since other keys can also toggle modifier flags without being the Fn key press itself.
        guard event.keyCode == fnKeyCode else { return }
        let fnPressed = event.modifierFlags.contains(.function)

        switch mode {
        case .idle:
            if fnPressed {
                mode = .holding
                fnPressTime = Date()
                onPress()
            } else if pendingSwap {
                // Fn released after a recognized swap gesture — safe now to post the
                // synthetic backspace/paste keystrokes without a live Fn modifier around.
                pendingSwap = false
                onSwapCommit()
            }
        case .holding:
            if !fnPressed {
                mode = .idle
                onRelease()
            }
        case .handsFree:
            // Hands-free recording ignores Fn presses — only Space toggles it off.
            break
        }
    }

    // MARK: - Space key (hands-free toggle)

    /// Called from the CGEventTap callback on every Space keyDown.
    /// Returns `true` if the event should be swallowed (don't pass through to the focused app).
    fileprivate func handleSpaceKeyDown(flags: CGEventFlags) -> Bool {
        let fnDown = flags.contains(.maskSecondaryFn)
        // Ignore the chord if Cmd/Ctrl are also down — those are reserved for other shortcuts.
        let onlyFn = fnDown
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)

        switch mode {
        case .idle:
            if onlyFn {
                mode = .handsFree
                onPress()
                return true
            }
            return false
        case .holding:
            // User is already hold-to-talking; tapping Space locks it into hands-free.
            // Don't fire onPress/onRelease — the recording is already running.
            if onlyFn {
                mode = .handsFree
                return true
            }
            return false
        case .handsFree:
            mode = .idle
            onRelease()
            return true
        }
    }

    /// Called from the CGEventTap callback on Enter (keyCode 36 or 76) when in hands-free mode.
    fileprivate func handleEnterKeyDown() -> Bool {
        guard mode == .handsFree else { return false }
        mode = .idle
        onRelease()
        return true
    }

    // MARK: - Option + Z (output swap shortcut)

    /// Called from the CGEventTap callback on every 'Z' keyDown.
    /// Returns `true` if Option+Z is pressed and a swappable pair is available,
    /// swallowing the key event (so 'Ω' is NOT typed) and triggering the text swap.
    fileprivate func handleOptionZKeyDown(flags: CGEventFlags) -> Bool {
        guard swapAvailable else { return false }
        let optionDown = flags.contains(.maskAlternate)
        let noCmdOrCtrl = !flags.contains(.maskCommand) && !flags.contains(.maskControl)
        if optionDown && noCmdOrCtrl {
            onSwapCommit()
            return true
        }
        return false
    }

    private func installSpaceEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<GlobalHotkey>.fromOpaque(refcon).takeUnretainedValue()

            // macOS disables the tap if our callback is too slow or the system was overloaded.
            // Re-enable and pass the event through unchanged.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 49 {
                if me.handleSpaceKeyDown(flags: event.flags) {
                    return nil
                }
            } else if keyCode == 36 || keyCode == 76 {
                if me.handleEnterKeyDown() {
                    return nil
                }
            } else if keyCode == me.zKeyCode {
                if me.handleOptionZKeyDown(flags: event.flags) {
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            owLog("[GlobalHotkey] Failed to create CGEventTap for Space — hands-free mode disabled")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        owLog("[GlobalHotkey] CGEventTap installed (hands-free: 🌐Space to start, Space to stop)")
    }

    private func removeSpaceEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    deinit {
        unregister()
    }
}
