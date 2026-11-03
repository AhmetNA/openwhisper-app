import AppKit
import QuartzCore

/// What is on the screen mode overlay now, and what its numbers stand for.
enum ScreenOverlayState {
    case numbers(app: NSRunningApplication, targets: [ScreenElement])
    case grid(CGRect)
}

/// How a pointer step ended, for the router: `step` keeps the mic open as after any other step.
enum PointerOutcome {
    case notHandled, step, noStep
}

extension AppState {
    /// Runs the step. Says where the time went like every screen step (`logScreenStep`).
    func runPointerCommand(_ command: PointerCommand, session: RecordingTranscriptionSession, app: NSRunningApplication) async -> PointerOutcome {
        let inMode = screenModeActive && session.followsCommand
        let started = CACurrentMediaTime()
        func finish(_ outcome: String, message: String?, changesScreen: Bool = true) -> PointerOutcome {
            screenOverlayHoldsNumbers = !changesScreen
            session.latency.finishDecision(route: "ekran modu, fare")
            logScreenStep(session, outcome, startedAt: started, [("fare adımı", CACurrentMediaTime() - started)])
            if let message { showFlowBarMessage(message, durationMs: 1500) }
            lastCommandUndo = []
            noteScreenModeAction()
            return .step
        }
        func miss(_ message: String) -> PointerOutcome {
            session.latency.finishDecision(route: "ekran modu, fare, olmadı")
            logScreenStep(session, "olmadı", startedAt: started, [("fare adımı", CACurrentMediaTime() - started)])
            showFlowBarMessage(message, durationMs: 3000)
            // The mic stays open: a wrong number is no reason to start over.
            return screenModeActive ? .step : .noStep
        }

        switch command {
        case .open:
            owLog("[Pointer] Screen mode opened by voice")
            return finish("açıldı", message: L("Ekran modu açık", "Screen mode on"), changesScreen: false)

        case .showNumbers:
            guard showScreenNumbers(in: app) else { return miss(L("Numaralanacak bir şey yok, ızgarayı deneyin", "Nothing to number, try the grid")) }
            return finish("numaralar gösterildi", message: nil, changesScreen: false)

        case .showGrid(let fullScreen):
            guard let rect = gridArea(of: app, fullScreen: fullScreen) else { return miss(L("Izgara açılamadı", "Couldn't show the grid")) }
            showScreenGrid(rect)
            return finish("ızgara gösterildi", message: nil)

        case .hideOverlay:
            guard screenOverlayState != nil else { return .notHandled }
            hideScreenOverlay()
            return finish("gizlendi", message: nil)

        case .number(let number, let action):
            switch screenOverlayState {
            case .numbers(let owner, let targets):
                guard owner.processIdentifier == app.processIdentifier else { return miss(L("Ekran değişti", "The screen changed")) }
                guard targets.indices.contains(number - 1) else { return miss(L("\(number) numara yok", "There's no number \(number)")) }
                let pressed = act(action ?? .press, on: targets[number - 1])
                return pressed ? finish("\(number) numara", message: "\(number) ✓", changesScreen: action != .hover) : miss(L("Basılamadı", "Couldn't press it"))
            case .grid(let rect):
                guard let cell = ScreenPointer.gridCell(number, in: rect) else { return miss(L("\(number) numara yok", "There's no number \(number)")) }
                if action == nil, !ScreenPointer.isLastGridLevel(cell) {
                    showScreenGrid(cell)
                    return finish("ızgara daraldı", message: nil)
                }
                hideScreenOverlay()
                perform(action ?? .press, at: CGPoint(x: cell.midX, y: cell.midY))
                return finish("ızgaradan", message: "✓")
            case nil:
                // A stray number on the open mic means nothing without numbers to choose from.
                guard action != nil, inMode else { return .notHandled }
                return miss(L("Önce numaraları gösterin", "Show the numbers first"))
            }

        case .name(let name, let action):
            guard let point = await locate(name, in: app) else {
                // Outside the mode such a sentence may be meant for Jarvis: it goes on as usual.
                guard inMode else { return .notHandled }
                return miss(L("Ekranda “\(name)” bulamadım", "I couldn't find “\(name)” on screen"))
            }
            perform(action, at: point)
            return finish("adıyla", message: "“\(name)” ✓", changesScreen: action != .hover)

        case .here(let action):
            var point = ScreenPointer.location
            if case .grid(let rect) = screenOverlayState {
                point = CGPoint(x: rect.midX, y: rect.midY)
                hideScreenOverlay()
            }
            perform(action, at: point)
            return finish("imlecin yerinde", message: "✓", changesScreen: action != .hover)

        case .dragNumbers(let from, let to):
            guard let start = overlayPoint(from), let end = overlayPoint(to) else { return miss(L("Bu numaralar yok", "Those numbers don't exist")) }
            await ScreenPointer.drag(from: start, to: end)
            if case .grid = screenOverlayState { hideScreenOverlay() }
            return finish("sürüklendi", message: "\(from) → \(to) ✓")

        case .dragNames(let from, let to):
            guard let start = await locate(from, in: app), let end = await locate(to, in: app) else {
                return miss(L("Sürüklenecek yerleri bulamadım", "I couldn't find both places"))
            }
            await ScreenPointer.drag(from: start, to: end)
            return finish("adıyla sürüklendi", message: "✓")
        }
    }

    /// A press goes through the accessibility action, which needs no pointer; the rest is the mouse.
    private func act(_ action: PointerAction, on target: ScreenElement) -> Bool {
        if action == .press {
            let pressed = ScreenActions.perform(target)
            if pressed { screenModeLastPress = (target, nil) }
            return pressed
        }
        guard let frame = ScreenReader.node(target.element).frame else { return false }
        perform(action, at: CGPoint(x: frame.midX, y: frame.midY))
        return true
    }

    private func perform(_ action: PointerAction, at point: CGPoint) {
        owLog("[Pointer] \(action) at \(Int(point.x)),\(Int(point.y))")
        switch action {
        case .press: ScreenPointer.click(at: point)
        case .doubleClick: ScreenPointer.click(at: point, count: 2)
        case .hover: ScreenPointer.move(to: point)
        case .rightClick:
            ScreenPointer.click(at: point, button: .right)
            showNumbersForMenu()
        }
    }

    /// The menu a right click opened is read by its numbers, whatever was on screen before.
    private func showNumbersForMenu() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.screenModeActive, let app = NSWorkspace.shared.frontmostApplication,
                  !ScreenActions.openMenuItems(of: app).isEmpty else { return }
            self.showScreenNumbers(in: app)
        }
    }

    /// The name's place, by what is said on screen only. A model's guess would be fine for a
    /// press that can be asked about; it is not for a drag.
    private func locate(_ name: String, in app: NSRunningApplication) async -> CGPoint? {
        let elements = ScreenActions.elements(of: app, limit: 400)
        let labels = elements.map(\.label)
        let exact = ScreenActions.exactMatches(name, labels: labels)
        let matches = exact.isEmpty ? ScreenActions.soundAlikeMatches(name, labels: labels) : exact
        if matches.count == 1, let frame = ScreenReader.node(elements[matches[0]].element).frame {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return await ScreenActions.findText(name, in: app)?.point
    }

    private func overlayPoint(_ number: Int) -> CGPoint? {
        switch screenOverlayState {
        case .numbers(_, let targets):
            guard targets.indices.contains(number - 1), let frame = ScreenReader.node(targets[number - 1].element).frame else { return nil }
            return CGPoint(x: frame.midX, y: frame.midY)
        case .grid(let rect):
            return ScreenPointer.gridCell(number, in: rect).map { CGPoint(x: $0.midX, y: $0.midY) }
        case nil:
            return nil
        }
    }

    private func gridArea(of app: NSRunningApplication, fullScreen: Bool) -> CGRect? {
        let window = ScreenReader.focusedWindow(of: app).flatMap { ScreenReader.node($0).frame }
        guard fullScreen else { return window }
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let center = window.map { NSPoint(x: $0.midX, y: mainHeight - $0.midY) }
        let screen = NSScreen.screens.first { candidate in center.map { candidate.frame.contains($0) } ?? false } ?? NSScreen.screens.first
        return screen.map { CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }

    // MARK: - The overlay

    /// Up to 99 numbers: more can't be told apart on screen, and the grid reaches the rest.
    @discardableResult
    func showScreenNumbers(in app: NSRunningApplication) -> Bool {
        var seen: Set<String> = []
        var targets: [ScreenElement] = []
        var items: [(number: Int, frame: CGRect)] = []
        for element in ScreenActions.elements(of: app, limit: 400) {
            guard items.count < 99, let frame = ScreenReader.node(element.element).frame else { continue }
            // A row and the one thing inside it are one place to point at.
            guard seen.insert("\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))").inserted else { continue }
            targets.append(element)
            items.append((targets.count, frame))
        }
        guard !items.isEmpty else {
            hideScreenOverlay()
            return false
        }
        let window = ScreenReader.focusedWindow(of: app).flatMap { ScreenReader.node($0).frame }
        // A menu may reach past the window.
        let covering = items.reduce(window ?? items[0].frame) { $0.union($1.frame) }.insetBy(dx: -24, dy: -24)
        screenOverlayState = .numbers(app: app, targets: targets)
        screenOverlay.show(.numbers(items, covering: covering))
        watchFrontApp()
        owLog("[Pointer] \(items.count) numbers on \(app.localizedName ?? "?")")
        return true
    }

    func showScreenGrid(_ rect: CGRect) {
        screenOverlayRefresh?.cancel()
        screenOverlayState = .grid(rect)
        screenOverlay.show(.grid(rect))
        watchFrontApp()
    }

    func hideScreenOverlay() {
        screenOverlayRefresh?.cancel()
        screenOverlayHoldsNumbers = false
        screenOverlayState = nil
        screenOverlay.hide()
    }

    /// After a step the screen has changed (a new page, a scroll): numbers are read again once
    /// it settled. Never on a timer or after a step that left the screen alone, so a number
    /// doesn't change while it is being said.
    func refreshScreenNumbers(after delay: Duration = .milliseconds(600)) {
        guard case .numbers = screenOverlayState else { return }
        screenOverlayRefresh?.cancel()
        screenOverlayRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, case .numbers = self.screenOverlayState,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self.showScreenNumbers(in: app)
        }
    }

    /// Another app in front: the numbers follow it, and the grid goes.
    private func watchFrontApp() {
        guard screenOverlayFrontObserver == nil else { return }
        screenOverlayFrontObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .grid = self.screenOverlayState { self.hideScreenOverlay() }
                self.refreshScreenNumbers(after: .milliseconds(300))
            }
        }
    }
}
