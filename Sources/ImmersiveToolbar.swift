import SwiftUI
import AppKit

/// Keeps controls reachable while crossing into a popover or tracking a native menu.
@MainActor final class ImmersiveToolbarController: ObservableObject {
    enum Region: Hashable { case edge, toolbar }
    @Published private(set) var isVisible = false
    private var active = false
    private var heldOpen = false
    private var hovered = Set<Region>()
    private var menus = Set<ObjectIdentifier>()
    private var hideTask: Task<Void, Never>?
    private let hideDelay: UInt64

    init(hideDelay: UInt64 = 700_000_000) { self.hideDelay = hideDelay }

    func configure(active: Bool, heldOpen: Bool) {
        if self.active != active {
            hovered.removeAll(); menus.removeAll()
        }
        self.active = active; self.heldOpen = heldOpen
        refresh()
    }

    func hover(_ region: Region, inside: Bool) {
        guard active else { return }
        if inside { hovered.insert(region) } else { hovered.remove(region) }
        refresh()
    }

    func menuOpened(_ menu: NSMenu) {
        guard active, isVisible else { return }
        menus.insert(ObjectIdentifier(menu)); refresh()
    }

    func menuClosed(_ menu: NSMenu) {
        menus.remove(ObjectIdentifier(menu)); refresh()
    }

    private func refresh() {
        hideTask?.cancel(); hideTask = nil
        guard active else { isVisible = false; return }
        if heldOpen || !hovered.isEmpty || !menus.isEmpty { isVisible = true; return }
        guard isVisible else { return }
        hideTask = Task { @MainActor [weak self, hideDelay] in
            do { try await Task.sleep(nanoseconds: hideDelay) } catch { return }
            guard let self, !Task.isCancelled, self.active, !self.heldOpen,
                  self.hovered.isEmpty, self.menus.isEmpty else { return }
            self.isVisible = false
            self.hideTask = nil
        }
    }

    deinit { hideTask?.cancel() }
}

/// The PDF keeps the same frame as controls appear, so its scale and position stay put.
struct ImmersiveReaderSurface<Content: View, Chrome: View>: View {
    let immersive: Bool
    let pinned: Bool
    let interacting: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let chrome: Chrome
    @StateObject private var controls = ImmersiveToolbarController()
    @StoredState<Bool> private var voiceOver = NSWorkspace.shared.isVoiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if !immersive { chrome }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if immersive {
                ZStack(alignment: .top) {
                    Color.clear.frame(height: 14).contentShape(Rectangle())
                        .onHover { controls.hover(.edge, inside: $0) }
                        .accessibilityHidden(true)
                    chrome
                        .frame(maxWidth: 1000)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StudyTheme.line.opacity(0.7), lineWidth: 0.5).allowsHitTesting(false))
                        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .opacity(controls.isVisible ? 1 : 0)
                        .offset(y: controls.isVisible || reduceMotion ? 0 : -8)
                        .allowsHitTesting(controls.isVisible)
                        .accessibilityHidden(!controls.isVisible)
                        .onHover { controls.hover(.toolbar, inside: $0) }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controls.isVisible)
                }
            }
        }
        .ignoresSafeArea(.container, edges: immersive ? .top : [])
        .onAppear(perform: configure)
        .onChange(of: immersive) { _, _ in configure() }
        .onChange(of: pinned) { _, _ in configure() }
        .onChange(of: interacting) { _, _ in configure() }
        .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled)) { value in
            voiceOver = value; configure()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { notification in
            if let menu = notification.object as? NSMenu { controls.menuOpened(menu) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { notification in
            if let menu = notification.object as? NSMenu { controls.menuClosed(menu) }
        }
        .onDisappear { controls.configure(active: false, heldOpen: false) }
    }

    private func configure() {
        controls.configure(active: immersive, heldOpen: pinned || interacting || voiceOver)
    }
}
