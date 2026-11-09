import AppKit
import SwiftUI
import Darwin

@main
@MainActor
struct PanelInteractionTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        checks += 1
    }

    static func fixtureSnapshot(accountCount: Int = 2, error: String? = nil) -> Snapshot {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let usage = Usage(plan: "fixture", windows: [
            UsageWindow(label: "Codex", durationMinutes: 300, remaining: 63, reset: date, ordinary: true),
            UsageWindow(label: "Weekly", durationMinutes: 10080, remaining: 33, reset: date, ordinary: true)
        ], checkedAt: date,
            credits: CreditBalance(balance: "56509.1182155", unlimited: false, expiresAt: date),
            resetAllowance: ResetAllowance(availableCount: 2, applicableCount: 1,
                credits: [ResetCredit(id: "fixture-reset", title: "额度重置", expiresAt: date)]))
        return Snapshot(accounts: (0..<accountCount).map {
            AccountView(id: "fixture-\($0)", email: "account-\($0)@example.invalid", workspace: "fixture",
                        current: $0 == 0, plan: $0 == 0 ? "pro" : "free", usage: $0 == 0 ? usage : nil, error: nil)
        }, refreshing: false, error: error, loginRunning: false)
    }

    static func subscriptionTests() throws {
        func account(_ plan: String?, usage: Usage? = nil) -> AccountView {
            AccountView(id: "fixture", email: "fixture@example.invalid", workspace: "fixture", current: false,
                        plan: plan, usage: usage, error: nil)
        }
        for (raw, title) in [("free", "Free"), ("go", "Go"), ("plus", "Plus"), ("pro", "Pro"),
                             ("team", "Team"), ("business", "Business"), ("enterprise", "Enterprise"), ("edu", "Edu"),
                             ("new-official-tier", "new-official-tier")] {
            try check(account(raw).subscriptionTitle == title, "official plan label for \(raw)")
        }
        try check(account(nil).subscriptionTitle == "待确认", "missing plan is not guessed")
        try check(account("pro\n").subscriptionTitle == "待确认", "invalid plan is rejected")
        let usage = Usage(plan: "free", windows: [], checkedAt: Date())
        try check(account("pro", usage: usage).subscriptionTitle == "Free", "usage response overrides an older identity plan")
        try check(account("pro").subscriptionTitle == "Pro", "Pro does not imply a particular price or monthly allowance")
        let old = Data("{\"id\":\"fixture\",\"email\":\"fixture@example.invalid\",\"workspace\":\"fixture\",\"current\":false}".utf8)
        try check(try JSONDecoder().decode(AccountView.self, from: old).subscriptionTitle == "待确认", "old status without plan still decodes")
    }

    static func previewTests() throws {
        let state = PanelState()
        state.snapshot = fixtureSnapshot()
        state.settings = true
        state.startup = false
        let originalBounds = state.bounds
        try check(state.detailAccountID == nil, "account details initially collapsed")
        state.previewAccount("fixture-0")
        try check(state.detailAccountID == "fixture-0", "hover opens the current account details")
        state.previewAccount("fixture-0")
        try check(state.detailAccountID == "fixture-0", "repeated hover does not toggle details off")
        state.previewAccount("fixture-1")
        try check(state.detailAccountID == "fixture-1", "moving hover changes the detail account")
        state.clearAccountPreview()
        try check(state.detailAccountID == nil, "leaving the account clears its preview")
        state.clearAccountPreview()
        try check(state.detailAccountID == nil, "clearing an absent preview is idempotent")
        state.toggleAccountDetails("fixture-0")
        try check(state.detailAccountID == "fixture-0", "click or keyboard opens account details")
        state.toggleAccountDetails("fixture-0")
        try check(state.detailAccountID == nil, "click or keyboard closes the same account details")
        state.toggleAccountDetails("fixture-0")
        state.toggleAccountDetails("fixture-1")
        try check(state.detailAccountID == "fixture-1", "clicking another account replaces the details")
        state.previewAccount("fixture-0")
        try check(state.detailAccountID == "fixture-0", "hover temporarily replaces a clicked account")
        state.clearAccountPreview()
        try check(state.detailAccountID == "fixture-1", "leaving hover restores the clicked account")
        state.toggleAccountDetails("fixture-1")
        try check(state.detailAccountID == nil, "clicking the pinned account again collapses it")
        state.previewAccount("fixture-0")
        state.toggleAccountDetails("fixture-0")
        try check(state.detailAccountID == "fixture-0", "click can pin the hovered account")
        state.clearAccountPreview()
        try check(state.detailAccountID == "fixture-0", "a clicked account survives hover exit")
        state.toggleAccountDetails("fixture-0")
        try check(state.detailAccountID == nil, "click still toggles an account opened by hover")
        state.toggleAccountDetails("fixture-1")
        state.resetAccountPreview()
        state.clearAccountPreview()
        try check(state.detailAccountID == nil, "resetting the panel clears both hover and click details")
        try check(state.settings && !state.startup && state.bounds == originalBounds,
                  "account interaction preserves settings, startup state, and screen bounds")
        try check(state.snapshot.accounts.map(\.id) == ["fixture-0", "fixture-1"] &&
                  state.snapshot.accounts[0].current && state.snapshot.accounts[0].usage?.ordinaryRemaining == 33,
                  "preview does not switch accounts or change usage")
    }

    static func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func hoverTimingTests() async throws {
        try check(PanelState.hoverDelay == 0.24 && PanelState.dismissDelay == 0.18,
                  "account hover and dismissal retain their original delays")
        let state = PanelState()
        state.snapshot = fixtureSnapshot()
        state.hoverAccount("fixture-0", inside: true)
        try check(state.detailAccountID == nil, "hover entry does not immediately expand details")
        try await pause(0.06)
        try check(state.detailAccountID == nil, "passing over a row stays collapsed during the dwell delay")
        state.hoverAccount("fixture-0", inside: false)
        try await pause(PanelState.hoverDelay + 0.08)
        try check(state.detailAccountID == nil, "fast hover exit cancels the pending expansion")

        state.hoverAccount("fixture-0", inside: true)
        try await pause(PanelState.hoverDelay + 0.08)
        try check(state.detailAccountID == "fixture-0", "a deliberate hover expands after the dwell delay")
        state.hoverAccount("fixture-0", inside: false)
        try await pause(0.05)
        try check(state.detailAccountID == "fixture-0", "brief travel from a header to its details does not collapse them")
        state.hoverDetails(true)
        try await pause(PanelState.dismissDelay + 0.08)
        try check(state.detailAccountID == "fixture-0", "entering details cancels dismissal so buttons remain usable")
        state.hoverDetails(false)
        try check(state.detailAccountID == "fixture-0", "leaving details starts a grace period instead of snapping shut")
        try await pause(PanelState.dismissDelay + 0.08)
        try check(state.detailAccountID == nil, "leaving the details eventually collapses an unpinned preview")

        state.hoverAccount("fixture-0", inside: true)
        try await pause(0.06)
        state.hoverAccount("fixture-1", inside: true)
        state.hoverAccount("fixture-0", inside: false)
        try await pause(0.13)
        try check(state.detailAccountID == nil, "rapid movement does not display the abandoned account")
        try await pause(0.19)
        try check(state.detailAccountID == "fixture-1", "a stale hover-exit event cannot cancel the new row's dwell")
        state.leaveAccountArea()
        try await pause(0.05)
        state.hoverAccount("fixture-1", inside: true)
        try await pause(PanelState.dismissDelay + 0.08)
        try check(state.detailAccountID == "fixture-1", "re-entering the row cancels delayed dismissal")
        state.leaveAccountArea()
        try await pause(PanelState.dismissDelay + 0.08)
        try check(state.detailAccountID == nil, "moving to the footer collapses the preview without leaving the panel")

        state.hoverAccount("fixture-0", inside: true)
        state.toggleAccountDetails("fixture-1")
        try await pause(PanelState.hoverDelay + 0.08)
        try check(state.detailAccountID == "fixture-1", "a pending hover cannot override a deliberate click")
        state.hoverAccount("fixture-0", inside: true)
        try await pause(PanelState.hoverDelay + 0.08)
        try check(state.detailAccountID == "fixture-0", "hover can still preview a different account while one is pinned")
        state.leaveAccountArea()
        try await pause(PanelState.dismissDelay + 0.08)
        try check(state.detailAccountID == "fixture-1", "dismissal restores the pinned account instead of losing the click")

        state.resetAccountPreview()
        state.hoverAccount("fixture-0", inside: true)
        state.cancelAccountHover()
        try await pause(PanelState.hoverDelay + 0.08)
        try check(state.detailAccountID == nil, "closing the popover cancels delayed expansion before its close animation")
        state.hoverAccount("fixture-0", inside: true)
        state.resetAccountPreview()
        try await pause(PanelState.hoverDelay + 0.08)
        try check(state.detailAccountID == nil, "a closed panel cannot be reopened by an abandoned task")

        state.hoverAccount("fixture-1", inside: true)
        state.snapshot = fixtureSnapshot(accountCount: 1)
        try await pause(PanelState.hoverDelay + 0.08)
        try check(state.detailAccountID == nil, "an account removed during the dwell delay is not displayed")
        state.hoverAccount("fixture-0", inside: true, reduceMotion: true)
        try check(state.detailAccountID == nil, "reduced motion retains the anti-flicker dwell delay")
        try await pause(PanelState.hoverDelay + 0.08)
        try check(state.detailAccountID == "fixture-0", "reduced motion can still open details")
        state.leaveAccountArea(reduceMotion: true)
        try await pause(PanelState.dismissDelay + 0.08)
        try check(state.detailAccountID == nil, "reduced motion can still dismiss details")
        try check(state.snapshot.accounts.count == 1 && state.snapshot.accounts[0].current &&
                  state.snapshot.accounts[0].usage?.ordinaryRemaining == 33,
                  "timed hover never switches accounts or modifies usage")
    }

    static func buttonTests() throws {
        for hovered in [false, true] {
            for pressed in [false, true] {
                for selected in [false, true] {
                    try check(MenuButtonStyle.backgroundOpacity(enabled: false, hovered: hovered,
                              pressed: pressed, selected: selected) == 0,
                              "disabled buttons have no background for any interaction state")
                }
            }
        }
        for selected in [false, true] {
            let idle = MenuButtonStyle.backgroundOpacity(enabled: true, hovered: false, pressed: false, selected: selected)
            let hover = MenuButtonStyle.backgroundOpacity(enabled: true, hovered: true, pressed: false, selected: selected)
            let press = MenuButtonStyle.backgroundOpacity(enabled: true, hovered: true, pressed: true, selected: selected)
            let pressOutside = MenuButtonStyle.backgroundOpacity(enabled: true, hovered: false, pressed: true, selected: selected)
            try check([idle, hover, press, pressOutside].allSatisfy { $0.isFinite && (0...1).contains($0) },
                      "button background opacity stays within its valid range")
            try check(hover > 0 && hover >= idle, "hover visibly highlights enabled buttons")
            try check(press > hover && pressOutside > idle, "pressed buttons visibly exceed the hover background")
        }
        try check(MenuButtonStyle.backgroundOpacity(enabled: true, hovered: false, pressed: false, selected: false) == 0,
                  "unselected idle buttons have no background")
        try check(MenuButtonStyle.backgroundOpacity(enabled: true, hovered: false, pressed: false, selected: true) > 0,
                  "selected settings button remains highlighted without hover")
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    static func clickTests() throws {
        let popover = window(), status = window(), other = window()
        defer { popover.close(); status.close(); other.close() }
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            for (target, outside) in [(Optional(popover), false), (Optional(status), false), (Optional(other), true), (nil, true)] {
                guard let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: target?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                else { throw Failure(description: "cannot create fixture mouse event") }
                if let target { try check(event.window === target, "fixture event resolves to its hidden window") }
                else { try check(event.window == nil, "fixture windowless event stays windowless") }
                try check(clickIsOutsidePopover(event, popoverWindow: popover, statusWindow: status) == outside,
                          "outside-click classification for \(type), window \(target?.windowNumber ?? 0)")
                if outside {
                    try check(clickIsOutsidePopover(event, popoverWindow: nil, statusWindow: nil),
                              "missing panel/status windows do not suppress outside clicks")
                }
            }
        }
        try check(!popover.isVisible && !status.isVisible && !other.isVisible,
                  "event tests never display fixture windows")
    }

    static func iconTests() throws {
        let icon = potetoIcon()
        try check(icon.size.width > 0 && icon.size.height > 0 && !icon.isTemplate,
                  "alert icon factory produces a full-color image")
        guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(description: "cannot rasterize the fixture potato icon")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var visible = 0, brown = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                visible += 1
                if color.redComponent > color.greenComponent && color.greenComponent > color.blueComponent { brown += 1 }
            }
        }
        let area = bitmap.pixelsWide * bitmap.pixelsHigh
        try check(visible > area / 20 && brown > area / 40, "potato icon contains visible brown emoji pixels")
        let alert = NSAlert()
        alert.icon = icon
        try check(alert.icon === icon, "a self-contained NSAlert retains the explicit potato icon")
        // The production alert method is private and modal; its presentation is not invoked here.
    }

    static func themeTests() throws -> [DesktopTheme] {
        let fixture = """
        [desktop]
        appearanceTheme = "system"
        appearanceLightChromeTheme = {surface = "#f3eee3", ink = "#2b2924", accent = "#d97857", ui = "-apple-system"}
        appearanceDarkChromeTheme = {surface = "#202020", ink = "#eeeeee", accent = "#123456", ui = "Menlo"}
        """
        guard let light = DesktopTheme.parse(fixture, systemDark: false),
              let dark = DesktopTheme.parse(fixture, systemDark: true) else {
            throw Failure(description: "cannot parse fixture themes")
        }
        for (theme, colors, font, isDark) in [
            (light, ["#f3eee3", "#2b2924", "#d97857"], "-apple-system", false),
            (dark, ["#202020", "#eeeeee", "#123456"], "Menlo", true)
        ] {
            for (actual, hex) in zip([theme.surface, theme.ink, theme.accent], colors) {
                try check(actual.isEqual(DesktopTheme.hex(hex)!), "theme preserves its fixture color \(hex)")
            }
            try check(theme.dark == isDark && theme.uiFont == font, "theme preserves appearance and font")
        }
        let explicitLight = fixture.replacingOccurrences(of: "appearanceTheme = \"system\"", with: "appearanceTheme = \"light\"")
        try check(DesktopTheme.parse(explicitLight, systemDark: true)?.surface.isEqual(light.surface) == true,
                  "explicit light appearance overrides the system appearance")
        let nested = """
        [desktop]
        appearanceTheme = "dark"
        [desktop.appearanceDarkChromeTheme]
        surface = "#202020"
        ink = "#eeeeee"
        accent = "#123456"
        """
        try check(DesktopTheme.parse(nested, systemDark: false)?.accent.isEqual(dark.accent) == true,
                  "nested theme fields remain supported")
        try check(DesktopTheme.parse("[desktop]\nappearanceLightChromeTheme = {surface = \"unsafe\"}", systemDark: false) == nil,
                  "invalid themes remain rejected")
        return [light, dark]
    }

    static func boundsTests() throws {
        let normal = PanelBounds.fitting(width: 1440, height: 900)
        try check(normal == PanelBounds(width: 380, maximumHeight: 600, listHeight: 360),
                  "normal screen keeps the existing popover bounds")
        for settings in [false, true] {
            for error in [false, true] {
                let small = PanelBounds.fitting(width: 360, height: 480, settings: settings, error: error)
                let reserved: CGFloat = 218 + (settings ? 44 : 0) + (error ? 44 : 0)
                try check(small.width == 336 && small.maximumHeight == 448 && small.listHeight == 448 - reserved,
                          "small screen reserves space for settings=\(settings), error=\(error)")
            }
        }
        let tiny = PanelBounds.fitting(width: 10, height: 20, settings: true, error: true)
        try check(tiny.width == 1 && tiny.maximumHeight == 1 && tiny.listHeight == 0,
                  "tiny screen bounds stay nonnegative")
        let state = PanelState()
        state.availableScreenSize = NSSize(width: 360, height: 480)
        state.snapshot = fixtureSnapshot(error: "Fixture error")
        state.settings = true
        try check(state.bounds == PanelBounds.fitting(width: 360, height: 480, settings: true, error: true),
                  "PanelState forwards screen size, settings, and error to bounds")
    }

    static func layout(_ hosting: NSHostingView<PotetoPanel>, in window: NSWindow, state: PanelState) throws -> NSSize {
        // Settle observable-state layout; this does not measure animation frames or display the window.
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        try check(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0,
                  "hosted panel has a finite nonempty layout")
        try check(abs(size.width - state.bounds.width) <= 1 && size.height <= state.bounds.maximumHeight + 1,
                  "hosted panel fits its width and visible-screen height")
        window.setContentSize(size)
        hosting.frame = window.contentView!.bounds
        hosting.layoutSubtreeIfNeeded()
        return size
    }

    static func scrollIndicatorTests(_ hosting: NSView, state: PanelState) throws {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
        }
        let scrolls = scrollViews(hosting)
        try check(scrolls.count == 1, "account list retains one native scroll view")
        guard let scroll = scrolls.first, let document = scroll.documentView else {
            throw Failure(description: "account list has no native scroll document")
        }
        let needsScrolling = document.frame.height > state.bounds.listHeight + 1
        try check(scroll.hasVerticalScroller == needsScrolling,
                  "native indicator is enabled only for content exceeding the stable list limit")
        if needsScrolling {
            try check(document.frame.height > scroll.contentView.bounds.height + 1,
                      "small-screen or multi-account overflow retains a real scroll range")
        }
    }

    static func hostingTests(_ themes: [DesktopTheme]) throws {
        for theme in themes {
            for screen in [NSSize(width: 1440, height: 900), NSSize(width: 360, height: 480)] {
                let state = PanelState()
                state.theme = theme
                state.snapshot = fixtureSnapshot(accountCount: 8)
                state.availableScreenSize = screen
                state.startup = false
                var startupCalls = 0, unexpectedActions = 0
                let panel = PotetoPanel(state: state, refresh: { unexpectedActions += 1 }, addAccount: { unexpectedActions += 1 },
                    switchAccount: { _ in unexpectedActions += 1 }, forget: { _ in unexpectedActions += 1 },
                    toggleStart: { startupCalls += 1; state.startup.toggle() }, quit: { unexpectedActions += 1 })
                let hosting = NSHostingView(rootView: panel)
                hosting.sizingOptions = [.intrinsicContentSize]
                let window = window()
                defer { window.close() }
                let container = window.contentView!
                container.addSubview(hosting)
                hosting.frame = container.bounds
                let closed = try layout(hosting, in: window, state: state)
                try scrollIndicatorTests(hosting, state: state)
                // Hidden hosts expose no AX children here; exercise observable state without AX or real UI events.
                state.settings = true
                let opened = try layout(hosting, in: window, state: state)
                try scrollIndicatorTests(hosting, state: state)
                try check(state.settings && opened.width == closed.width,
                          "opening settings preserves panel width")
                try check(window.contentView === container && hosting.superview === container &&
                          container.subviews.count == 1 && container.subviews.first === hosting && hosting.rootView.state === state,
                          "settings keep the hosting root, container, and observed state identities")
                panel.toggleStart()
                let startup = try layout(hosting, in: window, state: state)
                try check(state.startup && startupCalls == 1 && abs(startup.height - opened.height) <= 1,
                          "fixture startup toggle updates state without changing settings dimensions")
                state.previewAccount("fixture-0")
                _ = try layout(hosting, in: window, state: state)
                try scrollIndicatorTests(hosting, state: state)
                try check(state.detailAccountID == "fixture-0" && state.settings && state.startup,
                          "account hover and settings can coexist")
                state.clearAccountPreview()
                for (refreshing, busy, loginRunning) in [(true, false, false), (false, true, false), (false, false, true)] {
                    let snapshot = fixtureSnapshot(accountCount: 8, error: "Fixture error")
                    state.snapshot = Snapshot(accounts: snapshot.accounts, refreshing: refreshing,
                                              error: snapshot.error, loginRunning: loginRunning)
                    state.busy = busy
                    _ = try layout(hosting, in: window, state: state)
                    try scrollIndicatorTests(hosting, state: state)
                }
                state.snapshot = fixtureSnapshot(accountCount: 8)
                state.busy = false
                state.settings = false
                let restored = try layout(hosting, in: window, state: state)
                try scrollIndicatorTests(hosting, state: state)
                try check(abs(restored.width - closed.width) <= 1 && abs(restored.height - closed.height) <= 1,
                          "closing settings restores the original panel dimensions")
                try check(window.contentView === container && hosting.superview === container && hosting.rootView.state === state,
                          "closing settings preserves root and container identities")
                try check(state.theme.surface.isEqual(theme.surface) && state.theme.ink.isEqual(theme.ink) &&
                          state.theme.accent.isEqual(theme.accent) && state.theme.uiFont == theme.uiFont,
                          "settings and account interaction preserve the selected theme")
                try check(unexpectedActions == 0 && !window.isVisible,
                          "fixture never invokes external actions or displays a window")
                print("poteto: hidden \(theme.dark ? "dark" : "light") fixture \(Int(screen.width))×\(Int(screen.height)): " +
                      "settings \(Int(closed.height))→\(Int(opened.height))→\(Int(restored.height)) pt")
            }
        }
    }

    static func main() async {
        do {
            _ = NSApplication.shared
            try subscriptionTests()
            try previewTests()
            try await hoverTimingTests()
            try buttonTests()
            try clickTests()
            try iconTests()
            let themes = try themeTests()
            try boundsTests()
            try hostingTests(themes)
            print("poteto: \(checks) panel interaction/theme/bounds checks passed")
            print("poteto: fixture state/layout/identity checked; AX button presses and disclosure-arrow visibility were not measured")
            print("poteto: animation smoothness, real event-monitor delivery, and production modal alerts were not measured")
        } catch {
            fputs("poteto: panel interaction test failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
