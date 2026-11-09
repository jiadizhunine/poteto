import Foundation

@main
struct ActivationTests {
    static func tryValue(_ body: () throws -> Bool) -> Bool { (try? body()) == true }
    static func main() throws {
        let identity = Identity(id: "id", email: "a@example.invalid", workspace: "workspace", plan: "pro")
        let base: [String: Any] = ["account_id": "workspace", "email": identity.email,
            "rate_limit": ["allowed": true, "limit_reached": false,
                "primary_window": ["used_percent": 0, "limit_window_seconds": 300, "reset_after_seconds": 300],
                "secondary_window": ["used_percent": 0, "limit_window_seconds": 600, "reset_after_seconds": 600]]]
        func parse(_ root: [String: Any], server: Date? = nil) throws -> Usage {
            try parseUsage(JSONSerialization.data(withJSONObject: root), for: identity, serverTime: server)
        }
        let candidate = try parse(base).activation!
        precondition(candidate.slot == .secondary && candidate.allUnused && candidate.unstarted)
        var group = base["rate_limit"] as! [String: Any]
        var altered = base
        group["primary_window"] = ["used_percent": 1, "limit_window_seconds": 300]
        altered["rate_limit"] = group
        precondition(tryValue { try parse(altered).activation?.allUnused == false })
        group["primary_window"] = ["used_percent": "bad", "limit_window_seconds": 300]
        altered["rate_limit"] = group
        precondition(tryValue { try parse(altered).activation == nil })
        group = base["rate_limit"] as! [String: Any]; group["limit_reached"] = 0
        altered["rate_limit"] = group
        precondition(tryValue { try parse(altered).activation?.sendAllowed == false })
        group = base["rate_limit"] as! [String: Any]; group["third_window"] = ["used_percent": 0, "limit_window_seconds": 700]
        altered["rate_limit"] = group
        precondition(tryValue { try parse(altered).activation == nil })
        group = base["rate_limit"] as! [String: Any]
        group["secondary_window"] = ["used_percent": 0.1, "limit_window_seconds": 600, "reset_after_seconds": 600]
        altered["rate_limit"] = group
        precondition(tryValue { try parse(altered).activation?.allUnused == false })
        group = base["rate_limit"] as! [String: Any]; group["allowed"] = false; group["limit_reached"] = true
        altered["rate_limit"] = group
        precondition(tryValue { try parse(altered).activation?.sendAllowed == false })
        for alias in ["windowDurationMins", "usedPercent", "remainingPercent", "resetsAt"] {
            group = base["rate_limit"] as! [String: Any]
            var window = group["secondary_window"] as! [String: Any]
            window[alias] = 999
            group["secondary_window"] = window; altered["rate_limit"] = group
            precondition(tryValue { try parse(altered).activation == nil })
        }
        let duplicate = "{\"account_id\":\"workspace\",\"email\":\"a@example.invalid\",\"rate_limit\":{\"allowed\":true,\"limit_reached\":false,\"primary_window\":{\"used_percent\":0,\"used_percent\":0,\"limit_window_seconds\":300,\"reset_after_seconds\":300}}}"
        precondition(tryValue { try parseUsage(Data(duplicate.utf8), for: identity).activation == nil })
        let time = Date(timeIntervalSince1970: 1000), end = Date(timeIntervalSince1970: 1600)
        func fixed(_ at: Date, _ deadline: Date = end) -> ActivationObservation {
            ActivationObservation(slot: .secondary, duration: 600, usedPercent: 0, unstarted: false, allUnused: true, sendAllowed: true, absoluteReset: deadline, serverTime: at)
        }
        var ledger = ActivationLedger()
        precondition(ledger.observe(candidate, id: identity.id, now: time))
        precondition(!ledger.observe(candidate, id: identity.id, now: time))
        let floating = ActivationObservation(slot: .secondary, duration: 600, usedPercent: 0, unstarted: true, allUnused: true, sendAllowed: true, absoluteReset: end, serverTime: time)
        let floatingLater = ActivationObservation(slot: .secondary, duration: 600, usedPercent: 0, unstarted: true, allUnused: true, sendAllowed: true, absoluteReset: end, serverTime: time.addingTimeInterval(1))
        precondition(!ledger.observe(floating, id: identity.id, now: time))
        precondition(!ledger.observe(floatingLater, id: identity.id, now: time))
        precondition(ledger.accounts[identity.id]?.pending == nil && ledger.accounts[identity.id]?.confirmed == nil)
        precondition(!ledger.observe(fixed(time), id: identity.id, now: time))
        precondition(!ledger.observe(fixed(time), id: identity.id, now: time))
        precondition(ledger.accounts[identity.id]?.confirmed == nil)
        let changed = ActivationObservation(slot: .primary, duration: 300, usedPercent: 0, unstarted: true, allUnused: true, sendAllowed: true, absoluteReset: nil, serverTime: end)
        precondition(!ledger.observe(changed, id: identity.id, now: end.addingTimeInterval(100000)))
        let noServer = ActivationObservation(slot: .secondary, duration: 600, usedPercent: 0, unstarted: true, allUnused: true, sendAllowed: true, absoluteReset: nil, serverTime: nil)
        precondition(!ledger.observe(noServer, id: identity.id, now: end.addingTimeInterval(100000)))
        precondition(!ledger.observe(fixed(time.addingTimeInterval(1)), id: identity.id, now: time))
        precondition(ledger.accounts[identity.id]?.confirmed == end)
        let after = ActivationObservation(slot: .secondary, duration: 600, usedPercent: 0, unstarted: true, allUnused: true, sendAllowed: true, absoluteReset: nil, serverTime: end)
        precondition(ledger.observe(after, id: identity.id, now: time))
        precondition(!ledger.observe(after, id: identity.id, now: time))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poteto-activation-test-\(UUID().uuidString)")
        try PrivateFiles.directory(dir); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("activation.json")
        try ledger.save(file)
        precondition(tryValue { try ActivationLedger.load(file).accounts[identity.id] != nil })
        try PrivateFiles.write(Data("{\"version\":2,\"accounts\":{}}".utf8), to: file)
        do { _ = try ActivationLedger.load(file); fatalError("unknown version accepted") } catch { }
        let claims: [String: Any] = ["email": identity.email, "https://api.openai.com/auth": ["chatgpt_account_id": "workspace", "chatgpt_plan_type": "pro"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let auth = AuthBundle(data: try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "e30.\(payload).c2ln", "access_token": "fixture-access", "refresh_token": "must-not-leak", "account_id": "workspace"]]))
        let scratchMarker = dir.appendingPathComponent("scratch-path")
        let turnMarker = dir.appendingPathComponent("turn-marker")
        let originalFake = try String(contentsOfFile: "Tests/fake-activation.py", encoding: .utf8)
        let fake = originalFake.replacingOccurrences(of: "home = os.environ['CODEX_HOME']", with: "home = os.environ['CODEX_HOME']\nopen('\(scratchMarker.path)', 'w').write(home)")
            .replacingOccurrences(of: "turns += 1", with: "open('\(turnMarker.path)', 'w').write('turn')\n        turns += 1")
        func scratchRemoved() throws -> Bool {
            let path = try String(contentsOf: scratchMarker, encoding: .utf8)
            return !FileManager.default.fileExists(atPath: path)
        }
        let successFile = dir.appendingPathComponent("success")
        try fake.write(to: successFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: successFile.path)
        try NativeActivation.run(auth: auth, cancellation: ActivationCancellation(), executable: successFile.path, timeout: 5)
        precondition((try? scratchRemoved()) == true && FileManager.default.fileExists(atPath: turnMarker.path))
        func rejects(_ name: String, _ source: String, timeout: TimeInterval = 3, verifyScratch: Bool = false) throws {
            try? FileManager.default.removeItem(at: scratchMarker)
            try? FileManager.default.removeItem(at: turnMarker)
            let path = dir.appendingPathComponent(name)
            try source.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            do {
                try NativeActivation.run(auth: auth, cancellation: ActivationCancellation(), executable: path.path, timeout: timeout)
                fatalError("fake transport accepted \(name)")
            } catch { }
            if verifyScratch {
                precondition((try? scratchRemoved()) == true, "scratch remained after \(name)")
                precondition(!FileManager.default.fileExists(atPath: turnMarker.path), "turn sent for \(name)")
            }
        }
        try rejects("wrong-identity", fake.replacingOccurrences(of: "'a@example.invalid'", with: "'wrong@example.invalid'"))
        try rejects("no-default", fake.replacingOccurrences(of: "'isDefault': True", with: "'isDefault': False"))
        let modelLine = "elif method == 'model/list': result = {'data': [{'isDefault': True, 'model': 'fixture-default', 'inputModalities': ['text'], 'supportedReasoningEfforts': [{'reasoningEffort': 'high'}, {'reasoningEffort': 'low'}]}], 'nextCursor': None}"
        for (name, value) in [("wrong-modalities", "'text'"), ("null-modalities", "None"), ("mixed-modalities", "['text', 1]")] {
            try rejects(name, fake.replacingOccurrences(of: "'inputModalities': ['text']", with: "'inputModalities': \(value)"), verifyScratch: true)
        }
        try rejects("duplicate-default", fake.replacingOccurrences(of: modelLine, with: "elif method == 'model/list': result = {'data': [{'isDefault': True}, {'isDefault': True}], 'nextCursor': None}"), verifyScratch: true)
        try rejects("pagination-loop", fake.replacingOccurrences(of: modelLine, with: "elif method == 'model/list': result = {'data': [], 'nextCursor': 'repeat'}"), verifyScratch: true)
        try rejects("pagination-overflow", fake.replacingOccurrences(of: modelLine, with: "elif method == 'model/list': result = {'data': [{'isDefault': False}] * 129, 'nextCursor': None}"), verifyScratch: true)
        try rejects("error-response", fake.replacingOccurrences(of: "print(json.dumps({'id': request['id'], 'result': result}), flush=True)", with: "print(json.dumps({'id': request['id'], 'error': {'code': -1, 'message': 'fixture'}}) if method == 'model/list' else json.dumps({'id': request['id'], 'result': result}), flush=True)"), verifyScratch: true)
        let missingModalities = dir.appendingPathComponent("missing-modalities")
        try fake.replacingOccurrences(of: "'inputModalities': ['text'], ", with: "").write(to: missingModalities, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: missingModalities.path)
        try NativeActivation.run(auth: auth, cancellation: ActivationCancellation(), executable: missingModalities.path, timeout: 5)
        precondition((try? scratchRemoved()) == true)
        try rejects("refresh-request", fake.replacingOccurrences(of: "if method == 'initialize': result = {'codexHome': home}", with: "if method == 'initialize': print(json.dumps({'id': 999, 'method': 'account/token/refresh', 'params': {}}), flush=True); result = {'codexHome': home}"))
        try rejects("tool-request", fake.replacingOccurrences(of: "if method == 'initialize': result = {'codexHome': home}", with: "if method == 'initialize': print(json.dumps({'id': 999, 'method': 'item/commandExecution/requestApproval', 'params': {}}), flush=True); result = {'codexHome': home}"))
        try rejects("eof", "#!/usr/bin/python3\nimport sys\nsys.stdin.readline()\n")
        try rejects("timeout", "#!/usr/bin/python3\nimport time\ntime.sleep(3)\n", timeout: 0.2)
        try rejects("oversize", "#!/usr/bin/python3\nimport sys\nsys.stdin.readline()\nprint('x' * 2100000, flush=True)\n")
        try rejects("closed-stdin", "#!/usr/bin/python3\nimport json, os, sys, time\nr = json.loads(sys.stdin.readline())\nsys.stdin.close()\nprint(json.dumps({'id': r['id'], 'result': {'codexHome': os.environ['CODEX_HOME']}}), flush=True)\ntime.sleep(3)\n")
        let preflightFile = dir.appendingPathComponent("preflight")
        try fake.replacingOccurrences(of: "turns += 1", with: "raise AssertionError('unexpected turn')").write(to: preflightFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preflightFile.path)
        try NativeActivation.run(auth: auth, cancellation: ActivationCancellation(), executable: preflightFile.path, timeout: 5, preflight: true)
        let sleeper = dir.appendingPathComponent("sleeper")
        try "#!/usr/bin/python3\nimport time\ntime.sleep(10)\n".write(to: sleeper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
        let cancellation = ActivationCancellation(), finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do { try NativeActivation.run(auth: auth, cancellation: cancellation, executable: sleeper.path, timeout: 8); fatalError("cancelled child succeeded") }
            catch { }
        }
        Thread.sleep(forTimeInterval: 0.2); cancellation.cancel()
        precondition(finished.wait(timeout: .now() + 3) == .success, "native cancellation did not drain")
        print("poteto: activation eligibility, ledger, and fake native turn passed")
    }
}
