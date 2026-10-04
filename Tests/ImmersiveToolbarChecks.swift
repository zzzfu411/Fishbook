import AppKit

@main struct ImmersiveToolbarChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let controls = ImmersiveToolbarController(hideDelay: 35_000_000)
        func settle() async throws { try await Task.sleep(nanoseconds: 90_000_000) }

        controls.configure(active: true, heldOpen: false)
        precondition(!controls.isVisible, "entering immersion starts with an unobstructed page")
        controls.hover(.edge, inside: true)
        precondition(controls.isVisible)
        controls.hover(.edge, inside: false)
        precondition(controls.isVisible, "crossing from the edge must allow time to reach the controls")
        controls.hover(.toolbar, inside: true)
        try await settle()
        precondition(controls.isVisible, "the old edge-exit timer cannot hide a hovered toolbar")
        controls.hover(.toolbar, inside: false)
        try await settle()
        precondition(!controls.isVisible)

        // Search or a popover can open from a keyboard command with the pointer in the PDF.
        controls.configure(active: true, heldOpen: true)
        try await settle()
        precondition(controls.isVisible, "active input must not disappear while typing")
        controls.configure(active: true, heldOpen: false)
        try await settle()
        precondition(!controls.isVisible, "closing input restores automatic hiding")

        let parent = NSMenu(), submenu = NSMenu()
        controls.hover(.edge, inside: true)
        controls.menuOpened(parent); controls.menuOpened(submenu)
        controls.hover(.edge, inside: false)
        controls.menuClosed(submenu)
        try await settle()
        precondition(controls.isVisible, "closing a submenu cannot dismiss its parent toolbar")
        controls.menuClosed(parent)
        try await settle()
        precondition(!controls.isVisible)
        controls.menuOpened(parent)
        precondition(!controls.isVisible, "an unrelated menu cannot reveal hidden reading controls")

        // Exit and re-enter before a pending hide runs: no menu or hover state may leak.
        controls.hover(.toolbar, inside: true)
        controls.menuOpened(parent)
        controls.configure(active: false, heldOpen: false)
        controls.hover(.edge, inside: true)
        controls.configure(active: true, heldOpen: false)
        precondition(!controls.isVisible)
        controls.configure(active: true, heldOpen: true)
        try await settle()
        precondition(controls.isVisible, "pinning survives any canceled timer from a previous session")
        controls.configure(active: false, heldOpen: false)
        print("PASS: hidden entry; delayed exit; hover handoff; search/popover retention; nested native menus; pinning; session cleanup.")
    }
}
