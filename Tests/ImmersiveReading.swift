import Foundation
import AppKit

/// Records native requests without entering a Space or showing a real window.
@MainActor private final class SimulatedReaderWindow: NSWindow {
    var simulatedFullScreen = false
    private(set) var toggleCount = 0

    override var styleMask: NSWindow.StyleMask {
        get {
            var mask = super.styleMask
            if simulatedFullScreen { mask.insert(.fullScreen) }
            else { mask.remove(.fullScreen) }
            return mask
        }
        set {
            simulatedFullScreen = newValue.contains(.fullScreen)
            super.styleMask = newValue.subtracting(.fullScreen)
        }
    }
    override func toggleFullScreen(_ sender: Any?) { toggleCount += 1 }
    func emit(_ name: Notification.Name) {
        if name == NSWindow.didEnterFullScreenNotification { simulatedFullScreen = true }
        if name == NSWindow.didExitFullScreenNotification { simulatedFullScreen = false }
        NotificationCenter.default.post(name: name, object: self)
    }
}

@main struct ImmersiveReadingChecks {
    @MainActor private static func window(fullScreen: Bool = false) -> SimulatedReaderWindow {
        let window = SimulatedReaderWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 600),
                                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.simulatedFullScreen = fullScreen
        window.isReleasedWhenClosed = false
        return window
    }
    @MainActor private static func drain() async throws {
        // Let completion callbacks enqueue a reverse transition. No native
        // fullscreen animation is running in this harness.
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // Leaving focus mode must restore the user's choice, including a Space
        // they had already entered before using Fishbook's focus command.
        for priorFullScreen in [false, true] {
            var session = ImmersiveReadingSession()
            precondition(!session.end(), "an idle exit cannot own the window")
            precondition(session.begin(windowIsFullScreen: priorFullScreen) == !priorFullScreen)
            for observedDuringAnimation in [false, true, false, true] {
                precondition(!session.begin(windowIsFullScreen: observedDuringAnimation), "repeated enter must not acquire a second session")
                precondition(session.isActive && session.ownsFullScreen == !priorFullScreen,
                             "transient native state cannot overwrite original fullscreen ownership")
            }
            precondition(session.end() == !priorFullScreen)
            precondition(!session.isActive && !session.ownsFullScreen)
            precondition(!session.end() && !session.end(), "duplicate exits cannot close a user's existing fullscreen window")
            precondition(session.begin(windowIsFullScreen: true) == false, "a new session takes a fresh snapshot")
            precondition(session.end() == false)
        }
        print("session ownership verified")

        let first = window(), other = window()
        defer { first.close(); other.close() }
        let controller = ReaderWindowController()
        var nativeExits = 0
        controller.onExitFullScreen = { nativeExits += 1 }
        controller.attach(first)
        precondition(!controller.isFullScreen && !controller.isTransitioning)
        controller.setFullScreen(false)
        precondition(first.toggleCount == 0, "matching requested state must never toggle")

        // Escape can happen before the enter animation has finished. Queue one
        // opposite transition instead of asking AppKit to toggle while busy.
        var session = ImmersiveReadingSession()
        if session.begin(windowIsFullScreen: controller.isFullScreen) { controller.setFullScreen(true) }
        controller.setFullScreen(true)
        precondition(first.toggleCount == 1 && controller.isTransitioning)
        precondition(controller.intendedFullScreen, "ownership decisions use the requested destination during entry")
        first.emit(NSWindow.willEnterFullScreenNotification)
        if session.end() { controller.setFullScreen(false) }
        controller.setFullScreen(false)
        precondition(first.toggleCount == 1, "an in-flight enter is not interruptible by a second native toggle")
        precondition(!controller.intendedFullScreen, "queued exit is the latest intent even before AppKit exits")
        other.emit(NSWindow.didEnterFullScreenNotification)
        precondition(!controller.isFullScreen, "another window cannot complete this transition")
        other.simulatedFullScreen = false
        first.emit(NSWindow.didEnterFullScreenNotification)
        try await drain()
        precondition(first.toggleCount == 2 && controller.isTransitioning, "rapid enter/exit must converge to windowed once enter completes")
        first.emit(NSWindow.didEnterFullScreenNotification)
        try await drain()
        precondition(first.toggleCount == 2 && controller.isTransitioning, "duplicate enter completion must not restart an in-flight exit")
        first.emit(NSWindow.willExitFullScreenNotification)
        first.emit(NSWindow.didExitFullScreenNotification)
        first.emit(NSWindow.didExitFullScreenNotification)
        try await drain()
        precondition(first.toggleCount == 2 && !controller.isFullScreen && !controller.isTransitioning)
        precondition(nativeExits == 0, "a programmatic exit must not masquerade as the user's native exit")
        print("rapid reverse request and duplicate notifications verified")

        // The most recent intent wins even if the user changes their mind more
        // than once during one AppKit animation.
        controller.setFullScreen(true)
        first.emit(NSWindow.willEnterFullScreenNotification)
        controller.setFullScreen(false)
        controller.setFullScreen(true)
        first.emit(NSWindow.didEnterFullScreenNotification)
        try await drain()
        precondition(first.toggleCount == 3 && controller.isFullScreen && !controller.isTransitioning)

        // A native green-button exit ends focus once; calling end afterward is
        // harmless and must not unexpectedly reenter a Space.
        precondition(session.begin(windowIsFullScreen: controller.isFullScreen) == false)
        controller.onExitFullScreen = {
            nativeExits += 1
            if session.end() { controller.setFullScreen(false) }
        }
        first.emit(NSWindow.willExitFullScreenNotification)
        first.emit(NSWindow.didExitFullScreenNotification)
        first.emit(NSWindow.didExitFullScreenNotification)
        try await drain()
        precondition(nativeExits == 1 && !session.isActive && first.toggleCount == 3)
        precondition(!session.end())

        controller.setFullScreen(true)
        first.emit(NSWindow.willEnterFullScreenNotification)
        first.emit(NSWindow.didEnterFullScreenNotification)
        try await drain()
        precondition(session.begin(windowIsFullScreen: false), "this focus session owns its native fullscreen entry")
        first.emit(NSWindow.willExitFullScreenNotification)
        first.emit(NSWindow.didExitFullScreenNotification)
        try await drain()
        precondition(nativeExits == 2 && !session.isActive && first.toggleCount == 4,
                     "manual exit followed by session cleanup cannot toggle fullscreen again")
        print("native exit and existing fullscreen verified")

        // Detaching/replacing a SwiftUI window must invalidate late AppKit
        // events and requests, including a pending reverse transition.
        controller.setFullScreen(true)
        controller.setFullScreen(false)
        controller.attach(other)
        first.emit(NSWindow.didEnterFullScreenNotification)
        first.emit(NSWindow.didExitFullScreenNotification)
        try await drain()
        precondition(!controller.isFullScreen && !controller.isTransitioning && other.toggleCount == 0)
        precondition(nativeExits == 2, "detached window notifications cannot reach the active session")
        controller.attach(nil)
        controller.setFullScreen(true)
        controller.attach(other)
        precondition(other.toggleCount == 1, "a command before initial attachment is delivered once")
        controller.attach(other)
        precondition(other.toggleCount == 1, "SwiftUI updates cannot repeat the same pending command")
        controller.attach(nil)
        other.emit(NSWindow.didEnterFullScreenNotification)
        precondition(!controller.isFullScreen && !controller.isTransitioning)

        let alreadyFull = window(fullScreen: true)
        defer { alreadyFull.close() }
        controller.attach(alreadyFull)
        precondition(controller.isFullScreen)
        if session.begin(windowIsFullScreen: controller.isFullScreen) { controller.setFullScreen(true) }
        if session.end() { controller.setFullScreen(false) }
        precondition(alreadyFull.toggleCount == 0 && controller.isFullScreen, "prior native fullscreen survives the complete focus session")
        controller.attach(nil)
        let reversingNative = window(fullScreen: true)
        defer { reversingNative.close() }
        let reversalController = ReaderWindowController()
        var staleExitCallbacks = 0
        reversalController.onExitFullScreen = { staleExitCallbacks += 1 }
        reversalController.attach(reversingNative)
        reversingNative.emit(NSWindow.willExitFullScreenNotification)
        precondition(!reversalController.intendedFullScreen)
        reversalController.setFullScreen(true)
        reversingNative.emit(NSWindow.didExitFullScreenNotification)
        try await drain()
        precondition(staleExitCallbacks == 0 && reversingNative.toggleCount == 1 && reversalController.intendedFullScreen,
                     "an earlier native exit must not cancel a newer enter request")
        reversingNative.emit(NSWindow.willEnterFullScreenNotification)
        reversingNative.emit(NSWindow.didEnterFullScreenNotification)
        try await drain()
        precondition(reversalController.isFullScreen && !reversalController.isTransitioning)
        reversalController.attach(nil)
        print("PASS: immersive ownership and idempotence; latest native request; rapid enter/exit; native exit cleanup; unrelated/stale window events; attachment and prior fullscreen restoration. No actual window entered fullscreen.")
    }
}
