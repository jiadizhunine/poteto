import AppKit
import SwiftUI
import Foundation
import Darwin

let supportURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/poteto", isDirectory: true)
let nativeHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
let nativeAuthURL = nativeHome.appendingPathComponent("auth.json")
let launchLabel = "io.poteto.menubar"

struct AccountView: Codable, Sendable {
    let id: String
    let email: String
    let workspace: String
    let current: Bool
    let plan: String?
    let usage: Usage?
    let error: String?
    var activationNote: String? = nil
    var subscriptionTitle: String {
        guard let value = safeLabel(usage?.plan ?? plan, max: 60) else { return "待确认" }
        return ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "team": "Team",
                "business": "Business", "enterprise": "Enterprise", "edu": "Edu"][value.lowercased()] ?? value
    }
}
struct Snapshot: Codable, Sendable {
    let accounts: [AccountView]
    let refreshing: Bool
    let error: String?
    let loginRunning: Bool
}

actor Monitor {
    private let authURL: URL
    private let statusURL: URL
    private let activationURL: URL
    private let runActivation: @Sendable (AuthBundle, ActivationCancellation) async -> Bool
    private var activationTask: Task<Bool, Never>?
    private var readbackTask: Task<Usage?, Never>?
    private var activationCancellation: ActivationCancellation?
    private let loadVault: () throws -> Vault
    private let saveVault: (Vault) throws -> Void
    private let readUsage: (AuthBundle) async throws -> Usage
    private let readbackUsage: (AuthBundle) async throws -> Usage
    private let renewAuth: (AuthBundle) async throws -> AuthBundle
    private let isNativeRunning: () -> Bool
    private var vault = Vault()
    private var loaded = false
    private var usages: [String: Usage] = [:]
    private var errors: [String: String] = [:]
    private var activationNotes: [String: String] = [:]
    private var currentID: String?
    private var refreshing = false
    private var switching = false
    private var closing = false
    private var dirty = false
    private var loginRunning = false
    private var lastAttempt = Date.distantPast
    private var lastError: String?

    init(authURL: URL = nativeAuthURL, statusURL: URL = supportURL.appendingPathComponent("status.json"),
         load: @escaping () throws -> Vault = { try CredentialStore.load() },
         save: @escaping (Vault) throws -> Void = CredentialStore.save,
         read: ((AuthBundle) async throws -> Usage)? = nil,
         readback: ((AuthBundle) async throws -> Usage)? = nil,
         renew: @escaping (AuthBundle) async throws -> AuthBundle = OfficialHTTP.refresh,
         running: @escaping () -> Bool = nativeClientIsRunning,
         activationURL: URL? = nil,
         activate: @escaping @Sendable (AuthBundle, ActivationCancellation) async -> Bool = { auth, cancellation in
             await Task.detached(priority: .utility) { (try? NativeActivation.run(auth: auth, cancellation: cancellation)) != nil }.value
         }) {
        self.authURL = authURL; self.statusURL = statusURL
        self.activationURL = activationURL ?? statusURL.deletingLastPathComponent().appendingPathComponent("activation.json")
        self.runActivation = activate; loadVault = load; saveVault = save
        readUsage = read ?? OfficialHTTP.readUsage
        readbackUsage = readback ?? read ?? OfficialHTTP.readUsageOnly
        renewAuth = renew; isNativeRunning = running
    }
    private func flush() throws {
        if dirty { try saveVault(vault); dirty = false }
    }

    private func capture() throws {
        if !loaded { vault = try loadVault(); loaded = true }
        try flush()
        currentID = nil
        if let data = try PrivateFiles.read(authURL) {
            let auth = AuthBundle(data: data)
            // API-key/native logout documents are not imported as official accounts.
            if let identity = try? auth.identity {
                currentID = identity.id
                var candidate = vault
                try candidate.put(auth, fromNative: true)
                if candidate != vault { try saveVault(candidate); vault = candidate }
            }
        }
    }
    private func view() -> Snapshot {
        let accounts = vault.accounts.compactMap { saved -> AccountView? in
            guard let identity = try? saved.auth.identity else { return nil }
            return AccountView(id: identity.id, email: identity.email, workspace: identity.workspace,
                               current: identity.id == currentID, plan: identity.plan,
                               usage: usages[identity.id], error: errors[identity.id], activationNote: activationNotes[identity.id])
        }.sorted { ($0.current ? 0 : 1, $0.email) < ($1.current ? 0 : 1, $1.email) }
        return Snapshot(accounts: accounts, refreshing: refreshing, error: lastError, loginRunning: loginRunning)
    }
    func snapshot() -> Snapshot {
        if refreshing || switching || loginRunning || closing { return view() }
        do { try capture(); lastError = nil } catch { lastError = publicError(error) }
        return view()
    }
    private func currentFileID() throws -> String? {
        guard let data = try PrivateFiles.read(authURL) else { return nil }
        return try? AuthBundle(data: data).identity.id
    }
    private func usable(_ initial: AuthBundle, mayRefresh: Bool) async throws -> (AuthBundle, Usage) {
        try flush()
        do { return (initial, try await readUsage(initial)) }
        catch PotetoError.loginRequired {
            let id = try initial.identity.id
            // Never compete with the native auth owner for the current refresh token.
            guard mayRefresh, try currentFileID() != id else { throw PotetoError.loginRequired }
            let renewed = try await renewAuth(initial)
            try vault.put(renewed); dirty = true; try flush()
            guard try currentFileID() != id else { throw PotetoError.changed }
            return (renewed, try await readUsage(renewed))
        }
    }
    private func hasDisplayedReset(_ usage: Usage, record: ActivationLedger.Record?) -> Bool {
        guard let record, let observation = usage.activation, observation.slot == record.slot,
              observation.duration == record.duration, let reset = observation.absoluteReset else { return false }
        return usage.windows.contains { $0.ordinary && $0.durationMinutes * 60 == record.duration && $0.reset == reset }
    }
    func refresh(force: Bool = false, progress: (@Sendable (Snapshot) async -> Void)? = nil) async -> Snapshot {
        if refreshing || switching || loginRunning || closing { return view() }
        do { try capture(); lastError = nil } catch {
            lastError = publicError(error)
            try? PrivateFiles.write(JSONEncoder().encode(view()), to: statusURL)
            return view()
        }
        if !force && Date().timeIntervalSince(lastAttempt) < 290 { return view() }
        refreshing = true; lastAttempt = Date()
        for account in vault.accounts {
            if closing { break }
            guard let identity = try? account.auth.identity else { continue }
            do {
                let (auth, usage) = try await usable(account.auth, mayRefresh: identity.id != currentID)
                guard !closing else { break }
                usages[identity.id] = usage; errors[identity.id] = nil
                await progress?(view())
                guard !closing, let observation = usage.activation else { continue }
                do {
                    try PrivateFiles.write(JSONEncoder().encode(view()), to: statusURL)
                    var ledger = try ActivationLedger.load(activationURL)
                    let claim = ledger.observe(observation, id: identity.id, now: Date())
                    try ledger.save(activationURL)
                    if activationNotes[identity.id] != nil && hasDisplayedReset(usage, record: ledger.accounts[identity.id]) {
                        activationNotes[identity.id] = nil
                        await progress?(view())
                        guard !closing else { break }
                    }
                    if claim && !closing {
                        activationNotes[identity.id] = "正在激活首次额度。"
                        await progress?(view())
                        guard !closing else { break }
                        let cancellation = ActivationCancellation(); activationCancellation = cancellation
                        let run = runActivation
                        let task = Task { await run(auth, cancellation) }; activationTask = task
                        let succeeded = await task.value
                        activationNotes[identity.id] = hasDisplayedReset(usage, record: ledger.accounts[identity.id]) ? nil :
                            (succeeded ? "等待官方额度重置时间。" : "首次额度激活未完成，本周期不会自动重试。")
                        activationTask = nil; activationCancellation = nil
                        if var record = ledger.accounts[identity.id] {
                            record.outcome = succeeded ? .completed : .failed
                            ledger.accounts[identity.id] = record
                            try? ledger.save(activationURL)
                        }
                        if !closing { await progress?(view()) }
                        for readIndex in 0..<2 {
                            if readIndex == 1 {
                                for _ in 0..<20 {
                                    if closing { break }
                                    try? await Task.sleep(for: .milliseconds(100))
                                }
                            }
                            guard !closing else { break }
                            let read = readbackUsage
                            let task = Task { try? await read(auth) }; readbackTask = task
                            let result = await task.value; readbackTask = nil
                            guard !closing else { break }
                            if var readback = result {
                                if let current = usages[identity.id]?.resetAllowance, let fresh = readback.resetAllowance,
                                   current.availableCount == fresh.availableCount, current.applicableCount == fresh.applicableCount,
                                   fresh.credits == nil, let credits = current.credits {
                                    let kept = credits.filter { credit in
                                        guard let expiry = credit.expiresAt, let server = readback.activation?.serverTime else { return true }
                                        return expiry > server
                                    }
                                    readback.resetAllowance = ResetAllowance(availableCount: fresh.availableCount,
                                        applicableCount: fresh.applicableCount, credits: kept)
                                }
                                usages[identity.id] = readback
                                if let observed = readback.activation {
                                    _ = ledger.observe(observed, id: identity.id, now: Date())
                                    try? ledger.save(activationURL)
                                    if hasDisplayedReset(readback, record: ledger.accounts[identity.id]) { activationNotes[identity.id] = nil }
                                }
                                await progress?(view())
                                guard !closing else { break }
                            }
                        }
                    }
                } catch {
                    if observation.unstarted && observation.allUnused && observation.sendAllowed {
                        activationNotes[identity.id] = "首次额度激活暂不可用。"
                    }
                }

            } catch { errors[identity.id] = publicError(error) }
        }
        refreshing = false
        do {
            try capture()
            let data = try JSONEncoder().encode(view())
            try PrivateFiles.write(data, to: statusURL)
        } catch { lastError = publicError(error) }
        return view()
    }
    func switchAccount(_ id: String) async throws -> Snapshot {
        guard !refreshing && !switching && !loginRunning && !closing else { throw PotetoError.changed }
        switching = true; defer { switching = false }
        if isNativeRunning() { throw PotetoError.running }
        try capture()
        let before = try PrivateFiles.read(authURL)
        guard let saved = try vault.accounts.first(where: { try $0.auth.identity.id == id }) else { throw PotetoError.missingAccount }
        let (auth, usage) = try await usable(saved.auth, mayRefresh: id != currentID)
        // Recheck after network/auth preparation. There is no pending switch queue.
        if isNativeRunning() { throw PotetoError.running }
        guard try PrivateFiles.read(authURL) == before else { throw PotetoError.changed }
        try capture()
        guard try vault.accounts.first(where: { try $0.auth.identity.id == id })?.auth == auth else { throw PotetoError.changed }
        try withProjectStateLock(in: statusURL.deletingLastPathComponent()) {
            try activateAccount(auth, authURL: authURL, isRunning: isNativeRunning)
        }
        usages[id] = usage; errors[id] = nil
        try capture()
        return view()
    }
    func setLoginRunning(_ value: Bool) { loginRunning = value }
    func finishLogin(_ auth: AuthBundle) throws -> Snapshot {
        try capture(); try vault.put(auth); dirty = true; try flush()
        return view()
    }
    func forget(_ id: String) throws -> Snapshot {
        guard !refreshing && !switching && !loginRunning && !closing else { throw PotetoError.changed }
        try capture()
        if id == currentID { throw PotetoError.changed }
        var candidate = vault; candidate.accounts.removeAll { (try? $0.auth.identity.id) == id }
        try saveVault(candidate); vault = candidate; usages[id] = nil; errors[id] = nil; return view()
    }
    func prepareToQuit() async throws {
        closing = true
        activationCancellation?.cancel()
        activationTask?.cancel()
        readbackTask?.cancel()
        while refreshing || switching || loginRunning { try await Task.sleep(for: .milliseconds(100)) }
        do { try flush() } catch { closing = false; throw error }
    }
}

func publicError(_ error: Error) -> String { (error as? PotetoError)?.errorDescription ?? "操作未完成，请稍后重试；未输出私有凭据。" }

private func withProjectStateLock<T>(in directory: URL, _ operation: () throws -> T) throws -> T {
    let lock = try InstanceLock(directory.appendingPathComponent("project-state.lock"))
    return try withExtendedLifetime(lock, operation)
}

enum ProjectCommand {
    enum UsageError: LocalizedError {
        case invalidArguments
        var errorDescription: String? {
            "用法：--project-status [--codex-home PATH] 或 --restore-projects [--from SLOT] [--codex-home PATH]"
        }
    }

    static func run(_ arguments: [String], home: URL = nativeHome, support: URL = supportURL,
                    isRunning: () -> Bool = nativeClientIsRunning) throws -> Data? {
        guard let mode = arguments.first, ["--project-status", "--restore-projects"].contains(mode) else { return nil }
        var profile: URL?
        var source: String?
        var options = arguments.dropFirst().makeIterator()
        while let flag = options.next() {
            guard let value = options.next(), !value.hasPrefix("--") else { throw UsageError.invalidArguments }
            switch flag {
            case "--codex-home" where profile == nil && value.hasPrefix("/") && !value.contains("\0"):
                profile = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
            case "--from" where mode == "--restore-projects" && source == nil:
                guard let slot = safeLabel(value) else { throw UsageError.invalidArguments }
                source = slot
            default:
                throw UsageError.invalidArguments
            }
        }
        let auth = (profile ?? home).appendingPathComponent("auth.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if mode == "--project-status" {
            return try encoder.encode(ProjectRecovery.status(authURL: auth, isRunning: isRunning))
        }
        if isRunning() { throw PotetoError.running }
        try PrivateFiles.directory(support)
        return try withProjectStateLock(in: support) {
            let backups = support.appendingPathComponent("Project Recovery", isDirectory: true)
            let result = try ProjectRecovery.restore(authURL: auth, backupDirectory: backups, sourceSlot: source, isRunning: isRunning)
            return try encoder.encode(result)
        }
    }
}

func runCommand(_ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
}

enum LoginStart {
    static var plistURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist") }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func executable(bundle: URL, home: URL) throws -> URL {
        let allowed = [URL(fileURLWithPath: "/Applications/poteto.app"), home.appendingPathComponent("Applications/poteto.app")]
        guard allowed.contains(where: { $0.standardizedFileURL.path == bundle.standardizedFileURL.path }) else { throw PotetoError.privateFile }
        return bundle.appendingPathComponent("Contents/MacOS/poteto")
    }

    static func owned(_ data: Data, home: URL) throws {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["Label"] as? String == launchLabel,
              let args = value["ProgramArguments"] as? [String], args.count == 1 else { throw PotetoError.privateFile }
        let allowed = ["/Applications/poteto.app/Contents/MacOS/poteto", home.appendingPathComponent("Applications/poteto.app/Contents/MacOS/poteto").path]
        guard allowed.contains(args[0]) else { throw PotetoError.privateFile }
    }

    static func configure(_ on: Bool) throws {
        try configure(on, bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser,
                      plist: plistURL, command: runCommand)
    }

    static func configure(_ on: Bool, bundle: URL, home: URL, plist: URL, command: ([String]) -> Int32) throws {
        let executable = try executable(bundle: bundle, home: home)
        let domain = "gui/\(getuid())"
        if on && !FileManager.default.isExecutableFile(atPath: executable.path) { throw PotetoError.privateFile }
        let before = try PrivateFiles.snapshot(plist)
        if let data = try PrivateFiles.read(plist) {
            try owned(data, home: home)
            guard try PrivateFiles.snapshot(plist) == before else { throw PotetoError.changed }
        }
        if on {
            let payload: [String: Any] = ["Label": launchLabel, "ProgramArguments": [executable.path], "RunAtLoad": true,
                                          "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 30, "ProcessType": "Interactive",
                                          "LimitLoadToSessionType": "Aqua", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PrivateFiles.write(PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0), to: plist, expected: before, compare: true)
            guard command(["/bin/launchctl", "enable", "\(domain)/\(launchLabel)"]) == 0 else { throw PotetoError.privateFile }
            if command(["/bin/launchctl", "print", "\(domain)/\(launchLabel)"]) != 0 {
                guard command(["/bin/launchctl", "bootstrap", domain, plist.path]) == 0 else { throw PotetoError.privateFile }
            }
        } else if before != nil {
            guard try PrivateFiles.snapshot(plist) == before else { throw PotetoError.changed }
            guard command(["/bin/launchctl", "disable", "\(domain)/\(launchLabel)"]) == 0 else { throw PotetoError.privateFile }
            try FileManager.default.removeItem(at: plist)
        }
    }
}

@MainActor
func clickIsOutsidePopover(_ event: NSEvent, popoverWindow: NSWindow?, statusWindow: NSWindow?) -> Bool {
    guard let window = event.window else { return true }
    return window !== popoverWindow && window !== statusWindow
}

@MainActor
func potetoIcon() -> NSImage {
    if let url = Bundle.main.url(forResource: "poteto", withExtension: "icns"), let image = NSImage(contentsOf: url) {
        return image
    }
    // CLI/fixture launches do not have bundle resources; never fall back to the generic app icon.
    return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        let emoji = "🥔" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Apple Color Emoji", size: 105) ?? NSFont.systemFont(ofSize: 105)]
        let size = emoji.size(withAttributes: attributes)
        emoji.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: attributes)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor: Monitor
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let panel = PanelState()
    private var latest = Snapshot(accounts: [], refreshing: true, error: nil, loginRunning: false)
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var login: Process?
    private var loginHome: URL?
    private var loginTimeout: Task<Void, Never>?
    private var switching = false
    private var terminating = false
    private var signalSource: DispatchSourceSignal?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var startupTask: Task<Void, Never>?

#if POTETO_TEST
    private var presentationTheme: () -> DesktopTheme = DesktopTheme.load
    private var presentationNativeRunning: () -> Bool = nativeClientIsRunning
    private var presentationStartup: () -> Bool = { LoginStart.enabled }
    private var presentationScreen: (() -> NSSize)?
#endif

    init(monitor: Monitor = Monitor()) {
        self.monitor = monitor
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource?.setEventHandler { [weak self] in self?.requestTermination() }; signalSource?.resume()
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = potetoIcon()
        item = NSStatusBar.system.statusItem(withLength: 58)
        item.button?.title = "🥔"; item.button?.toolTip = "poteto"
        item.button?.target = self; item.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.delegate = self
        render(); refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 30
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func wake() { refresh() }
    private func refresh(force: Bool = false) {
        guard !terminating, refreshTask == nil, !switching, login == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            latest = await monitor.snapshot()
            guard !terminating else { refreshTask = nil; return }
            latest = Snapshot(accounts: latest.accounts, refreshing: true, error: latest.error, loginRunning: latest.loginRunning)
            updateTitle(); render()
            let result = await monitor.refresh(force: force) { [weak self] snapshot in
                await self?.publishProgress(snapshot)
            }
            guard !terminating else { refreshTask = nil; return }
            latest = result
            updateTitle(); render()
            refreshTask = nil
        }
    }
    private func publishProgress(_ snapshot: Snapshot) {
        guard !terminating else { return }
        latest = snapshot; updateTitle(); render()
    }
    private func preparePanelForShow() {
        (popover.contentViewController as? PanelHostingController)?.stopSizeAnimation()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
#if POTETO_TEST
            panel.theme = presentationTheme()
#else
            panel.theme = DesktopTheme.load()
#endif
            render(forOpening: true)
            if popover.contentViewController == nil {
                let hosting = PanelHostingController(rootView: PotetoPanel(state: panel,
                    refresh: { [weak self] in self?.refresh(force: true) },
                    addAccount: { [weak self] in self?.addOrCancel() },
                    switchAccount: { [weak self] id in let row = NSMenuItem(); row.representedObject = id; self?.switchAccount(row) },
                    forget: { [weak self] id in let row = NSMenuItem(); row.representedObject = id; self?.forget(row) },
                    toggleStart: { [weak self] in self?.toggleStart() }, quit: { [weak self] in self?.quit() }))
                hosting.popover = popover
                popover.contentViewController = hosting
            }
            (popover.contentViewController as? PanelHostingController)?.prepareForShow()
        }
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        preparePanelForShow()
        popover.appearance = NSAppearance(named: panel.theme.dark ? .darkAqua : .aqua)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Activate only on an explicit menu-bar click, not on background refresh/startup.
        // SwiftUI hover and keyboard focus need an active accessory app.
        NSApp.activate(ignoringOtherApps: true)
        if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        Task { [weak self] in
            guard let self else { return }
            latest = await monitor.snapshot(); updateTitle(); render()
        }
    }
    func popoverDidShow(_ notification: Notification) {
        (popover.contentViewController as? PanelHostingController)?.animatesSizeChanges = true
        stopPanelClickMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // A status-item popover can be shown while this accessory app is inactive.
        // Transient alone then misses clicks delivered to another application.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            if let self, clickIsOutsidePopover(event, popoverWindow: self.popover.contentViewController?.view.window, statusWindow: self.item.button?.window) {
                self.popover.performClose(nil)
            }
            return event
        }
    }
    func popoverWillClose(_ notification: Notification) {
        panel.cancelAccountHover()
        (popover.contentViewController as? PanelHostingController)?.stopSizeAnimation()
        stopPanelClickMonitors()
    }
    func popoverDidClose(_ notification: Notification) { panel.resetAccountPreview() }
    private func stopPanelClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil; globalClickMonitor = nil
    }
    private func updateTitle() {
        let current = latest.accounts.first(where: \.current)
        if let account = current, account.error == nil, let usage = account.usage,
           Date().timeIntervalSince(usage.checkedAt) < 600, let left = usage.ordinaryRemaining {
            item.button?.title = "🥔 \(Int(left.rounded()))%"
        } else { item.button?.title = latest.error != nil || current?.error != nil ? "🥔 !" : "🥔" }
    }
    private func render(forOpening: Bool = false) {
        guard popover.isShown || forOpening else { return }
#if POTETO_TEST
        panel.snapshot = latest; panel.nativeRunning = presentationNativeRunning()
        panel.busy = switching; panel.startup = presentationStartup()
        if let screen = presentationScreen?() {
            panel.availableScreenSize = screen
        } else if let screen = item.button?.window?.screen ?? NSScreen.main {
            panel.availableScreenSize = screen.visibleFrame.size
        }
#else
        panel.snapshot = latest; panel.nativeRunning = nativeClientIsRunning()
        panel.busy = switching; panel.startup = LoginStart.enabled
        if let screen = item.button?.window?.screen ?? NSScreen.main {
            panel.availableScreenSize = screen.visibleFrame.size
        }
#endif
    }
    private func alert(_ message: String, detail: String, confirm: String? = nil) -> Bool {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let box = NSAlert(); box.messageText = message; box.informativeText = detail
        box.icon = potetoIcon()
        if let confirm { box.addButton(withTitle: confirm); box.addButton(withTitle: "取消"); box.buttons[1].keyEquivalent = "\r"; box.buttons[0].keyEquivalent = "" }
        else { box.addButton(withTitle: "好") }
        box.window.appearance = NSAppearance(named: panel.theme.dark ? .darkAqua : .aqua)
        for button in box.buttons { button.bezelColor = panel.theme.surface; button.contentTintColor = panel.theme.ink }
        return box.runModal() == .alertFirstButtonReturn
    }
    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let account = latest.accounts.first(where: { $0.id == id }) else { return }
        if nativeClientIsRunning() { _ = alert("未切换", detail: PotetoError.running.errorDescription!); return }
        guard alert("切换到 \(account.email)？", detail: "", confirm: "确认切换") else { return }
        switching = true
        Task {
            do { latest = try await monitor.switchAccount(id) }
            catch { _ = alert("切换未完成", detail: publicError(error)) }
            switching = false; updateTitle(); render()
        }
    }
    @objc private func forget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard alert("从 poteto 移除此账号？", detail: "", confirm: "移除") else { return }
        Task { do { latest = try await monitor.forget(id); render() } catch { _ = alert("未移除", detail: publicError(error)) } }
    }
    @objc private func toggleStart() {
        guard !terminating, startupTask == nil else { return }
        let enabled = !panel.startup
        panel.startupChanging = true
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                // launchctl waits for a subprocess; keep that wait off AppKit's event/render queue.
                try await Task.detached { try LoginStart.configure(enabled) }.value
                panel.startup = LoginStart.enabled
            } catch { _ = alert("自启动设置未更改", detail: publicError(error)) }
            panel.startupChanging = false; startupTask = nil
        }
    }
    @objc private func quit() {
        guard alert("退出？", detail: "不退出 ChatGPT，不改变登录。", confirm: "退出") else { return }
        requestTermination()
    }
    private func requestTermination() {
        // AppKit's terminateLater loop must not hold the main dispatch queue needed by the drain task.
        RunLoop.main.perform { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true; stopLogin()
        Task {
            await startupTask?.value
            while login != nil { try? await Task.sleep(for: .milliseconds(100)) }
            do { try await monitor.prepareToQuit(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                terminating = false; _ = alert("尚未退出", detail: "账号续期尚未保存到钥匙串，请解锁后重试。退出前会保留最新凭据。")
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); stopPanelClickMonitors()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    @objc private func addOrCancel() {
        guard !terminating, !(latest.loginRunning && login == nil) else { return }
        if login != nil { stopLogin(); return }
        guard alert("添加账号", detail: "", confirm: "打开登录") else { return }
        do {
            let executable = try NativeCodexCLI.locate()
            let home = supportURL.appendingPathComponent("login-\(UUID().uuidString)", isDirectory: true)
            try PrivateFiles.directory(home)
            try PrivateFiles.write(Data("cli_auth_credentials_store = \"file\"\n[analytics]\nenabled = false\n".utf8), to: home.appendingPathComponent("config.toml"))
            let process = Process(); process.executableURL = executable; process.arguments = ["login"]
            var env = ProcessInfo.processInfo.environment; env["CODEX_HOME"] = home.path
            for key in ["OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "CODEX_APP_SERVER_LOGIN_ISSUER", "BROWSER"] { env[key] = nil }
            process.environment = env; process.currentDirectoryURL = home
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] finished in Task { @MainActor in self?.finishLogin(finished) } }
            login = process; loginHome = home
            try process.run()
            Task { await monitor.setLoginRunning(true) }; render()
            loginTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }; self?.stopLogin()
            }
        } catch { stopLogin(); _ = alert("无法开始登录", detail: publicError(error)) }
    }
    private func stopLogin() {
        loginTimeout?.cancel(); loginTimeout = nil
        if let login, login.isRunning { login.terminate(); return }
        if let home = loginHome { try? FileManager.default.removeItem(at: home) }
        login = nil; loginHome = nil; Task { await monitor.setLoginRunning(false) }; render()
    }
    private func finishLogin(_ process: Process) {
        guard login === process else { return }
        let home = loginHome; login = nil; loginHome = nil; loginTimeout?.cancel(); loginTimeout = nil
        Task {
            var saved = false
            do {
                if process.terminationStatus == 0, let home {
                    guard let data = try PrivateFiles.read(home.appendingPathComponent("auth.json")) else { throw PotetoError.invalidAuth }
                    latest = try await monitor.finishLogin(AuthBundle(data: data)); saved = true
                }
            } catch { if !terminating { _ = alert("未保存登录", detail: publicError(error)) } }
            if let home { try? FileManager.default.removeItem(at: home) }
            await monitor.setLoginRunning(false); latest = await monitor.snapshot(); render()
            if saved && !terminating { refresh(force: true); _ = alert("账号已添加", detail: "") }
        }
    }
}

#if POTETO_TEST
extension AppDelegate {
    var presentationState: PanelState { panel }
    var presentationPopover: NSPopover { popover }
    var presentationLatest: Snapshot { latest }
    var presentationTitle: String? { item.button?.title }
    var presentationRefreshTask: Task<Void, Never>? { refreshTask }
    var presentationStatusWindow: NSWindow? { item.button?.window }
    func configurePresentation(theme: @escaping () -> DesktopTheme, nativeRunning: @escaping () -> Bool,
                               startup: @escaping () -> Bool, screen: @escaping () -> NSSize) {
        presentationTheme = theme; presentationNativeRunning = nativeRunning
        presentationStartup = startup; presentationScreen = screen
    }
    func hidePresentationStatusItem() { item.isVisible = false }
    func preparePresentation() { preparePanelForShow() }
    func refreshPresentation() { refresh(force: true) }
    func setPresentationBusy(_ value: Bool) { switching = value }
    func receivePresentation(_ value: Snapshot) { latest = value; updateTitle(); render() }
    func finishPresentationFixture() async throws {
        await refreshTask?.value
        await startupTask?.value
        try await monitor.prepareToQuit()
        applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        signalSource?.cancel(); signalSource = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}
#endif

#if !POTETO_TEST
@main
struct Poteto {
    static func main() {
        do {
            if let result = try ProjectCommand.run(Array(CommandLine.arguments.dropFirst())) {
                FileHandle.standardOutput.write(result + Data("\n".utf8))
                return
            }
        } catch {
            let message: String
            switch error as? PotetoError {
            case .running: message = "完全退出 ChatGPT 和 Codex 后再恢复项目。"
            case .invalidAuth: message = "项目检查需要当前账号的文件模式凭据。请先确认原生登录和 Codex 目录。"
            case .projectState: message = "无法合并本地项目。请核对当前账号、原生项目状态和来源槽位。"
            case .projectPartial: message = "请运行 --project-status 核对恢复结果。"
            case .changed: message = "本机状态刚发生变化。请重新运行 --project-status。"
            default: message = (error as? ProjectCommand.UsageError)?.errorDescription ?? publicError(error)
            }
            fputs(message + "\n", stderr)
            exit(1)
        }
        do {
            try PrivateFiles.directory(supportURL)
            if CommandLine.arguments.contains("--status") {
                if let data = try PrivateFiles.read(supportURL.appendingPathComponent("status.json")) { FileHandle.standardOutput.write(data) }
                return
            }
            if CommandLine.arguments.contains("--theme-info") {
                _ = NSApplication.shared
                let theme = DesktopTheme.load()
                let rgb: (NSColor) -> [Double] = { [$0.redComponent, $0.greenComponent, $0.blueComponent] }
                let data = try JSONSerialization.data(withJSONObject: ["surface": rgb(theme.surface), "ink": rgb(theme.ink), "accent": rgb(theme.accent)])
                FileHandle.standardOutput.write(data); return
            }
            // Starting the job must not retain the single-instance lock while launchd starts it.
            if CommandLine.arguments.contains("--enable-login") { try LoginStart.configure(true); return }
            let lock = try InstanceLock(supportURL.appendingPathComponent("runtime.lock"))
            withExtendedLifetime(lock) {
                do {
                    if let index = CommandLine.arguments.firstIndex(of: "--migrate") {
                        var vault = try CredentialStore.load(allowInteraction: true)
                        for path in CommandLine.arguments.dropFirst(index + 1) {
                            guard let data = try PrivateFiles.read(URL(fileURLWithPath: path)), let legacy = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  legacy["version"] as? Int == 1, let accounts = legacy["accounts"] as? [[String: Any]], accounts.count <= 128 else { throw PotetoError.malformed }
                            for entry in accounts {
                                guard let doc = entry["auth"] as? [String: Any] else { throw PotetoError.malformed }
                                let auth = AuthBundle(data: try JSONSerialization.data(withJSONObject: doc, options: .sortedKeys)); try vault.put(auth)
                            }
                        }
                        if let data = try PrivateFiles.read(nativeAuthURL) { try vault.put(AuthBundle(data: data), fromNative: true) }
                        try CredentialStore.save(vault)
                        print("migrated \(vault.accounts.count) official accounts to local Keychain")
                        return
                    }
                    let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate
                    withExtendedLifetime(delegate) { app.run() }
                } catch { fputs("\(publicError(error))\n", stderr); exit(1) }
            }
        } catch PotetoError.changed { exit(0) }
        catch { fputs("\(publicError(error))\n", stderr); exit(1) }
    }
}
#endif
