import Foundation
import AppKit

final class FakeVault {
    var value: Vault
    var failures = 0
    var writes = 0
    init(_ value: Vault) { self.value = value }
    func save(_ next: Vault) throws {
        writes += 1
        if failures > 0 { failures -= 1; throw PotetoError.keychain(-25308) }
        value = next
    }
}
actor Gate {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
    func wait() async { while !entered { await Task.yield() } }
}
actor SnapshotCollector {
    var snapshots: [Snapshot] = []
    func append(_ snapshot: Snapshot) { snapshots.append(snapshot) }
}
actor Counter {
    var count = 0
    func increment() { count += 1 }
}
func bundle(_ email: String, refresh: String = "fixture-refresh", refreshed: String = "2026-10-11T00:00:00Z") throws -> AuthBundle {
    let c: [String: Any] = ["email": email, "sub": "fixture", "https://api.openai.com/auth": ["chatgpt_account_id": "fixture", "chatgpt_plan_type": "pro"]]
    let p = try JSONSerialization.data(withJSONObject: c).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return AuthBundle(data: try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["id_token": "e30.\(p).c2ln", "access_token": "fixture-access", "refresh_token": refresh, "account_id": "fixture"], "last_refresh": refreshed], options: .sortedKeys))
}
@main
struct MonitorTests {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("poteto-monitor-\(UUID().uuidString)")
        try PrivateFiles.directory(folder); defer { try? FileManager.default.removeItem(at: folder) }
        let authFile = folder.appendingPathComponent("auth.json"), status = folder.appendingPathComponent("status.json")
        let a = try bundle("a@example.invalid"), b = try bundle("b@example.invalid"), c = try bundle("c@example.invalid")
        let use = Usage(plan: "fixture", windows: [UsageWindow(label: "Codex", durationMinutes: 300, remaining: 60, reset: nil, ordinary: true)], checkedAt: Date())
        var initial = Vault(); try initial.put(a, fromNative: true); try initial.put(b)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func fileIs(_ bundle: AuthBundle) throws -> Bool { try PrivateFiles.read(authFile) == bundle.data }

        try PrivateFiles.write(a.data, to: authFile)
        let store = FakeVault(initial), gate = Gate(), count = Counter()
        let monitor = Monitor(authURL: authFile, statusURL: status, load: { store.value }, save: store.save,
                              read: { _ in await count.increment(); await gate.pause(); return use }, running: { false })
        let captured = await monitor.snapshot()
        check(captured.accounts.allSatisfy { $0.plan == "pro" && $0.subscriptionTitle == "Pro" }, "identity plan is available before the usage request completes")
        let switching = Task { try await monitor.switchAccount(b.identity.id) }
        await gate.wait()
        _ = await monitor.refresh(force: true)
        check(await count.count == 1, "refresh cannot interleave a switching credential preparation")
        await gate.release(); let switched = try await switching.value
        check(try fileIs(b), "isolated closed-account switch")
        check(switched.accounts.first(where: { $0.current })?.subscriptionTitle == "fixture", "usage plan takes priority in the monitor snapshot")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(switched))
        check(decoded.accounts.map(\.plan) == switched.accounts.map(\.plan), "status serialization retains the account plans without credentials")

        try PrivateFiles.write(a.data, to: authFile)
        let updated = try bundle("a@example.invalid", refresh: "fixture-new-native", refreshed: "2026-10-11T01:00:00Z")
        let saveStore = FakeVault(initial)
        let retryMonitor = Monitor(authURL: authFile, statusURL: status, load: { saveStore.value }, save: saveStore.save, read: { _ in use }, running: { false })
        _ = await retryMonitor.snapshot(); saveStore.failures = 1
        try PrivateFiles.write(updated.data, to: authFile)
        let failed = await retryMonitor.snapshot()
        check(failed.error != nil, "failed capture is reported")
        check(saveStore.value.accounts[0].auth == a, "failed capture must not commit only in memory")
        _ = await retryMonitor.snapshot()
        check(saveStore.value.accounts[0].auth == updated, "next capture retries Keychain save")

        try PrivateFiles.write(a.data, to: authFile)
        let rotated = try b.replacingTokens(["refresh_token": "fixture-rotated", "access_token": "fixture-new-access"])
        let rotateStore = FakeVault(initial)
        let rotateMonitor = Monitor(authURL: authFile, statusURL: status, load: { rotateStore.value }, save: rotateStore.save,
            read: { auth in if try auth.identity.id == b.identity.id && auth.token("refresh_token") != "fixture-rotated" { throw PotetoError.loginRequired }; return use },
            renew: { _ in rotateStore.failures = 2; return rotated }, running: { false })
        _ = await rotateMonitor.refresh(force: true)
        check(rotateStore.value.accounts[1].auth == b, "failed rotated token save is not falsely reported persisted")
        check(try fileIs(a), "background rotation does not write native auth")
        rotateStore.failures = 1
        do { try await rotateMonitor.prepareToQuit(); preconditionFailure("quit lost pending token") } catch { checks += 1 }
        rotateStore.failures = 0; try await rotateMonitor.prepareToQuit()
        check(rotateStore.value.accounts[1].auth == rotated, "quit flushes pending renewed credentials")

        let quitGate = Gate(), quitStore = FakeVault(initial)
        let quitMonitor = Monitor(authURL: authFile, statusURL: status, load: { quitStore.value }, save: quitStore.save,
            read: { auth in if try auth.identity.id == b.identity.id { await quitGate.pause() }; return use }, running: { false })
        let refresh = Task { await quitMonitor.refresh(force: true) }; await quitGate.wait()
        let quit = Task { try await quitMonitor.prepareToQuit() }
        await quitGate.release(); _ = await refresh.value; try await quit.value
        check(try fileIs(a), "quit drains network without changing native login")

        let raceGate = Gate(), raceStore = FakeVault(initial)
        let raceMonitor = Monitor(authURL: authFile, statusURL: status, load: { raceStore.value }, save: raceStore.save,
            read: { _ in await raceGate.pause(); return use }, running: { false })
        let raceSwitch = Task { try await raceMonitor.switchAccount(b.identity.id) }; await raceGate.wait()
        try PrivateFiles.write(c.data, to: authFile); await raceGate.release()
        do { _ = try await raceSwitch.value; preconditionFailure("late preparation overwrote a new native login") } catch { checks += 1 }
        check(try fileIs(c), "native login change during preparation is retained")

        try PrivateFiles.write(a.data, to: authFile)
        var single = Vault(); try single.put(a, fromNative: true)
        let throttleStore = FakeVault(single), throttleCount = Counter()
        let throttleMonitor = Monitor(authURL: authFile, statusURL: status,
            load: { throttleStore.value }, save: throttleStore.save,
            read: { _ in await throttleCount.increment(); return use }, running: { false })
        let firstRefresh = await throttleMonitor.refresh()
        check(await throttleCount.count == 1 && firstRefresh.accounts.first?.usage?.ordinaryRemaining == 60,
              "initial regular refresh reads and publishes quota")
        _ = await throttleMonitor.refresh()
        check(await throttleCount.count == 1, "regular refresh within the throttle window performs no new read")
        let forcedRefresh = await throttleMonitor.refresh(force: true)
        check(await throttleCount.count == 2 && !forcedRefresh.refreshing,
              "forced refresh bypasses the throttle window and finishes")
        check(try fileIs(a), "regular and forced quota reads preserve native auth")

        let forceStore = FakeVault(single), forceGate = Gate(), forceCount = Counter()
        let forceMonitor = Monitor(authURL: authFile, statusURL: status,
            load: { forceStore.value }, save: forceStore.save,
            read: { _ in await forceCount.increment(); await forceGate.pause(); return use }, running: { true })
        let inFlight = Task { await forceMonitor.refresh(force: true) }
        await forceGate.wait()
        let joined = await forceMonitor.refresh(force: true)
        let joinedAgain = await forceMonitor.refresh(force: true)
        check(await forceCount.count == 1 && joined.refreshing && joinedAgain.refreshing,
              "repeated forced refreshes share the active read without additional concurrency")
        await forceGate.release()
        let completed = await inFlight.value
        check(!completed.refreshing && completed.accounts.first?.usage?.ordinaryRemaining == 60,
              "quota refresh completes while the native app is running")
        check(try fileIs(a), "refresh while the native app runs never writes native auth")

        let recoveryStore = FakeVault(single), recoveryCount = Counter(), renewCount = Counter()
        let recoveryMonitor = Monitor(authURL: authFile, statusURL: status,
            load: { recoveryStore.value }, save: recoveryStore.save,
            read: { _ in
                await recoveryCount.increment()
                if await recoveryCount.count == 1 { throw PotetoError.loginRequired }
                return use
            }, renew: { auth in await renewCount.increment(); return auth }, running: { true })
        let failedRefresh = await recoveryMonitor.refresh(force: true)
        check(!failedRefresh.refreshing && failedRefresh.accounts.first?.error != nil,
              "a failed quota read reports its error and clears refreshing")
        check(await renewCount.count == 0, "manual refresh does not renew the native owner's token")
        let recovered = await recoveryMonitor.refresh(force: true)
        check(await recoveryCount.count == 2 && !recovered.refreshing && recovered.accounts.first?.error == nil &&
              recovered.accounts.first?.usage?.ordinaryRemaining == 60,
              "forced refresh after an error retries immediately and publishes recovered quota")
        check(try fileIs(a), "failed and recovered quota reads retain native credentials")
        print("poteto: manual refresh throttle/force/coalescing/native-running/recovery checks passed")

        let observation = ActivationObservation(slot: .secondary, duration: 600, usedPercent: 0, unstarted: true,
                                                allUnused: true, sendAllowed: true, absoluteReset: nil, serverTime: nil)
        let full = Usage(plan: "fixture", windows: [UsageWindow(label: "Codex", durationMinutes: 10, remaining: 100, reset: nil, ordinary: true)], checkedAt: Date(), activation: observation)
        let progressGate = Gate(), progressSnapshots = SnapshotCollector()
        let progressMonitor = Monitor(authURL: authFile, statusURL: status, load: { FakeVault(single).value }, save: { _ in },
            read: { _ in full }, running: { false }, activationURL: folder.appendingPathComponent("progress-activation.json"),
            activate: { _, _ in await progressGate.pause(); return true })
        let progressRefresh = Task { await progressMonitor.refresh(force: true) { snapshot in await progressSnapshots.append(snapshot) } }
        await progressGate.wait()
        let delivered = await progressSnapshots.snapshots
        check(delivered.contains { $0.refreshing && $0.accounts.first?.usage?.ordinaryRemaining == 100 },
              "fresh full quota reaches progress callback before activation completes")
        await progressGate.release(); _ = await progressRefresh.value

        let activationCounter = Counter(), activationStore = FakeVault(single)
        let ledgerURL = folder.appendingPathComponent("test-activation.json")
        let activationMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in full }, running: { false }, activationURL: ledgerURL,
            activate: { auth, _ in
                precondition((try? auth.token("access_token")) == "fixture-access")
                await activationCounter.increment(); return true
            })
        _ = await activationMonitor.refresh(force: true)
        _ = await activationMonitor.refresh(force: true)
        check(await activationCounter.count == 1, "manual refresh does not repeat a claimed activation")
        check(try fileIs(a), "activation preserves native auth")
        let restartMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in full }, running: { false }, activationURL: ledgerURL,
            activate: { _, _ in await activationCounter.increment(); return true })
        _ = await restartMonitor.refresh(force: true)
        check(await activationCounter.count == 1, "restart retains the activation tombstone")
        try PrivateFiles.write(Data("invalid".utf8), to: ledgerURL)
        _ = await restartMonitor.refresh(force: true)
        check(await activationCounter.count == 1, "corrupt ledger fails closed")

        let visibleReset = Date(timeIntervalSince1970: 2_000_000_000)
        let resetObservation = ActivationObservation(slot: .secondary, duration: 600, usedPercent: 0, unstarted: false,
            allUnused: true, sendAllowed: true, absoluteReset: visibleReset, serverTime: nil)
        let resetUsage = Usage(plan: "fixture", windows: [UsageWindow(label: "Codex", durationMinutes: 10, remaining: 100,
            reset: visibleReset, ordinary: true)], checkedAt: Date(), activation: resetObservation)
        let resetLedger = folder.appendingPathComponent("visible-reset.json")
        let resetMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in full }, readback: { _ in resetUsage }, running: { false }, activationURL: resetLedger,
            activate: { _, _ in false })
        let resetSnapshot = await resetMonitor.refresh(force: true)
        let resetRecord = try ActivationLedger.load(resetLedger).accounts[a.identity.id]
        check(resetSnapshot.accounts.first?.usage?.ordinaryRemaining == 100 && resetSnapshot.accounts.first?.activationNote == nil &&
              resetRecord?.confirmed == nil && resetRecord?.outcome == .failed,
              "displayed official reset clears failure note without confirming a rearm")

        let failedActivationCount = Counter()
        let failedActivationMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in full }, running: { false }, activationURL: folder.appendingPathComponent("failed-activation.json"),
            activate: { _, _ in await failedActivationCount.increment(); return false })
        _ = await failedActivationMonitor.refresh(force: true)
        _ = await failedActivationMonitor.refresh(force: true)
        check(await failedActivationCount.count == 1, "a failed activation remains spent")
        let failedReadCount = Counter()
        let failedReadMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in throw PotetoError.network }, running: { false }, activationURL: folder.appendingPathComponent("failed-read.json"),
            activate: { _, _ in await failedReadCount.increment(); return true })
        _ = await failedReadMonitor.refresh(force: true)
        check(await failedReadCount.count == 0, "failed reads never activate")

        let blockedCounter = Counter()
        let blockedMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in full }, running: { false }, activationURL: folder.appendingPathComponent("missing-parent/activation.json"),
            activate: { _, _ in await blockedCounter.increment(); return true })
        let blocked = await blockedMonitor.refresh(force: true)
        check(await blockedCounter.count == 0 && blocked.accounts.first?.usage?.ordinaryRemaining == 100,
              "ledger write failure blocks the turn and retains quota")
        let quitCounter = Counter(), quitEntered = Counter()
        let activationQuitMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in full }, running: { false }, activationURL: folder.appendingPathComponent("quit-activation.json"),
            activate: { _, cancel in
                await quitEntered.increment()
                while !cancel.cancelled { try? await Task.sleep(for: .milliseconds(10)) }
                await quitCounter.increment(); return false
            })
        let activationRefresh = Task { await activationQuitMonitor.refresh(force: true) }
        while await quitEntered.count == 0 { await Task.yield() }
        _ = await activationQuitMonitor.refresh(force: true)
        try await activationQuitMonitor.prepareToQuit()
        _ = await activationRefresh.value
        let drained = await quitCounter.count, entered = await quitEntered.count
        check(drained == 1 && entered == 1, "quit cancels and drains the one coalesced activation")
        let readbackEntered = Counter()
        let quitReadbackMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in full }, readback: { _ in
                await readbackEntered.increment()
                try await Task.sleep(for: .seconds(30))
                return full
            }, running: { false }, activationURL: folder.appendingPathComponent("quit-readback.json"), activate: { _, _ in true })
        let readbackRefresh = Task { await quitReadbackMonitor.refresh(force: true) }
        while await readbackEntered.count == 0 { await Task.yield() }
        try await quitReadbackMonitor.prepareToQuit()
        _ = await readbackRefresh.value
        check(await readbackEntered.count == 1, "quit cancels an in-flight direct readback")
        let renewedCount = Counter()
        let renewalLedger = folder.appendingPathComponent("renewed-activation.json")
        let renewalStore = FakeVault(initial)
        let renewedMonitor = Monitor(authURL: authFile, statusURL: status, load: { renewalStore.value }, save: renewalStore.save,
            read: { auth in
                if try auth.identity.id == a.identity.id { return use }
                guard try auth.token("access_token") == "fixture-new-access" else { throw PotetoError.loginRequired }
                return full
            }, renew: { _ in rotated }, running: { false }, activationURL: renewalLedger,
            activate: { auth, _ in
                if (try? auth.token("access_token")) == "fixture-new-access" { await renewedCount.increment() }
                return true
            })
        _ = await renewedMonitor.refresh(force: true)
        let renewalActivations = await renewedCount.count, nativeUnchanged = try fileIs(a)
        check(renewalActivations == 1 && nativeUnchanged, "activation uses renewed non-current auth and leaves native auth alone")

        _ = try await renewedMonitor.forget(b.identity.id)
        _ = try await renewedMonitor.finishLogin(rotated)
        _ = await renewedMonitor.refresh(force: true)
        check(await renewedCount.count == 1, "forget and readd retains the cycle tombstone")
        let readbackCount = Counter(), initialCount = Counter(), boundary = Date(timeIntervalSince1970: 2_000_000_000)
        let boundaryLedger = folder.appendingPathComponent("boundary-activation.json")
        let resetCredit = ResetCredit(id: "credit", title: nil, expiresAt: boundary.addingTimeInterval(1000))
        let detailed = ResetAllowance(availableCount: 1, applicableCount: 1, credits: [resetCredit])
        let summary = ResetAllowance(availableCount: 1, applicableCount: 1, credits: nil)
        let fullWithDetails = Usage(plan: full.plan, windows: full.windows, checkedAt: full.checkedAt,
                                    resetAllowance: detailed, activation: observation)
        let readbackMonitor = Monitor(authURL: authFile, statusURL: status, load: { activationStore.value }, save: activationStore.save,
            read: { _ in await initialCount.increment(); return fullWithDetails }, readback: { _ in
                await readbackCount.increment()
                let index = await readbackCount.count
                let observed = ActivationObservation(slot: .secondary, duration: 600, usedPercent: 0, unstarted: false,
                    allUnused: false, sendAllowed: false, absoluteReset: boundary,
                    serverTime: Date(timeIntervalSince1970: 1_999_999_990 + Double(index)))
                return Usage(plan: "fixture", windows: full.windows, checkedAt: Date(), resetAllowance: summary, activation: observed)
            }, running: { false }, activationURL: boundaryLedger, activate: { _, _ in true })
        let readbackSnapshot = await readbackMonitor.refresh(force: true)
        let confirmed = try ActivationLedger.load(boundaryLedger).accounts[a.identity.id]?.confirmed
        let initialReads = await initialCount.count, directReads = await readbackCount.count
        check(initialReads == 1 && directReads == 2 && confirmed == boundary, "two direct reads confirm a fixed boundary even when sending is blocked")
        check(readbackSnapshot.accounts.first?.usage?.resetAllowance?.credits == [resetCredit], "direct readbacks retain compatible reset expiry details")

        let captureFailureURL = folder.appendingPathComponent("capture-failure.json")
        let captureFailureMonitor = Monitor(authURL: authFile, statusURL: captureFailureURL,
            load: { throw PotetoError.keychain(-25293) }, save: { _ in }, read: { _ in use }, running: { false })
        let captureFailure = await captureFailureMonitor.refresh(force: true)
        let captureFailureSaved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: captureFailureURL))
        check(captureFailure.error != nil && captureFailureSaved.error == captureFailure.error && !captureFailureSaved.refreshing,
              "capture failure is visible in the persisted status instead of leaving stale quota")

        let fixture = "[desktop]\nappearanceTheme = \"light\"\nappearanceLightChromeTheme = {surface = \"#f3eee3\", ink = \"#2b2924\", accent = \"#d97857\"}\n[unrelated]\napi_key = \"fixture\"\n"
        let theme = DesktopTheme.parse(fixture, systemDark: true)
        check(theme != nil && abs(theme!.surface.redComponent - 243.0 / 255) < 0.00001, "actual Codex surface")
        check(theme != nil && abs(theme!.accent.greenComponent - 120.0 / 255) < 0.00001, "actual Codex accent")
        let nested = "[desktop]\nappearanceTheme = \"dark\"\n[desktop.appearanceDarkChromeTheme]\nsurface = \"#202020\"\nink = \"#eeeeee\"\naccent = \"#123456\"\n"
        check(DesktopTheme.parse(nested, systemDark: false)?.dark == true, "nested theme and dark mode")
        check(DesktopTheme.parse("[desktop]\nappearanceLightChromeTheme = {surface = \"unsafe\"}", systemDark: false) == nil, "unknown color config does not guess")
        let small = PanelBounds.fitting(width: 360, height: 480, settings: true, error: true)
        check(small.width <= 336 && small.maximumHeight <= 448 && small.listHeight + 306 <= small.maximumHeight, "panel fits visible screen in points, including settings/error")
        let normal = PanelBounds.fitting(width: 1440, height: 900)
        check(normal.width == 380 && normal.maximumHeight == 600 && normal.listHeight == 360, "stable native popover bounds")
        check(deadlineText(Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 940)).contains("1分钟后"), "reset deadline includes countdown")
        check(deadlineText(Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 1001)).contains("已到时间"), "past deadline is not a negative countdown")
        for request in [URLRequest(url: URL(string: "https://example.invalid/usage")!), {
            var r = URLRequest(url: OfficialHTTP.resetCredits); r.httpMethod = "POST"; return r
        }()] {
            do { _ = try await OfficialHTTP.request(request); preconditionFailure("read-only endpoint guard did not reject") }
            catch { checks += 1 }
        }
        let panelSource = try String(contentsOfFile: "Sources/Panel.swift", encoding: .utf8)
        check(!panelSource.contains("退出 ChatGPT/Codex 后可切换") && !panelSource.contains("关于 poteto"), "unrequested explanatory text removed")
        print("poteto: \(checks) lifecycle/concurrency/theme checks passed")
    }
}
