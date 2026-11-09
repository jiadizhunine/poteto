import Foundation

@main
struct ProjectRetentionTests {
    static func auth(_ namespace: [String: Any]) throws -> AuthBundle {
        let claims: [String: Any] = ["email": "fake@example.invalid", "sub": "unrelated-subject", "https://api.openai.com/auth": namespace]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return AuthBundle(data: try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "e30.\(payload).c2ln", "account_id": "fake-account"]]))
    }

    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--fixture" {
            let dir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let state = try Data(contentsOf: dir.appendingPathComponent("state.json"))
            let a = AuthBundle(data: try Data(contentsOf: dir.appendingPathComponent("auth-a.json")))
            let b = AuthBundle(data: try Data(contentsOf: dir.appendingPathComponent("auth-b.json")))
            guard let prepared = try NativeProjectState.prepare(state, source: a, target: b) else { fatalError("fixture has no source projects") }
            try prepared.write(to: dir.appendingPathComponent("prepared.json")); return
        }
        try runSynthetic()
        for key in ["chatgpt_user_id", "user_id"] {
            let descriptor = try NativeAccountDescriptor(auth: auth(["chatgpt_account_id": "fake-account", key: "fake-user"]))
            precondition(descriptor.accountId == "fake-account" && descriptor.userId == "fake-user")
        }
        let both = try NativeAccountDescriptor(auth: auth(["chatgpt_account_id": "fake-account", "chatgpt_user_id": "fake-user", "user_id": "fake-user"]))
        precondition(both.userId == "fake-user")
        for namespace: [String: Any] in [
            ["chatgpt_account_id": "fake-account"],
            ["chatgpt_account_id": "fake-account", "chatgpt_user_id": "fake-user", "user_id": "other-user"],
            ["chatgpt_account_id": "other-account", "user_id": "fake-user"],
            ["chatgpt_account_id": "fake-account", "user_id": 42]
        ] {
            do { _ = try NativeAccountDescriptor(auth: auth(namespace)); fatalError("invalid descriptor accepted") }
            catch PotetoError.invalidAuth { }
        }
        print("Synthetic native account descriptor tests passed")
    }
    static func bundle(_ account: String) throws -> AuthBundle {
        let claims: [String: Any] = ["email": "\(account)@example.invalid", "sub": "other", "https://api.openai.com/auth": ["chatgpt_account_id": account, "user_id": "user-\(account)"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return AuthBundle(data: try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "e30.\(payload).c2ln", "account_id": account]]))
    }
    static func atom(_ account: String) -> [String: Any] { ["local-document-identity": ["accountId": account, "userId": "user-\(account)"]] }
    static func project(_ id: String) -> [String: Any] { ["id": id, "name": id, "rootPaths": ["/synthetic/shared"], "createdAt": 1, "updatedAt": 2] }
    static func globals(_ id: String) -> [String: Any] {
        ["local-projects": [id: project(id)], "project-order": [id], "sidebar-project-thread-orders": [id: ["threadIds": ["thread-\(id)", "stale"]]], "thread-project-assignments": ["thread-\(id)": ["projectKind": "local", "projectId": id]], "project-appearances": [id: ["color": "blue"]], "selected-project": id, "untouched": "sentinel"]
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func object(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    static func state() -> [String: Any] {
        var root = globals("a"); root["electron-persisted-atom-state"] = atom("A"); root["electron-account-renderer-state-v1"] = ["owner": "owner-A", "inactive": ["owner-B": ["atoms": atom("B"), "globals": globals("b")], "other": ["atoms": atom("C"), "globals": ["other": 1]]]]; return root
    }
    static func select(_ data: Data, _ owner: String) throws -> Data {
        var root = try object(data), state = root["electron-account-renderer-state-v1"] as! [String: Any], inactive = state["inactive"] as! [String: Any]
        let keys = ["local-projects", "project-order", "sidebar-project-thread-orders", "thread-project-assignments", "project-appearances", "selected-project", "untouched"]
        if let current = state["owner"] as? String {
            var g: [String: Any] = [:]; for key in keys { g[key] = root[key]; root.removeValue(forKey: key) }
            inactive[current] = ["atoms": root["electron-persisted-atom-state"]!, "globals": g]
        }
        let slot = inactive.removeValue(forKey: owner) as! [String: Any], g = slot["globals"] as! [String: Any]
        root["electron-persisted-atom-state"] = slot["atoms"]; for key in keys { root[key] = g[key] }
        state["owner"] = owner; state["inactive"] = inactive; root["electron-account-renderer-state-v1"] = state
        return try json(root)
    }
    static func runSynthetic() throws {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent("poteto-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: dir) }
        let authURL = dir.appendingPathComponent("auth.json"), stateURL = dir.appendingPathComponent(".codex-global-state.json"), a = try bundle("A"), b = try bundle("B")
        func write(_ data: Data, _ url: URL, _ mode: Int = 0o600) throws { try data.write(to: url); try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        try write(a.data, authURL); try write(try json(state()), stateURL, 0o644)
        try write(json(state()), dir.appendingPathComponent("state.json")); try write(a.data, dir.appendingPathComponent("auth-a.json")); try write(b.data, dir.appendingPathComponent("auth-b.json"))
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); fixture.arguments = ["--fixture", dir.path]; try fixture.run(); fixture.waitUntilExit()
        precondition(fixture.terminationStatus == 0)
        let fixturePrepared = try Data(contentsOf: dir.appendingPathComponent("prepared.json"))
        precondition(fixturePrepared == (try! NativeProjectState.prepare(json(state()), source: a, target: b)))
        let sentinels = ["config.toml", "history.jsonl", "sessions.sqlite"]
        for name in sentinels { try write(Data("sentinel".utf8), dir.appendingPathComponent(name)) }
        try activateAccount(b, authURL: authURL, isRunning: { false })
        let prepared = try Data(contentsOf: stateURL), selectedB = try select(prepared, "owner-B")
        let rootB = try object(selectedB), projectsB = rootB["local-projects"] as! [String: Any]
        precondition(Set(projectsB.keys) == ["a", "b"] && rootB["selected-project"] as? String == "b")
        precondition((try! object(prepared))["local-projects"] as! NSDictionary == (state()["local-projects"] as! NSDictionary))
        try write(selectedB, stateURL, 0o644)
        try activateAccount(a, authURL: authURL, isRunning: { false })
        let selectedA = try object(select(Data(contentsOf: stateURL), "owner-A"))
        precondition(Set((selectedA["local-projects"] as! [String: Any]).keys) == ["a", "b"])
        for name in sentinels { precondition(try! Data(contentsOf: dir.appendingPathComponent(name)) == Data("sentinel".utf8)) }
        func rejected(_ bytes: Data) throws {
            try write(a.data, authURL); try write(bytes, stateURL, 0o644)
            do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("invalid state accepted") }
            catch PotetoError.projectState { }
            precondition(try! Data(contentsOf: authURL) == a.data)
            precondition(try! Data(contentsOf: stateURL) == bytes)
        }
        var decoy = state(); decoy["electron-persisted-atom-state"] = atom("C"); decoy["decoy"] = atom("A")
        try rejected(json(decoy))
        var sameOwner = state(), sameRenderer = sameOwner["electron-account-renderer-state-v1"] as! [String: Any]
        var sameSlots = sameRenderer["inactive"] as! [String: Any]
        sameSlots["owner-A"] = sameSlots.removeValue(forKey: "owner-B")
        sameRenderer["inactive"] = sameSlots; sameOwner["electron-account-renderer-state-v1"] = sameRenderer
        try rejected(json(sameOwner))
        for (key, value) in [
            ("project-order", ["ghost"] as Any), ("sidebar-project-thread-orders", ["ghost": ["threadIds": []]] as Any),
            ("thread-project-assignments", ["thread": ["projectKind": "local", "projectId": "ghost"]] as Any),
            ("project-appearances", ["ghost": ["color": "blue"]] as Any), ("project-files", ["ghost": []] as Any),
            ("pinned-project-ids", ["ghost"] as Any)
        ] {
            var empty = state()
            for field in ["local-projects", "project-order", "sidebar-project-thread-orders", "thread-project-assignments", "project-appearances"] { empty.removeValue(forKey: field) }
            empty[key] = value
            try rejected(json(empty))
        }
        var empty = state()
        for field in ["local-projects", "project-order", "sidebar-project-thread-orders", "thread-project-assignments", "project-appearances"] { empty.removeValue(forKey: field) }
        try write(a.data, authURL); try write(json(empty), stateURL, 0o644)
        try activateAccount(b, authURL: authURL, isRunning: { false })
        precondition(try! Data(contentsOf: authURL) == b.data)
        var emptyMissing = empty, emptyMissingState = emptyMissing["electron-account-renderer-state-v1"] as! [String: Any]
        emptyMissingState["inactive"] = [:]; emptyMissing["electron-account-renderer-state-v1"] = emptyMissingState
        try rejected(json(emptyMissing))
        for field in ["project-order", "thread-project-assignments"] {
            var same = state()
            same[field] = field == "project-order" ? ["ghost"] : ["remote": ["projectKind": "remote", "projectId": "remote-id"]]
            let bytes = try json(same)
            try write(a.data, authURL); try write(bytes, stateURL, 0o644)
            do { try activateAccount(a, authURL: authURL, isRunning: { false }); fatalError("same-identity invalid layout accepted") }
            catch PotetoError.projectState { }
            precondition(try! Data(contentsOf: authURL) == a.data)
            precondition(try! Data(contentsOf: stateURL) == bytes)
        }
        var mixed = state(), mixedAssignments = mixed["thread-project-assignments"] as! [String: Any]
        mixedAssignments["remote"] = ["projectKind": "remote", "projectId": "remote-id"]
        mixed["thread-project-assignments"] = mixedAssignments
        try rejected(json(mixed))
        var remoteTarget = state(), remoteRenderer = remoteTarget["electron-account-renderer-state-v1"] as! [String: Any]
        var remoteSlots = remoteRenderer["inactive"] as! [String: Any], remoteSlot = remoteSlots["owner-B"] as! [String: Any], remoteGlobals = remoteSlot["globals"] as! [String: Any]
        remoteGlobals["thread-project-assignments"] = ["remote": ["projectKind": "remote", "projectId": "remote-id"]]
        remoteSlot["globals"] = remoteGlobals; remoteSlots["owner-B"] = remoteSlot; remoteRenderer["inactive"] = remoteSlots; remoteTarget["electron-account-renderer-state-v1"] = remoteRenderer
        let remoteOutput = try object(NativeProjectState.prepare(json(remoteTarget), source: a, target: b)!)
        let remoteState = remoteOutput["electron-account-renderer-state-v1"] as! [String: Any], remoteInactive = remoteState["inactive"] as! [String: Any]
        let remoteResult = (remoteInactive["owner-B"] as! [String: Any])["globals"] as! [String: Any]
        let assignments = remoteResult["thread-project-assignments"] as! [String: Any]
        precondition((assignments["remote"] as! [String: String])["projectKind"] == "remote" && assignments["thread-a"] != nil)
        var boolConflict = state(), boolRenderer = boolConflict["electron-account-renderer-state-v1"] as! [String: Any]
        var boolSlots = boolRenderer["inactive"] as! [String: Any], boolSlot = boolSlots["owner-B"] as! [String: Any], boolGlobals = boolSlot["globals"] as! [String: Any]
        boolConflict["project-appearances"] = ["a": ["flag": true]]
        boolGlobals["project-appearances"] = ["a": ["flag": 1]]
        boolSlot["globals"] = boolGlobals; boolSlots["owner-B"] = boolSlot; boolRenderer["inactive"] = boolSlots; boolConflict["electron-account-renderer-state-v1"] = boolRenderer
        try rejected(json(boolConflict))
        let base = String(data: try json(state()), encoding: .utf8)!
        for literal in ["9007199254740993", "1.2345678901234567890123456789", "5e-324", "-0"] {
            let input = Data(base.replacingOccurrences(of: "\"other\":1", with: "\"other\":\(literal)").utf8)
            precondition(input != Data(base.utf8))
            try write(a.data, authURL); try write(input, stateURL, 0o644)
            do {
                try activateAccount(b, authURL: authURL, isRunning: { false })
                let output = try Data(contentsOf: stateURL)
                let result = try object(output), renderer = result["electron-account-renderer-state-v1"] as! [String: Any]
                let slots = renderer["inactive"] as! [String: Any], other = slots["other"] as! [String: Any]
                let otherJSON = try json(other)
                precondition((try! NativeProjectState.numbers(otherJSON)) == (try! NativeProjectState.numbers(Data("[\(literal)]".utf8))))
            } catch PotetoError.projectState {
                precondition(try! Data(contentsOf: authURL) == a.data)
                precondition(try! Data(contentsOf: stateURL) == input)
            }
        }
        var conflict = state(), renderer = conflict["electron-account-renderer-state-v1"] as! [String: Any], inactive = renderer["inactive"] as! [String: Any], slot = inactive["owner-B"] as! [String: Any], target = slot["globals"] as! [String: Any]
        var changedProject = project("a"); changedProject["name"] = "different"; target["local-projects"] = ["a": changedProject]; slot["globals"] = target; inactive["owner-B"] = slot; renderer["inactive"] = inactive; conflict["electron-account-renderer-state-v1"] = renderer
        try write(a.data, authURL); try write(json(conflict), stateURL, 0o644)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("conflict accepted") } catch PotetoError.projectState { }
        precondition(try! Data(contentsOf: authURL) == a.data)
        var missing = state(), missingState = missing["electron-account-renderer-state-v1"] as! [String: Any]
        missingState["inactive"] = [:]; missing["electron-account-renderer-state-v1"] = missingState
        try write(json(missing), stateURL, 0o644)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("missing target accepted") } catch PotetoError.projectState { }
        var wrong = state(); wrong["electron-persisted-atom-state"] = atom("C")
        try write(json(wrong), stateURL, 0o644)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("wrong source accepted") } catch PotetoError.projectState { }
        var threadConflict = state(), rs = threadConflict["electron-account-renderer-state-v1"] as! [String: Any], slots = rs["inactive"] as! [String: Any], bs = slots["owner-B"] as! [String: Any], bg = bs["globals"] as! [String: Any]
        bg["thread-project-assignments"] = ["thread-a": ["projectKind": "local", "projectId": "b"]]; bs["globals"] = bg; slots["owner-B"] = bs; rs["inactive"] = slots; threadConflict["electron-account-renderer-state-v1"] = rs
        try write(json(threadConflict), stateURL, 0o644)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("thread conflict accepted") } catch PotetoError.projectState { }
        precondition(try! Data(contentsOf: authURL) == a.data)
        try fm.removeItem(at: stateURL); let linkTarget = dir.appendingPathComponent("link-target")
        try write(json(state()), linkTarget, 0o644); try fm.createSymbolicLink(at: stateURL, withDestinationURL: linkTarget)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("symlink accepted") } catch PotetoError.projectState { }
        try fm.removeItem(at: stateURL); try fm.linkItem(at: linkTarget, to: stateURL)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("hard link accepted") } catch PotetoError.projectState { }
        try fm.removeItem(at: stateURL)
        try write(json(state()), stateURL, 0o666)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("unsafe mode accepted") } catch PotetoError.projectState { }
        try fm.removeItem(at: stateURL); try activateAccount(b, authURL: authURL, isRunning: { false }); precondition(try! Data(contentsOf: authURL) == b.data)
        try write(a.data, authURL)
        var nullRoot = state(), nullState = nullRoot["electron-account-renderer-state-v1"] as! [String: Any], nullSlots = nullState["inactive"] as! [String: Any]
        nullSlots["owner-A"] = ["atoms": atom("A"), "globals": globals("a")]; nullState["owner"] = NSNull(); nullState["inactive"] = nullSlots; nullRoot["electron-account-renderer-state-v1"] = nullState
        do { _ = try NativeProjectState.prepare(json(nullRoot), source: a, target: a); fatalError("same null-owner slot accepted") } catch PotetoError.projectState { }
        try write(json(nullRoot), stateURL, 0o644); try activateAccount(b, authURL: authURL, isRunning: { false })
        let nullPrepared = try object(Data(contentsOf: stateURL)), nullRenderer = nullPrepared["electron-account-renderer-state-v1"] as! [String: Any], nullInactive = nullRenderer["inactive"] as! [String: Any], nullB = nullInactive["owner-B"] as! [String: Any], nullGlobals = nullB["globals"] as! [String: Any]
        precondition(Set((nullGlobals["local-projects"] as! [String: Any]).keys) == ["a", "b"])
        let attrs = try fm.attributesOfItem(atPath: stateURL.path); precondition((attrs[.posixPermissions] as! NSNumber).intValue == 0o644)
        try write(a.data, authURL); try write(json(state()), stateURL, 0o644)
        var calls = 0
        do { try activateAccount(b, authURL: authURL, isRunning: { calls += 1; return calls == 3 }); fatalError("race accepted") } catch PotetoError.projectPartial { }
        precondition(try! Data(contentsOf: authURL) == a.data)
        try activateAccount(b, authURL: authURL, isRunning: { false })
        precondition(try! Data(contentsOf: authURL) == b.data)
        try write(a.data, authURL); try write(json(state()), stateURL, 0o644)
        var raceCalls = 0
        do {
            try activateAccount(b, authURL: authURL, isRunning: {
                raceCalls += 1
                if raceCalls == 3 { try! write(Data("external writer".utf8), stateURL, 0o644) }
                return false
            }); fatalError("state race accepted")
        } catch PotetoError.projectPartial { }
        precondition(try! Data(contentsOf: authURL) == a.data)
        precondition(try! Data(contentsOf: stateURL) == Data("external writer".utf8))
        try write(json(state()), stateURL, 0o644)
        var startupCalls = 0
        do { try activateAccount(b, authURL: authURL, isRunning: { startupCalls += 1; return startupCalls == 4 }); fatalError("startup race accepted") } catch PotetoError.startupRace { }
        precondition(try! Data(contentsOf: authURL) == b.data)
        try write(a.data, authURL); try write(json(state()), stateURL, 0o644)
        var postAuthCalls = 0
        do {
            try activateAccount(b, authURL: authURL, isRunning: {
                postAuthCalls += 1
                if postAuthCalls == 4 { try! write(Data("post-auth writer".utf8), stateURL, 0o644) }
                return false
            }); fatalError("post-auth state race accepted")
        } catch PotetoError.projectPartial { }
        precondition(try! Data(contentsOf: authURL) == b.data)
        print("Synthetic project inheritance tests passed")
    }
}
