import AppKit
import SwiftUI
import Combine
import Darwin

actor PresentationUsage {
    private(set) var reads = 0
    private var remaining: Double = 71
    private var paused = false
    private var waiting: CheckedContinuation<Void, Never>?
    func configure(remaining: Double, paused: Bool = false) {
        self.remaining = remaining; self.paused = paused
    }
    func read() async -> Usage {
        reads += 1
        if paused { await withCheckedContinuation { waiting = $0 } }
        return Usage(plan: "pro", windows: [
            UsageWindow(label: "Codex", durationMinutes: 300, remaining: remaining, reset: nil, ordinary: true)
        ], checkedAt: Date())
    }
    func waitForRead() async { while waiting == nil { await Task.yield() } }
    func release() { paused = false; waiting?.resume(); waiting = nil }
}

@main
@MainActor
struct PresentationTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        checks += 1
    }
    static func auth(_ index: Int) throws -> AuthBundle {
        let claims: [String: Any] = ["email": "account-\(index)@example.invalid", "sub": "fixture-\(index)",
            "https://api.openai.com/auth": ["chatgpt_account_id": "fixture-\(index)", "chatgpt_plan_type": "pro"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return AuthBundle(data: try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
            "id_token": "e30.\(payload).c2ln", "access_token": "fixture-access", "refresh_token": "fixture-refresh",
            "account_id": "fixture-\(index)"]]))
    }
    static func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
    }
    static func drain(_ seconds: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    static func geometry(_ delegate: AppDelegate) throws -> NSSize {
        let state = delegate.presentationState, popover = delegate.presentationPopover
        guard let controller = popover.contentViewController as? PanelHostingController else {
            throw Failure(description: "preparation did not create the real panel controller")
        }
        let size = controller.preferredContentSize
        try check(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0,
                  "preparation synchronously produces finite nonempty geometry")
        try check(abs(size.width - state.bounds.width) < 1 && size.height <= state.bounds.maximumHeight + 1,
                  "pre-show geometry fits the latest screen: size=\(size), bounds=\(state.bounds)")
        try check(popover.contentSize == size && state.presentationViewportHeight == size.height,
                  "viewport, preferred size and popover size agree before show")
        try check(abs(controller.view.frame.width - size.width) < 1 && abs(controller.view.frame.height - size.height) < 1,
                  "retained host frame matches the prepared size")
        let referenceState = PanelState()
        referenceState.snapshot = state.snapshot; referenceState.theme = state.theme
        referenceState.settings = state.settings; referenceState.availableScreenSize = state.availableScreenSize
        let reference = NSHostingView(rootView: PotetoPanel(state: referenceState, refresh: {}, addAccount: {},
            switchAccount: { _ in }, forget: { _ in }, toggleStart: {}, quit: {}))
        reference.frame.size.width = state.bounds.width
        reference.layoutSubtreeIfNeeded()
        let natural = reference.fittingSize
        try check(abs(natural.width - size.width) < 1 && abs(natural.height - size.height) < 1,
                  "pre-show geometry matches unconstrained fresh content, not the previous viewport")
        controller.animatesSizeChanges = true
        drain(0.03)
        try check(controller.preferredContentSize == size && !controller.presentationHasSizeAnimation,
                  "late layout after enabling shown-state animation does not resize the prepared first frame")
        controller.stopSizeAnimation()
        try check(!popover.isShown && controller.view.window?.isVisible != true,
                  "preparation does not show a panel window")
        return size
    }
    static func run() async throws {
        let app = NSApplication.shared
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("poteto-presentation-\(UUID().uuidString)")
        try PrivateFiles.directory(home)
        let auths = try (0..<3).map(auth)
        var vault = Vault()
        for (index, auth) in auths.enumerated() { try vault.put(auth, fromNative: index == 0) }
        let authURL = home.appendingPathComponent("fixture-auth.json"), statusURL = home.appendingPathComponent("status.json")
        try PrivateFiles.write(auths[0].data, to: authURL)
        let usage = PresentationUsage()
        var saves = 0, renewals = 0, safetyReads = 0
        let monitor = Monitor(authURL: authURL, statusURL: statusURL, load: { vault }, save: { _ in saves += 1 },
            read: { _ in await usage.read() }, renew: { auth in renewals += 1; return auth },
            running: { safetyReads += 1; return false })
        let delegate = AppDelegate(monitor: monitor)
        var nativeReads = 0, startupReads = 0, screenReads = 0, themeReads = 0
        var nativeRunning = false, startup = false
        var screen = NSSize(width: 1440, height: 900)
        var theme = DesktopTheme(surface: DesktopTheme.hex("#f3eee3")!, ink: DesktopTheme.hex("#2b2924")!,
                                 accent: DesktopTheme.hex("#d97857")!, uiFont: nil)
        delegate.configurePresentation(theme: { themeReads += 1; return theme },
            nativeRunning: { nativeReads += 1; return nativeRunning },
            startup: { startupReads += 1; return startup }, screen: { screenReads += 1; return screen })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let statusWindow = delegate.presentationStatusWindow
        delegate.hidePresentationStatusItem()
        try check(delegate.presentationPopover.contentViewController == nil, "startup leaves the host absent")
        await delegate.presentationRefreshTask?.value
        func quota(_ snapshot: Snapshot, _ expected: Double) -> Bool {
            snapshot.accounts.count == 3 && !snapshot.refreshing && snapshot.accounts.allSatisfy {
                $0.usage?.ordinaryRemaining == expected && $0.error == nil
            }
        }
        try check(quota(delegate.presentationLatest, 71) && delegate.presentationTitle == "🥔 71%",
                  "hidden startup completes all three quotas and updates the status title")
        try check(quota(try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: statusURL)), 71),
                  "hidden startup writes complete three-account status")
        await usage.configure(remaining: 62)
        delegate.refreshPresentation(); await delegate.presentationRefreshTask?.value
        try check(await usage.reads == 6 && quota(delegate.presentationLatest, 62) && delegate.presentationTitle == "🥔 62%",
                  "hidden force refresh bypasses throttling for all three accounts")
        try check(delegate.presentationPopover.contentViewController == nil && nativeReads + startupReads + screenReads + themeReads == 0,
                  "hidden refreshes neither create a host nor read presentation environment")
        let state = delegate.presentationState
        try check(state.snapshot.accounts.isEmpty, "hidden startup does not publish presentation data")
        var publications = 0
        let observation = state.objectWillChange.sink { _ in publications += 1 }
        state.settings = true; state.startupChanging = true
        delegate.setPresentationBusy(true)
        nativeRunning = true; startup = true; screen = NSSize(width: 800, height: 500)
        let errorSnapshot = Snapshot(accounts: delegate.presentationLatest.accounts, refreshing: true,
                                     error: "Fixture pending operation", loginRunning: true)
        delegate.receivePresentation(errorSnapshot)
        delegate.preparePresentation()
        try check(state.snapshot.accounts.count == 3 && state.snapshot.refreshing && state.snapshot.loginRunning &&
                  state.snapshot.error == errorSnapshot.error && state.busy && state.nativeRunning && state.startup && state.startupChanging &&
                  state.theme.surface.isEqual(theme.surface) && state.theme.ink.isEqual(theme.ink),
                  "first preparation projects latest accounts, errors and all busy inputs")
        try check(state.settings && state.bounds == PanelBounds(width: 380, maximumHeight: 468, listHeight: 162),
                  "first preparation retains settings and fits the fresh screen with an error")
        let first = try geometry(delegate)
        let controller = delegate.presentationPopover.contentViewController as! PanelHostingController
        let hosting = controller.view as! NSHostingView<PotetoPanel>
        let scroll = scrolls(hosting).first
        try check(scroll != nil && hosting.rootView.state === state, "first host owns the retained state and a real scroll view")
        delegate.setPresentationBusy(false)
        await usage.configure(remaining: 53)
        let publishedBeforeRefresh = publications
        let readsBeforeRefresh = nativeReads + startupReads + screenReads + themeReads
        delegate.refreshPresentation(); await delegate.presentationRefreshTask?.value
        try check(quota(delegate.presentationLatest, 53) && delegate.presentationTitle == "🥔 53%" &&
                  quota(try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: statusURL)), 53),
                  "hidden refresh after preparation still updates latest, title and disk status")
        try check(publications == publishedBeforeRefresh && nativeReads + startupReads + screenReads + themeReads == readsBeforeRefresh &&
                  state.snapshot.error == errorSnapshot.error && state.snapshot.accounts[0].usage?.ordinaryRemaining == 62,
                  "hidden refresh leaves retained presentation untouched until preparation")
        theme = DesktopTheme(surface: DesktopTheme.hex("#202020")!, ink: DesktopTheme.hex("#eeeeee")!,
                             accent: DesktopTheme.hex("#123456")!, uiFont: "Menlo")
        nativeRunning = false; startup = false; screen = NSSize(width: 360, height: 480)
        state.startupChanging = false
        delegate.preparePresentation()
        try check(quota(state.snapshot, 53) && !state.busy && !state.nativeRunning && !state.startup && !state.startupChanging &&
                  state.theme.dark && state.theme.uiFont == "Menlo" && state.theme.accent.isEqual(theme.accent),
                  "reopening refreshes quota, controls and theme synchronously")
        let reopened = try geometry(delegate)
        try check(reopened.width == 336 && first.width == 380 && abs(first.height - reopened.height) > 1,
                  "reopening replaces old width and height before show")
        try check(delegate.presentationState === state && delegate.presentationPopover.contentViewController === controller &&
                  controller.view === hosting && hosting.rootView.state === state && scrolls(hosting).first === scroll && state.settings,
                  "reopening retains state, controller, root host, scroll view and settings")
        state.toggleAccountDetails(state.snapshot.accounts[0].id)
        state.hoverAccount(state.snapshot.accounts[1].id, inside: true)
        let popoverAnimation = delegate.presentationPopover.animates
        controller.animatesSizeChanges = true
        hosting.rootView.reportSize(NSSize(width: reopened.width, height: reopened.height + 30))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try check(controller.presentationHasSizeAnimation, "fixture starts the real size animation before close")
        }
        await usage.configure(remaining: 44, paused: true)
        delegate.refreshPresentation(); await usage.waitForRead()
        delegate.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        delegate.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        try check(!controller.presentationHasSizeAnimation && !controller.animatesSizeChanges && state.detailAccountID == nil && state.settings &&
                  delegate.presentationPopover.animates == popoverAnimation,
                  "close cancels animation and previews while preserving settings")
        hosting.rootView.reportSize(NSSize(width: reopened.width, height: reopened.height + 25))
        try check(!controller.presentationHasSizeAnimation, "a late geometry callback after close cannot start a hidden animation")
        await usage.release(); await delegate.presentationRefreshTask?.value
        drain()
        try check(state.detailAccountID == nil && !controller.presentationHasSizeAnimation,
                  "late geometry and hover callbacks after close do not revive animation or preview")
        state.clearAccountPreview()
        try check(state.detailAccountID == nil, "close also clears the pinned preview")
        screen = NSSize(width: 800, height: 500)
        delegate.preparePresentation()
        let final = try geometry(delegate)
        try check(quota(state.snapshot, 44) && controller.view === hosting && state.settings,
                  "late refresh is projected on the same host at reopen")
        drain()
        try check(delegate.presentationPopover.contentSize == final && !controller.presentationHasSizeAnimation,
                  "late callbacks leave reopened geometry finite and stable")
        try check(nativeReads == 3 && startupReads == 3 && screenReads == 3 && themeReads == 3,
                  "each explicit preparation reads fresh presentation inputs once")
        try check(await usage.reads == 12, "preparation never adds quota or Monitor reads")
        try check(saves == 0 && renewals == 0 && safetyReads == 0 && (try Data(contentsOf: authURL)) == auths[0].data,
                  "presentation and refresh do not renew, save or switch fixture credentials")
        try check(!app.windows.contains { $0 !== statusWindow && $0.isVisible }, "fixture never displays content windows")
        observation.cancel()
        try await delegate.finishPresentationFixture()
        print("poteto: \(checks) lazy presentation/fresh geometry/lifecycle checks passed")
        print("poteto: real AppDelegate + PanelHostingController, three fake accounts, no activation or visible content windows")
    }
    static func main() async {
        do { try await run() }
        catch { fputs("poteto: presentation test failed: \(error)\n", stderr); exit(1) }
    }
}
