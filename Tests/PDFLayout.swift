import Foundation
import AppKit
import PDFKit

/// Exercises the live PDFKit view only in an offscreen test window and temporary
/// library. No Fishbook process, user defaults, or real learning records are used.
@main struct PDFLayoutChecks {
    @MainActor private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        fatalError("Timed out: " + message)
    }
    private static func samePassage(_ first: ReadingPosition?, _ second: ReadingPosition) -> Bool {
        guard let first else { return false }
        return first.page == second.page && abs(first.y - second.y) < 3
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fishbook-pdf-layout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = StudyStore(resourceDirectory: resources, dataDirectory: temp)
        store.select("R01")
        let pdf = PDFController()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 820))
        window.contentView = host
        pdf.view.frame = host.bounds
        pdf.view.autoresizingMask = [.width, .height]
        host.addSubview(pdf.view)
        pdf.load(store.paper!, store: store)
        try await wait("PDF loaded") { pdf.view.document != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        let document = pdf.view.document!
        pdf.view.go(to: PDFDestination(page: document.page(at: 4)!, at: CGPoint(x: 0, y: 420)))
        pdf.flush()
        let passage = store.readingPosition(for: "R01")!
        precondition(passage.page == 4, "fixture begins halfway down PDF page 5")
        precondition(!pdf.canBack && !pdf.canForward)

        func resize(_ width: CGFloat, _ height: CGFloat) {
            window.setContentSize(NSSize(width: width, height: height))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            pdf.view.frame = host.bounds
            host.layoutSubtreeIfNeeded()
        }
        pdf.preservePositionForLayoutChange()
        resize(1120, 910)
        try await Task.sleep(nanoseconds: 160_000_000)
        try await wait("wide reader preserves the same paragraph") {
            pdf.flush()
            return samePassage(store.readingPosition(for: "R01"), passage)
        }
        // A fullscreen animation can briefly settle at an intermediate width,
        // then resize once more. It is still the same requested layout change.
        resize(1430, 960)
        try await Task.sleep(nanoseconds: 160_000_000)
        try await wait("late fullscreen geometry retains the original passage") {
            pdf.flush()
            return samePassage(store.readingPosition(for: "R01"), passage)
        }
        precondition(pdf.view.document === document && !pdf.canBack && !pdf.canForward,
                     "relayout must retain the loaded document and must not create navigation history")
        print("successive widths preserve the visible passage")

        pdf.preservePositionForLayoutChange()
        pdf.view.removeFromSuperview()
        pdf.view.frame = .zero
        pdf.flush()
        precondition(samePassage(store.readingPosition(for: "R01"), passage), "a hidden zero-size PDF cannot overwrite the saved passage")
        try await Task.sleep(nanoseconds: 160_000_000)
        resize(460, 700)
        host.addSubview(pdf.view)
        pdf.view.frame = host.bounds
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 160_000_000)
        try await wait("unmount/remount restores the same page and in-page location") {
            pdf.flush()
            return samePassage(store.readingPosition(for: "R01"), passage)
        }
        precondition(!pdf.canBack && !pdf.canForward)
        print("zero frame and PDF view remount preserve progress")

        pdf.preservePositionForLayoutChange()
        resize(920, 840)
        // Reading input is delivered before PDFKit handles the resulting scroll.
        pdf.view.readingFocused?()
        pdf.view.go(to: document.page(at: 8)!)
        try await Task.sleep(nanoseconds: 180_000_000)
        pdf.flush()
        precondition(store.readingPosition(for: "R01")?.page == 8,
                     "a user scroll during layout takes priority over the queued restoration")
        pdf.preservePositionForLayoutChange()
        resize(650, 760)
        pdf.goPage(7)
        try await Task.sleep(nanoseconds: 180_000_000)
        pdf.flush()
        precondition(store.readingPosition(for: "R01")?.page == 6,
                     "a requested page jump cannot be undone by an old layout anchor")
        precondition(pdf.canBack && !pdf.canForward)
        pdf.goBack()
        precondition(pdf.pageNumber == 9, "layout preservation must not insert a synthetic history entry")
        print("user scroll and explicit navigation supersede layout restoration")

        pdf.preservePositionForLayoutChange()
        resize(1180, 920)
        store.select("R02")
        pdf.load(store.paper!, store: store)
        try await Task.sleep(nanoseconds: 180_000_000)
        precondition(pdf.loadedID == "R02" && pdf.pageNumber == 1 && !pdf.canBack,
                     "a queued restore cannot move a newly selected paper to the previous paper's page")
        print("PASS: PDFKit wide/narrow reflow and late fullscreen resize; detach and zero-frame persistence; same-page paragraph restoration; no synthetic history; user takeover; paper-switch cancellation.")
    }
}
