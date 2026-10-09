import SwiftUI
import AppKit

/// Remembers whether this reading session, rather than the user, entered full screen.
struct ImmersiveReadingSession {
    private(set) var isActive = false
    private(set) var ownsFullScreen = false

    @discardableResult
    mutating func begin(windowIsFullScreen: Bool) -> Bool {
        guard !isActive else { return false }
        isActive = true
        ownsFullScreen = !windowIsFullScreen
        return ownsFullScreen
    }

    @discardableResult
    mutating func end() -> Bool {
        guard isActive else { return false }
        let shouldLeaveFullScreen = ownsFullScreen
        isActive = false
        ownsFullScreen = false
        return shouldLeaveFullScreen
    }
}

/// Observes the existing reading window without replacing SwiftUI's window delegate.
@MainActor final class ReaderWindowController: NSObject, ObservableObject {
    private(set) weak var window: NSWindow?
    @Published private(set) var isFullScreen = false
    @Published private(set) var isTransitioning = false

    /// Includes a queued reversal, so a new session does not claim that an
    /// outgoing full-screen state was already present before it began.
    var intendedFullScreen: Bool {
        desiredFullScreen ?? transitionTarget ?? isFullScreen
    }

    var onExitFullScreen: (() -> Void)?
    var onEscape: (() -> Bool)?

    private var desiredFullScreen: Bool?
    private var transitionTarget: Bool?
    private var transitionWasRequested = false
    private var transitionGeneration = 0
    private var eventMonitor: Any?
    private var accessorID: ObjectIdentifier?
    private var updatingFullScreenShortcut = false
    func attach(_ window: NSWindow?) {
        attach(window, accessorID: nil)
    }

    fileprivate func attach(_ nextWindow: NSWindow?, accessorID: ObjectIdentifier?) {
        if nextWindow != nil, window === nextWindow {
            self.accessorID = accessorID
            return
        }

        // A pending request may precede the first view attachment. Requests for a
        // window that is being removed must not leak into a different window.
        let pendingInitialRequest = window == nil ? desiredFullScreen : nil
        stopObserving()
        window = nextWindow
        self.accessorID = accessorID
        transitionGeneration += 1
        transitionTarget = nil
        transitionWasRequested = false
        isTransitioning = false
        isFullScreen = nextWindow?.styleMask.contains(.fullScreen) ?? false
        desiredFullScreen = nextWindow == nil ? nil : pendingInitialRequest
        guard let nextWindow else { return }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: nextWindow)
        center.addObserver(self, selector: #selector(didEnterFullScreen), name: NSWindow.didEnterFullScreenNotification, object: nextWindow)
        center.addObserver(self, selector: #selector(willExitFullScreen), name: NSWindow.willExitFullScreenNotification, object: nextWindow)
        center.addObserver(self, selector: #selector(didExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: nextWindow)
        center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nextWindow)
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification] {
            center.addObserver(self, selector: #selector(menuDidChange), name: name, object: nil)
        }
        updateFullScreenShortcut()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window, window.isKeyWindow,
                  event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            return self.onEscape?() == true ? nil : event
        }
        fulfillLatestRequest()
    }

    @objc private func menuDidChange(_ notification: Notification) {
        updateFullScreenShortcut()
    }

    private func updateFullScreenShortcut() {
        guard !updatingFullScreenShortcut, let menu = NSApp.mainMenu else { return }
        updatingFullScreenShortcut = true
        defer { updatingFullScreenShortcut = false }

        // AppKit supplies the localized title, target and full-screen validation.
        // Bind its existing command, including when SwiftUI rebuilds the menu.
        // Only changing the shortcut keeps native exit notifications (and the
        // immersive layout restoration they trigger) on the same path.
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == #selector(NSWindow.toggleFullScreen(_:)) {
                    if item.keyEquivalent != "f" { item.keyEquivalent = "f" }
                    let modifiers: NSEvent.ModifierFlags = [.control, .command]
                    if item.keyEquivalentModifierMask != modifiers { item.keyEquivalentModifierMask = modifiers }
                }
                if let submenu = item.submenu { update(submenu) }
            }
        }
        update(menu)
    }

    fileprivate func detach(accessorID: ObjectIdentifier) {
        // An old SwiftUI probe can leave the hierarchy after its replacement has
        // attached. Only the current probe may detach the shared controller.
        guard self.accessorID == accessorID else { return }
        attach(nil)
    }

    func setFullScreen(_ desired: Bool) {
        desiredFullScreen = desired
        fulfillLatestRequest()
    }

    private func fulfillLatestRequest() {
        guard !isTransitioning, let window, let desired = desiredFullScreen else { return }
        guard desired != isFullScreen else {
            desiredFullScreen = nil
            return
        }
        transitionTarget = desired
        transitionWasRequested = true
        isTransitioning = true
        transitionGeneration += 1
        recoverIfTransitionStalls()
        window.toggleFullScreen(nil)
    }

    private func recoverIfTransitionStalls() {
        // AppKit exposes failed transitions through the delegate, which belongs
        // to SwiftUI. Recover a stalled transition without taking that delegate
        // or retrying a rejected request forever.
        let generation = transitionGeneration
        guard let window else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  self.isTransitioning, self.transitionGeneration == generation else { return }
            self.isFullScreen = window.styleMask.contains(.fullScreen)
            self.isTransitioning = false
            self.transitionTarget = nil
            self.transitionWasRequested = false
            self.desiredFullScreen = nil
        }
    }

    private func transitionWillBegin(toward fullScreen: Bool) {
        if !isTransitioning || transitionTarget != fullScreen {
            // The green traffic-light button and the system View menu remain
            // authoritative; a stale app request must not undo a native action.
            desiredFullScreen = nil
            transitionWasRequested = false
            transitionGeneration += 1
            recoverIfTransitionStalls()
        }
        transitionTarget = fullScreen
        isTransitioning = true
    }

    @objc private func willEnterFullScreen(_ notification: Notification) {
        transitionWillBegin(toward: true)
    }

    @objc private func willExitFullScreen(_ notification: Notification) {
        transitionWillBegin(toward: false)
    }

    @objc private func didEnterFullScreen(_ notification: Notification) {
        guard !isFullScreen || (isTransitioning && transitionTarget == true) else { return }
        finishTransition(fullScreen: true)
    }

    @objc private func didExitFullScreen(_ notification: Notification) {
        guard isFullScreen || (isTransitioning && transitionTarget == false) else { return }
        // A fresh enter request during a native exit is newer than that exit.
        // Do not let its completion cancel the newly started reading session.
        let exitedNatively = !transitionWasRequested && desiredFullScreen != true
        finishTransition(fullScreen: false)
        if exitedNatively { onExitFullScreen?() }
    }

    private func finishTransition(fullScreen: Bool) {
        isFullScreen = fullScreen
        isTransitioning = false
        transitionTarget = nil
        transitionWasRequested = false
        transitionGeneration += 1
        if desiredFullScreen == fullScreen { desiredFullScreen = nil }

        // Wait until AppKit has finished delivering the completion notification
        // before starting an opposite transition requested during its animation.
        let generation = transitionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.fulfillLatestRequest()
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        attach(nil)
    }

    private func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }


}

/// A transparent attachment probe. It never creates a window or takes focus.
struct ReaderWindowAccessor: NSViewRepresentable {
    let controller: ReaderWindowController

    func makeNSView(context: Context) -> ReaderWindowProbe {
        ReaderWindowProbe(controller: controller)
    }

    func updateNSView(_ nsView: ReaderWindowProbe, context: Context) {}
}

@MainActor final class ReaderWindowProbe: NSView {
    private weak var controller: ReaderWindowController?

    init(controller: ReaderWindowController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Window attachment can happen during a SwiftUI update; defer observable
        // publication so it does not modify state inside that update.
        DispatchQueue.main.async { [weak self] in
            guard let self, let controller = self.controller else { return }
            let id = ObjectIdentifier(self)
            if let window = self.window {
                controller.attach(window, accessorID: id)
            } else {
                controller.detach(accessorID: id)
            }
        }
    }
}
