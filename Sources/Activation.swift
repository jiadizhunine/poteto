import Foundation
import AppKit
import Darwin
import Security

struct ActivationLedger: Codable {
    struct Boundary: Codable, Equatable {
        let deadline: Date
        let observedAt: Date
    }
    enum Outcome: String, Codable { case claimed, completed, failed }
    struct Record: Codable {
        let slot: ActivationObservation.Slot
        let duration: Double
        let attemptedAt: Date
        var outcome: Outcome
        var pending: Boundary?
        var confirmed: Date?
    }
    var version = 1
    var accounts: [String: Record] = [:]

    static func load(_ url: URL) throws -> ActivationLedger {
        guard let data = try PrivateFiles.read(url) else { return ActivationLedger() }
        let ledger = try JSONDecoder().decode(ActivationLedger.self, from: data)
        guard ledger.version == 1 else { throw PotetoError.malformed }
        return ledger
    }
    func save(_ url: URL) throws {
        try PrivateFiles.write(JSONEncoder().encode(self), to: url)
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw PotetoError.privateFile }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw PotetoError.privateFile }
    }
    mutating func observe(_ observation: ActivationObservation, id: String, now: Date) -> Bool {
        let candidate = observation.unstarted && observation.allUnused && observation.sendAllowed
        guard var record = accounts[id] else {
            guard candidate else { return false }
            accounts[id] = Record(slot: observation.slot, duration: observation.duration, attemptedAt: now,
                                  outcome: .claimed, pending: nil, confirmed: nil)
            return true
        }
        guard record.slot == observation.slot, record.duration == observation.duration else { return false }
        if let end = record.confirmed, let server = observation.serverTime, server >= end, candidate {
            accounts[id] = Record(slot: record.slot, duration: record.duration, attemptedAt: now,
                                  outcome: .claimed, pending: nil, confirmed: nil)
            return true
        }
        if record.confirmed == nil, !observation.unstarted,
           let server = observation.serverTime, let deadline = observation.absoluteReset, deadline > server {
            if let previous = record.pending, previous.deadline == deadline, server > previous.observedAt {
                record.confirmed = deadline
            } else if record.pending == nil || server > record.pending!.observedAt {
                record.pending = Boundary(deadline: deadline, observedAt: server)
            }
            accounts[id] = record
        }
        return false
    }
}

final class ActivationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum NativeCodexCLI {
    static func locate() throws -> URL {
        try locate(
            applications: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app", isDirectory: true)
            ],
            registered: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") }
        )
    }

    static func locate(applications: [URL], registered: () -> URL?) throws -> URL {
        var requirement: SecRequirement?
        let rule = #"anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2""#
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw PotetoError.nativeCLIUnavailable }
        func verifiedCLI(in application: URL) -> URL? {
            let app = application.resolvingSymlinksInPath()
            let cli = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                .resolvingSymlinksInPath()
            guard cli.path.hasPrefix(app.path + "/"), FileManager.default.isExecutableFile(atPath: cli.path) else { return nil }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(cli as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
            return cli
        }
        for app in applications {
            if let cli = verifiedCLI(in: app) { return cli }
        }
        if let app = registered(), let cli = verifiedCLI(in: app) { return cli }
        throw PotetoError.nativeCLIUnavailable
    }
}

enum NativeActivation {
    static let flags = ["shell_tool", "unified_exec", "multi_agent", "plugins", "apps", "code_mode", "browser_use", "computer_use", "image_generation", "remote_plugin"]

    static func run(auth: AuthBundle, cancellation: ActivationCancellation, executable: String? = nil, timeout: TimeInterval = 45, preflight: Bool = false) throws {
        guard !cancellation.cancelled else { throw PotetoError.network }
        guard let access = try auth.token("access_token") else { throw PotetoError.loginRequired }
        let identity = try auth.identity
        let cli = try executable.map { URL(fileURLWithPath: $0) } ?? NativeCodexCLI.locate()
        let scratch = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("poteto-activation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let config = """
        cli_auth_credentials_store = "file"
        web_search = "disabled"
        [history]
        persistence = "none"
        [analytics]
        enabled = false
        [features]
        skip_host_skill_discovery = true
        unbounded_connection_retries = false
        \(flags.map { "\($0) = false" }.joined(separator: "\n"))
        """
        try Data(config.utf8).write(to: scratch.appendingPathComponent("config.toml"))
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = cli; child.arguments = ["app-server", "--stdio"]
        child.currentDirectoryURL = scratch
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": scratch.path, "TMPDIR": scratch.path]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING"] { if let value = ProcessInfo.processInfo.environment[key] { env[key] = value } }
        child.environment = env; child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        guard !cancellation.cancelled else { throw PotetoError.network }
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            let until = ProcessInfo.processInfo.systemUptime + 1
            while child.isRunning && ProcessInfo.processInfo.systemUptime < until { usleep(20_000) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffered = Data(), total = 0, frames = 0, nextID = 0
        var pending: [[String: Any]] = []
        let fd = output.fileHandleForReading.fileDescriptor
        let writeFD = input.fileHandleForWriting.fileDescriptor
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0,
              fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK) == 0 else { throw PotetoError.network }
        func send(_ method: String, _ params: [String: Any], id: Int?) throws {
            guard !cancellation.cancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw PotetoError.network }
            var object: [String: Any] = ["method": method, "params": params]
            if let id { object["id"] = id }
            var bytes = try JSONSerialization.data(withJSONObject: object); bytes.append(10)
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    guard !cancellation.cancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw PotetoError.network }
                    let count = Darwin.write(writeFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count > 0 { offset += count; continue }
                    guard count < 0, errno == EAGAIN || errno == EINTR else { throw PotetoError.network }
                    var descriptor = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
                    guard poll(&descriptor, 1, 100) >= 0 else { throw PotetoError.network }
                }
            }
        }
        func receive() throws -> [String: Any] {
            while true {
                guard !cancellation.cancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw PotetoError.network }
                if let index = buffered.firstIndex(of: 10) {
                    let line = buffered.prefix(upTo: index); buffered.removeSubrange(...index)
                    frames += 1
                    guard frames <= 1024, line.count <= 262_144,
                          let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw PotetoError.malformed }
                    if object["method"] != nil && object["id"] != nil { throw PotetoError.malformed }
                    if let method = object["method"] as? String {
                        if method == "error" { throw PotetoError.malformed }
                        if method.hasPrefix("item/") {
                            if method == "item/started" || method == "item/completed" {
                                guard let params = object["params"] as? [String: Any], let item = params["item"] as? [String: Any],
                                      let type = item["type"] as? String, ["userMessage", "agentMessage", "reasoning"].contains(type) else { throw PotetoError.malformed }
                            } else if !method.hasPrefix("item/agentMessage/") && !method.hasPrefix("item/reasoning/") {
                                throw PotetoError.malformed
                            }
                        }
                    }
                    return object
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 { throw PotetoError.network }
                if ready > 0 {
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    guard count > 0 else { throw PotetoError.network }
                    total += count; guard total <= 2_097_152 else { throw PotetoError.malformed }
                    buffered.append(contentsOf: bytes.prefix(count))
                }
            }
        }
        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            nextID += 1; let id = nextID
            try send(method, params, id: id)
            while true {
                let frame = try receive()
                if let responseID = frame["id"] as? Int {
                    guard responseID == id, frame["error"] == nil, let result = frame["result"] as? [String: Any] else { throw PotetoError.malformed }
                    return result
                }
                if let method = frame["method"] as? String, method.hasPrefix("turn/") || method.hasPrefix("item/") { pending.append(frame) }
            }
        }
        let initialization = try call("initialize", ["clientInfo": ["name": "poteto", "title": "poteto", "version": "1.0.3"], "capabilities": ["experimentalApi": true]])
        guard (initialization["codexHome"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) == scratch.standardizedFileURL.resolvingSymlinksInPath().path else { throw PotetoError.malformed }
        try send("initialized", [:], id: nil)
        let configResponse = try call("config/read", ["includeLayers": false])
        guard let actual = configResponse["config"] as? [String: Any], actual["cli_auth_credentials_store"] as? String == "file",
              actual["web_search"] as? String == "disabled", let features = actual["features"] as? [String: Any],
              flags.allSatisfy({ (features[$0] as? Bool) == false }),
              features["skip_host_skill_discovery"] as? Bool == true,
              features["unbounded_connection_retries"] as? Bool == false else { throw PotetoError.malformed }
        var login: [String: Any] = ["type": "chatgptAuthTokens", "accessToken": access, "chatgptAccountId": identity.workspace]
        if let plan = identity.plan { login["chatgptPlanType"] = plan }
        guard try call("account/login/start", login)["type"] as? String == "chatgptAuthTokens" else { throw PotetoError.malformed }
        let read = try call("account/read", ["refreshToken": false])
        guard let account = read["account"] as? [String: Any], account["type"] as? String == "chatgpt",
              (account["email"] as? String)?.lowercased() == identity.email.lowercased() else { throw PotetoError.wrongIdentity }
        if let routing = read["workspaceRouting"] as? [String: Any], let accountID = routing["chatgptAccountId"], !(accountID is NSNull) {
            guard accountID as? String == identity.workspace else { throw PotetoError.wrongIdentity }
        }
        var models: [[String: Any]] = [], cursor: String?, cursors = Set<String>()
        var pages = 0
        repeat {
            pages += 1; guard pages <= 128 else { throw PotetoError.malformed }
            var params: [String: Any] = ["includeHidden": false, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try call("model/list", params)
            guard let page = result["data"] as? [[String: Any]] else { throw PotetoError.malformed }
            models += page; guard models.count <= 128 else { throw PotetoError.malformed }
            cursor = result["nextCursor"] as? String
            if let cursor, !cursors.insert(cursor).inserted { throw PotetoError.malformed }
        } while cursor != nil
        let order: [String] = ["minimal", "low", "medium", "high", "xhigh", "max"]
        guard models.allSatisfy({ model in
            guard let flag = model["isDefault"] as? NSNumber else { return false }
            return CFGetTypeID(flag) == CFBooleanGetTypeID()
        }) else { throw PotetoError.malformed }
        let defaults = models.filter { ($0["isDefault"] as? Bool) == true }
        guard defaults.count == 1 else { throw PotetoError.malformed }
        let modalities: [String]
        if let value = defaults[0]["inputModalities"] {
            guard let parsed = value as? [String] else { throw PotetoError.malformed }
            modalities = parsed
        } else { modalities = ["text", "image"] }
        guard let model = defaults[0]["model"] as? String, !model.isEmpty,
              modalities.contains("text"),
              let efforts = defaults[0]["supportedReasoningEfforts"] as? [[String: Any]],
              let effort: String = order.first(where: { choice in efforts.contains { ($0["reasoningEffort"] as? String) == choice } }) else { throw PotetoError.malformed }
        let thread = try call("thread/start", ["ephemeral": true, "model": model, "modelProvider": "openai", "allowProviderModelFallback": false,
                                                "cwd": scratch.path, "approvalPolicy": "never", "sandbox": "read-only", "environments": [], "dynamicTools": [],
                                                "baseInstructions": "Reply exactly OK. Do not use tools."])
        guard thread["modelProvider"] as? String == "openai", thread["model"] as? String == model,
              thread["approvalPolicy"] as? String == "never",
              (thread["sandbox"] as? [String: Any])?["type"] as? String == "readOnly",
              let info = thread["thread"] as? [String: Any], info["ephemeral"] as? Bool == true,
              info["path"] == nil || info["path"] is NSNull, let threadID = info["id"] as? String else { throw PotetoError.malformed }
        if preflight { return }
        pending.removeAll()
        let started = try call("turn/start", ["threadId": threadID, "input": [["type": "text", "text": "Reply exactly OK. Do not use tools."]], "effort": effort, "serviceTierForTurn": "default"])
        guard let turn = started["turn"] as? [String: Any], let turnID = turn["id"] as? String else { throw PotetoError.malformed }
        var message: String?
        while true {
            let frame = try pending.isEmpty ? receive() : pending.removeFirst()
            guard let method = frame["method"] as? String, let params = frame["params"] as? [String: Any] else { throw PotetoError.malformed }
            if method == "item/completed", params["threadId"] as? String == threadID, params["turnId"] as? String == turnID,
               let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage" { message = item["text"] as? String }
            if method == "turn/completed", params["threadId"] as? String == threadID,
               let done = params["turn"] as? [String: Any], done["id"] as? String == turnID {
                guard done["status"] as? String == "completed", message?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else { throw PotetoError.malformed }
                return
            }
        }
    }
}
