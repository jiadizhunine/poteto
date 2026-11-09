import AppKit
import SwiftUI
import Darwin

@main
@MainActor
struct PanelMotionSmoke {
    struct Failure: Error { let message: String }
    static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw Failure(message: message) }
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    static func scrollView(_ window: NSWindow) throws -> NSScrollView {
        let scrolls = window.contentView.map { scrollViews(in: $0) } ?? []
        try check(scrolls.count == 1, "fixture must contain one native account scroll view")
        return scrolls[0]
    }

    static func sample(_ window: NSWindow, seconds: TimeInterval, scrolling: Bool? = false) async throws -> [NSRect] {
        let deadline = Date().addingTimeInterval(seconds)
        var frames = [window.frame]
        let scroll = try scrollView(window)
        var visibilityChanges = 0
        var visible = scroll.hasVerticalScroller && scroll.verticalScroller?.isHidden == false
        var maximumOverflow: CGFloat = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            frames.append(window.frame)
            try check(try scrollView(window) === scroll, "transition replaced the native scroll view")
            let nowVisible = scroll.hasVerticalScroller && scroll.verticalScroller?.isHidden == false
            if let scrolling {
                try check(scrolling ? scroll.hasVerticalScroller : !nowVisible,
                          "transition flashed an unnecessary indicator or removed a required one")
            }
            if visible != nowVisible { visibilityChanges += 1 }
            visible = nowVisible
            maximumOverflow = max(maximumOverflow, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        }
        try check(visibilityChanges <= (scrolling == nil ? 1 : 0), "native scroll indicator flickered during transition")
        print("poteto: \(frames.count) native samples, \(visibilityChanges) indicator visibility changes; " +
              "max document/viewport difference \(String(format: "%.3f", maximumOverflow)) pt")
        return frames
    }

    static func verify(_ frames: [NSRect], from start: NSRect, to end: NSRect, name: String) throws {
        let low = min(start.height, end.height), high = max(start.height, end.height)
        let heights = Set(frames.map { Int(($0.height * 10).rounded()) })
        let intermediates = frames.filter { $0.height > low + 1 && $0.height < high - 1 }
        print("poteto: \(name) native window \(Int(start.height))→\(Int(end.height)) pt; " +
              "\(heights.count) distinct heights, \(intermediates.count) intermediate frames")
        try check(high - low > 40, "\(name) did not change the detail region height")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try check(heights.count <= 2, "\(name) ignored reduced motion")
        } else {
            try check(heights.count >= 4 && intermediates.count >= 3, "\(name) window snapped instead of animating")
        }
        try check(frames.allSatisfy { abs($0.width - start.width) <= 1 && abs($0.maxY - start.maxY) <= 2 },
                  "\(name) moved account headers or changed panel width")
    }

    static func toggle(_ state: PanelState, _ id: String, reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: PanelState.transitionDuration)) {
            state.toggleAccountDetails(id)
        }
    }

    static func verifyWheel(_ window: NSWindow) async throws {
        let scroll = try scrollView(window)
        let before = scroll.contentView.bounds.minY
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -80, wheel2: 0, wheel3: 0), let wheel = NSEvent(cgEvent: event) else {
            throw Failure(message: "cannot create fixture-only scroll wheel event")
        }
        // Deliver to this fixture's scroll view, never post an event to another app.
        scroll.scrollWheel(with: wheel)
        try await Task.sleep(nanoseconds: 120_000_000)
        try check(scroll.contentView.bounds.minY > before + 1, "overflow list no longer responds to native scrolling")
        print("poteto: fixture-only native wheel scrolled \(Int(scroll.contentView.bounds.minY - before)) pt")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { fputs("poteto: no GUI screen for motion smoke\n", stderr); exit(1) }
        let state = PanelState()
        state.theme = DesktopTheme(surface: DesktopTheme.hex("#f3eee3")!, ink: DesktopTheme.hex("#2b2924")!,
                                   accent: DesktopTheme.hex("#d97857")!, uiFont: nil)
        state.availableScreenSize = screen.visibleFrame.size
        let usage = Usage(plan: "free", windows: [UsageWindow(label: "Codex", durationMinutes: 43200,
            remaining: 63, reset: Date().addingTimeInterval(86400), ordinary: true)], checkedAt: Date(),
            resetAllowance: ResetAllowance(availableCount: 0, applicableCount: 0, credits: []))
        func snapshot(_ count: Int) -> Snapshot {
            Snapshot(accounts: (0..<count).map {
                AccountView(id: "fixture-\($0)", email: "account-\($0)@example.invalid", workspace: "fixture",
                            current: $0 == 0, plan: "free", usage: usage, error: nil)
            }, refreshing: false, error: nil, loginRunning: false)
        }
        state.snapshot = snapshot(3)
        var unexpectedActions = 0
        let panel = PotetoPanel(state: state, refresh: { unexpectedActions += 1 }, addAccount: { unexpectedActions += 1 },
            switchAccount: { _ in unexpectedActions += 1 }, forget: { _ in unexpectedActions += 1 },
            toggleStart: { unexpectedActions += 1 }, quit: { unexpectedActions += 1 })
        let hosting = PanelHostingController(rootView: panel)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        hosting.popover = popover
        popover.contentViewController = hosting
        let visible = screen.visibleFrame
        let x = NSEvent.mouseLocation.x < visible.midX ? visible.maxX - 430 : visible.minX + 40
        let anchor = NSPanel(contentRect: NSRect(x: x, y: visible.maxY - 100, width: 20, height: 20),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderBack(nil)
        popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        Task { @MainActor in
            var result: Int32 = 0
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard let window = hosting.view.window else { throw Failure(message: "native popover has no window") }
                hosting.animatesSizeChanges = true
                let collapsed = window.frame
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                for cycle in 1...3 {
                    state.hoverAccount("fixture-1", inside: true, reduceMotion: reduceMotion)
                    let opening = try await sample(window, seconds: 1.0)
                    try check(state.detailAccountID == "fixture-1", "fixture hover failed to expand")
                    let expanded = window.frame
                    try verify(opening, from: collapsed, to: expanded, name: "expand \(cycle)")
                    state.hoverAccount("fixture-2", inside: true, reduceMotion: reduceMotion)
                    state.hoverAccount("fixture-1", inside: false, reduceMotion: reduceMotion)
                    let switching = try await sample(window, seconds: 0.65)
                    try check(state.detailAccountID == "fixture-2" && switching.allSatisfy { $0.height >= expanded.height - 1 },
                              "moving between accounts briefly collapsed the detail region")
                    state.hoverAccount("fixture-2", inside: true, reduceMotion: reduceMotion)
                    let repeated = try await sample(window, seconds: 0.30)
                    try check(repeated.allSatisfy { abs($0.height - expanded.height) <= 1 },
                              "repeated selection resized an unchanged account")
                    state.leaveAccountArea(reduceMotion: reduceMotion)
                    let closing = try await sample(window, seconds: 1.0)
                    try check(state.detailAccountID == nil, "fixture hover failed to dismiss")
                    try verify(closing, from: expanded, to: window.frame, name: "collapse \(cycle)")
                    try check(abs(window.frame.height - collapsed.height) <= 1, "collapse failed to restore panel height")
                }

                toggle(state, "fixture-1", reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.7)
                state.hoverAccount("fixture-0", inside: true, reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.7)
                state.leaveAccountArea(reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.7)
                try check(state.detailAccountID == "fixture-1", "hover exit failed to restore the clicked account")
                toggle(state, "fixture-1", reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.7)
                toggle(state, "fixture-1", reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.07)
                toggle(state, "fixture-0", reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.7)
                try check(state.detailAccountID == "fixture-0", "mid-animation click failed to replace the account")

                hosting.animatesSizeChanges = false
                state.resetAccountPreview()
                state.availableScreenSize = NSSize(width: 360, height: 360)
                try await Task.sleep(nanoseconds: 350_000_000)
                hosting.animatesSizeChanges = true
                let smallCollapsed = window.frame
                state.hoverAccount("fixture-1", inside: true, reduceMotion: reduceMotion)
                let smallOpening = try await sample(window, seconds: 1.0, scrolling: nil)
                let smallExpanded = window.frame
                try verify(smallOpening, from: smallCollapsed, to: smallExpanded, name: "small-screen expand")
                try check(try scrollView(window).hasVerticalScroller && popover.contentSize.height <= state.bounds.maximumHeight + 1,
                          "small screen failed to show its needed indicator or exceeded the screen cap")
                try await verifyWheel(window)
                state.hoverAccount("fixture-2", inside: true, reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.65, scrolling: true)
                state.leaveAccountArea(reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 1.0, scrolling: nil)
                try check(try !scrollView(window).hasVerticalScroller, "small-screen collapse left an unnecessary indicator")

                hosting.animatesSizeChanges = false
                state.availableScreenSize = NSSize(width: 360, height: 480)
                state.snapshot = snapshot(12)
                try await Task.sleep(nanoseconds: 350_000_000)
                _ = try await sample(window, seconds: 0.2, scrolling: true)
                try await verifyWheel(window)
                hosting.animatesSizeChanges = true
                state.hoverAccount("fixture-1", inside: true, reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.8, scrolling: true)
                state.hoverAccount("fixture-2", inside: true, reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.65, scrolling: true)
                state.leaveAccountArea(reduceMotion: reduceMotion)
                _ = try await sample(window, seconds: 0.8, scrolling: true)

                hosting.animatesSizeChanges = false
                state.availableScreenSize = screen.visibleFrame.size
                state.snapshot = snapshot(3)
                try await Task.sleep(nanoseconds: 350_000_000)
                state.hoverAccount("fixture-1", inside: true, reduceMotion: true)
                let immediate = try await sample(window, seconds: 0.7)
                try check(state.detailAccountID == "fixture-1" && Set(immediate.map { Int(($0.height * 10).rounded()) }).count <= 2,
                          "reduced-motion fixture failed to expand without interpolation")
                state.leaveAccountArea(reduceMotion: true)
                _ = try await sample(window, seconds: 0.5)
                try check(state.detailAccountID == nil, "reduced-motion fixture failed to dismiss")

                hosting.animatesSizeChanges = true
                state.hoverAccount("fixture-1", inside: true, reduceMotion: reduceMotion)
                try await Task.sleep(nanoseconds: UInt64((PanelState.hoverDelay + 0.08) * 1_000_000_000))
                hosting.stopSizeAnimation(); state.cancelAccountHover()
                let stopped = window.frame
                let afterStop = try await sample(window, seconds: 0.2)
                try check(afterStop.allSatisfy { abs($0.height - stopped.height) <= 1 } && popover.animates,
                          "closing failed to cancel size animation or restore native popover animation")
                try check(unexpectedActions == 0, "fixture invoked an external account or app action")
                print("poteto: repeated/cross-account/interrupted NSPopover motion and small-screen/multi-account native scrolling passed")
                print("poteto: fixture simulated hover state; physical mouse delivery and subjective smoothness were not measured")
            } catch {
                result = 1
                fputs("poteto: motion smoke failed: \(error)\n", stderr)
            }
            popover.close(); anchor.close()
            exit(result)
        }
        app.run()
    }
}
