import Cocoa
import ApplicationServices
import CoreGraphics
import QuartzCore

final class GlobalHotkey {
    static var lastFnPressUptime: CFTimeInterval = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// What's currently driving the recording, if anything.
    /// - `idle`: nothing pressed.
    /// - `holding`: Fn/Globe held → release stops recording.
    /// - `handsFree`: Fn+Space toggled on → bare Space stops it.
    private enum Mode { case idle, holding, handsFree }
    private var mode: Mode = .idle {
        didSet {
            guard (oldValue == .handsFree) != (mode == .handsFree) else { return }
            onHandsFreeChange?(mode == .handsFree)
        }
    }
    /// Fired when hands-free recording turns on/off, so the FlowBar can show its stop button.
    var onHandsFreeChange: ((Bool) -> Void)?
    var isIdle: Bool { mode == .idle }
    /// How the current (or last) recording was started; kept after it ends.
    private(set) var trigger: RecordingTrigger = .fnHold
    /// Fired on a Vocal Shortcuts recognition: start a voice session (hands-free recording that
    /// ends itself on silence).
    var onVoiceSessionRequest: (() -> Void)?

    /// NX_SYSDEFINED — has no case in Swift's CGEventType.
    fileprivate static let systemDefinedEventType: UInt32 = 14
    private let fnKeyCode: UInt16 = 63
    private let spaceKeyCode: Int64 = 49
    private let zKeyCode: Int64 = 6
    /// TEMPORARY diagnostic shortcut (Option+Shift+D) — triggers AXProbe. Remove along with
    /// AXProbe.swift once the AX-readability measurement is done.
    private let dKeyCode: Int64 = 2
    /// Manual correction review shortcut: Option+Shift+C.
    private let cKeyCode: Int64 = 8

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
    /// TEMPORARY: fired on Option+Shift+D to run the AX-readability diagnostic probe.
    private let onDiagnosticProbe: () -> Void
    /// Fired on Option+Shift+C to compare the active pasted text with its current field text.
    private let onCorrectionReview: () -> Void

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
        onSwapCommit: @escaping () -> Void,
        onDiagnosticProbe: @escaping () -> Void = {},
        onCorrectionReview: @escaping () -> Void = {}
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onSwapRequest = onSwapRequest
        self.onSwapCommit = onSwapCommit
        self.onDiagnosticProbe = onDiagnosticProbe
        self.onCorrectionReview = onCorrectionReview
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

    /// Register the global event tap used by Fn/Globe hold-to-talk and the key-down shortcuts.
    /// Keeping both event types in the same tap is important: macOS can deliver the Fn key's
    /// flagsChanged event differently from ordinary modifier keys, and NSEvent monitors do not
    /// reliably see a bare Fn press in every focused application.
    func register() {
        installSpaceEventTap()
    }

    func unregister() {
        removeSpaceEventTap()
    }

    /// Ensures the global key-down event tap is installed. The tap is also installed during
    /// register(), but keeping this call makes the recording path resilient if macOS or another
    /// component temporarily removes the tap.
    ///
    /// This is idempotent so AppState may call it alongside the automatic Fn/Globe path
    /// without creating a second tap.
    func beginActiveKeyDownCapture() {
        installSpaceEventTap()
    }

    /// Kept as a compatibility hook for recording paths. The tap must remain installed after
    /// dictation so Option+Z and Option+Shift+C continue to work while editing the pasted text.
    func endActiveKeyDownCapture() {
        // Intentionally keep the tap alive. Space/Enter remain mode-gated in their handlers.
    }

    // MARK: - Fn/Globe (hold-to-talk)

    private func handleFunctionKeyChanged(isPressed: Bool) {
        switch mode {
        case .idle:
            if isPressed {
                let now = CACurrentMediaTime()
                GlobalHotkey.lastFnPressUptime = now
                owLog("[Perf] [FnKeyDown] Fn key pressed down at t=\(String(format: "%.3f", now))")
                trigger = .fnHold
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
            if !isPressed {
                mode = .idle
                onRelease()
            }
        case .handsFree:
            // Hands-free recording ignores Fn presses — only Space toggles it off.
            break
        }
    }

    // MARK: - Space key (hands-free toggle)

    /// Applies the same mode transition used by Fn+Space. Keeping this in one place makes
    /// alternate hands-free shortcuts behave identically without changing the Fn+Space path.
    ///
    /// Returns `true` when the triggering key event should be swallowed.
    private func toggleHandsFreeRecording(_ trigger: RecordingTrigger) -> Bool {
        switch mode {
        case .idle:
            self.trigger = trigger
            mode = .handsFree
            onPress()
            return true
        case .holding:
            // User is already hold-to-talking; lock the active recording into hands-free.
            self.trigger = trigger
            mode = .handsFree
            return true
        case .handsFree:
            mode = .idle
            onRelease()
            endActiveKeyDownCapture()
            return true
        }
    }

    // MARK: - External triggers (openwhisper:// URL — Vocal Shortcuts, Shortcuts, Voice Control)

    /// Routed through the same state machine as ⌘⌥⌃D so a URL-started recording can still be
    /// stopped with Enter / Fn+Space / ⌘⌥⌃D, and vice versa. A live Fn hold is never hijacked.
    func externalStartHandsFree(trigger: RecordingTrigger = .external) {
        guard mode == .idle else { return }
        _ = toggleHandsFreeRecording(trigger)
    }

    func externalStopHandsFree() {
        guard mode == .handsFree else { return }
        _ = toggleHandsFreeRecording(.external)
    }

    func externalToggleHandsFree() {
        guard mode != .holding else { return }
        _ = toggleHandsFreeRecording(.external)
    }

    /// Leaves hands-free mode without firing `onRelease`; the caller stops or discards the
    /// recording itself.
    func externalCancelHandsFree() {
        guard mode == .handsFree else { return }
        mode = .idle
    }

    /// Called from the CGEventTap callback on every Space keyDown.
    /// Returns `true` if the event should be swallowed (don't pass through to the focused app).
    fileprivate func handleSpaceKeyDown(flags: CGEventFlags) -> Bool {
        // A bare Space ends a hands-free recording (there is no key being held to release).
        if mode == .handsFree
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate) {
            return toggleHandsFreeRecording(.fnSpace)
        }

        let fnDown = flags.contains(.maskSecondaryFn)
        // Ignore the chord if Cmd/Ctrl are also down — those are reserved for other shortcuts.
        let onlyFn = fnDown
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)

        guard onlyFn else { return false }
        return toggleHandsFreeRecording(.fnSpace)
    }

    // MARK: - Command + Option + Control + D (hands-free toggle)

    /// Makes ⌘⌥⌃D behave exactly like Fn+Space while keeping Fn+Space available.
    /// Autorepeat is swallowed but does not toggle the recording a second time.
    fileprivate func handleCommandOptionControlDKeyDown(
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        let hasRequiredModifiers = flags.contains(.maskCommand)
            && flags.contains(.maskAlternate)
            && flags.contains(.maskControl)
            && !flags.contains(.maskShift)
        guard hasRequiredModifiers else { return false }
        if !isRepeat {
            return toggleHandsFreeRecording(.keyboardShortcut)
        }
        return true
    }

    /// Called from the CGEventTap callback on Enter (keyCode 36 or 76) when in hands-free mode.
    fileprivate func handleEnterKeyDown() -> Bool {
        guard mode == .handsFree else { return false }
        mode = .idle
        onRelease()
        endActiveKeyDownCapture()
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

    // MARK: - Option + Shift + D (TEMPORARY: AX-readability diagnostic probe)

    /// Called from the CGEventTap callback on every 'D' keyDown.
    /// Returns `true` if Option+Shift+D is pressed, swallowing the key event. The probe itself
    /// only fires once per physical keypress — `isRepeat` (autorepeat from holding the chord)
    /// still swallows the key so 'ﬂ'/'∂' etc. never leaks into the focused app, but skips
    /// re-running the probe (and its AX calls) on every repeat tick.
    fileprivate func handleDiagnosticProbeKeyDown(flags: CGEventFlags, isRepeat: Bool) -> Bool {
        let optionDown = flags.contains(.maskAlternate)
        let shiftDown = flags.contains(.maskShift)
        let noCmdOrCtrl = !flags.contains(.maskCommand) && !flags.contains(.maskControl)
        guard optionDown && shiftDown && noCmdOrCtrl else { return false }
        if !isRepeat {
            onDiagnosticProbe()
        }
        return true
    }

    // MARK: - Vocal Shortcuts recognition (undocumented system event)

    /// When Vocal Shortcuts recognizes *any* of the user's phrases, the system posts an
    /// NX_SYSDEFINED event with subtype 211 / data1 98 (measured on macOS 27.2 beta; it is what
    /// universalaccessd logs as "Event Type: 14 Subtype: 211"). Catching it here skips the
    /// Shortcuts hop, which on this build recognizes the phrase but never runs the shortcut.
    /// Undocumented: a macOS update may change or drop it — openwhisper://start remains.
    private static let vocalShortcutSubtype: Int16 = 211
    private static let vocalShortcutData1 = 98
    private var lastVocalShortcutTrigger = Date.distantPast

    fileprivate func handleSystemDefinedEvent(_ event: CGEvent) {
        guard let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == Self.vocalShortcutSubtype,
              ns.data1 == Self.vocalShortcutData1 else { return }
        // One recognition could conceivably arrive twice; never start two sessions from it.
        let now = Date()
        guard now.timeIntervalSince(lastVocalShortcutTrigger) > 1.0 else { return }
        lastVocalShortcutTrigger = now
        owLog("[GlobalHotkey] Vocal Shortcuts phrase recognized (sysdefined 211/98)")
        onVoiceSessionRequest?()
    }

    // MARK: - Option + Shift + C (manual correction review)

    /// Called from the CGEventTap callback on every 'C' keyDown. The event is swallowed so
    /// the shortcut cannot leak a character into the focused app; autorepeat is swallowed too
    /// but only the first physical press starts a review.
    fileprivate func handleCorrectionReviewKeyDown(flags: CGEventFlags, isRepeat: Bool) -> Bool {
        let optionDown = flags.contains(.maskAlternate)
        let shiftDown = flags.contains(.maskShift)
        let noCmdOrCtrl = !flags.contains(.maskCommand) && !flags.contains(.maskControl)
        guard optionDown && shiftDown && noCmdOrCtrl else { return false }
        if !isRepeat {
            onCorrectionReview()
        }
        return true
    }

    private func installSpaceEventTap() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << GlobalHotkey.systemDefinedEventType)
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

            if type.rawValue == GlobalHotkey.systemDefinedEventType {
                me.handleSystemDefinedEvent(event)
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .flagsChanged {
                // Fn/Globe is key code 63. Its press/release state is represented by
                // maskSecondaryFn on the CGEvent, which is also what the working Fn+Space
                // path uses. Handle it in this tap so a bare Fn press starts recording even
                // when the focused app does not deliver a modifier event to NSEvent monitors.
                if keyCode == Int64(me.fnKeyCode) {
                    me.handleFunctionKeyChanged(isPressed: event.flags.contains(.maskSecondaryFn))
                }
                return Unmanaged.passUnretained(event)
            }

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
            } else if keyCode == me.dKeyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if me.handleCommandOptionControlDKeyDown(flags: event.flags, isRepeat: isRepeat)
                    || me.handleDiagnosticProbeKeyDown(flags: event.flags, isRepeat: isRepeat) {
                    return nil
                }
            } else if keyCode == me.cKeyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if me.handleCorrectionReviewKeyDown(flags: event.flags, isRepeat: isRepeat) {
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
            owLog("[GlobalHotkey] Failed to create CGEventTap — global shortcuts disabled")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        owLog("[GlobalHotkey] CGEventTap installed (hands-free: 🌐Space/⌘⌥⌃D; voice: Vocal Shortcuts; swap: ⌥Z; review: ⌥⇧C)")
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
