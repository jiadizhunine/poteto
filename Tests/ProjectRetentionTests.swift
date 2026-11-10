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
        let keys = ["local-projects", "project-order", "sidebar-project-thread-orders", "thread-project-assignments",
                    "project-appearances", "project-files", "pinned-project-ids", "thread-workspace-root-hints",
                    "thread-projectless-output-directories", "projectless-thread-ids", "selected-project", "untouched"]
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
        try activateAccount(b, authURL: authURL, isRunning: { false })
        precondition(try! Data(contentsOf: stateURL) == prepared)
        try activateAccount(a, authURL: authURL, isRunning: { false })
        let returnedWithoutOpen = try object(Data(contentsOf: stateURL))
        precondition(Set((returnedWithoutOpen["local-projects"] as! [String: Any]).keys) == ["a", "b"])
        precondition(try! Data(contentsOf: authURL) == a.data)
        try write(b.data, authURL)
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
            ("project-appearances", ["ghost": ["color": "blue"]] as Any), ("project-files", ["ghost": []] as Any),
            ("pinned-project-ids", ["ghost"] as Any)
        ] {
            var empty = state()
            for field in ["local-projects", "project-order", "sidebar-project-thread-orders", "thread-project-assignments", "project-appearances"] { empty.removeValue(forKey: field) }
            empty[key] = value
            let bytes = try json(empty)
            try write(a.data, authURL); try write(bytes, stateURL, 0o644)
            try activateAccount(b, authURL: authURL, isRunning: { false })
            precondition(try! Data(contentsOf: authURL) == b.data)
            precondition(try! Data(contentsOf: stateURL) == bytes)
        }
        var orphan = state()
        orphan["thread-project-assignments"] = ["thread": ["projectKind": "local", "projectId": "ghost"]]
        try rejected(json(orphan))
        let freshProfiles: [[String: Any]] = [
            ["local-projects": [:], "project-order": [], "unrelated": "keep"],
            ["electron-account-renderer-state-v1": ["owner": NSNull(), "inactive": [:]], "selected-project": NSNull(), "projectless-thread-ids": NSNull()]
        ]
        for profile in freshProfiles {
            let fresh = try json(profile)
            try fm.removeItem(at: authURL); try write(fresh, stateURL, 0o644)
            try activateAccount(b, authURL: authURL, isRunning: { false })
            precondition(try! Data(contentsOf: authURL) == b.data)
            precondition(try! Data(contentsOf: stateURL) == fresh)
        }
        try rejected(json(globals("a")))
        var empty = state()
        for field in ["local-projects", "project-order", "sidebar-project-thread-orders", "thread-project-assignments", "project-appearances"] { empty.removeValue(forKey: field) }
        try write(a.data, authURL); try write(json(empty), stateURL, 0o644)
        try activateAccount(b, authURL: authURL, isRunning: { false })
        precondition(try! Data(contentsOf: authURL) == b.data)
        var emptyMissing = empty, emptyMissingState = emptyMissing["electron-account-renderer-state-v1"] as! [String: Any]
        emptyMissingState["inactive"] = [:]; emptyMissing["electron-account-renderer-state-v1"] = emptyMissingState
        try write(a.data, authURL); try write(json(emptyMissing), stateURL, 0o644)
        try activateAccount(b, authURL: authURL, isRunning: { false })
        precondition(try! Data(contentsOf: authURL) == b.data)
        for field in ["project-order", "thread-project-assignments"] {
            var same = state()
            same[field] = field == "project-order" ? ["ghost"] : ["remote": ["projectKind": "local", "projectId": "remote-id"]]
            let bytes = try json(same)
            try write(a.data, authURL); try write(bytes, stateURL, 0o644)
            try activateAccount(a, authURL: authURL, isRunning: { false })
            precondition(try! Data(contentsOf: authURL) == a.data)
            precondition(try! Data(contentsOf: stateURL) == bytes)
        }
        var mixed = state(), mixedAssignments = mixed["thread-project-assignments"] as! [String: Any]
        mixedAssignments["remote"] = ["projectKind": "remote", "projectId": "remote-id"]
        mixed["thread-project-assignments"] = mixedAssignments
        let mixedOutput = try object(NativeProjectState.prepare(json(mixed), source: a, target: b)!)
        let mixedState = mixedOutput["electron-account-renderer-state-v1"] as! [String: Any]
        let mixedSlots = mixedState["inactive"] as! [String: Any]
        let mixedTarget = (mixedSlots["owner-B"] as! [String: Any])["globals"] as! [String: Any]
        precondition((mixedTarget["thread-project-assignments"] as! [String: Any])["remote"] == nil)
        var remoteTarget = state(), remoteRenderer = remoteTarget["electron-account-renderer-state-v1"] as! [String: Any]
        var remoteSlots = remoteRenderer["inactive"] as! [String: Any], remoteSlot = remoteSlots["owner-B"] as! [String: Any], remoteGlobals = remoteSlot["globals"] as! [String: Any]
        remoteGlobals["thread-project-assignments"] = ["remote": ["projectKind": "remote", "projectId": "remote-id"]]
        remoteGlobals["project-order"] = ["remote-id", "b"]
        remoteGlobals["sidebar-project-thread-orders"] = ["remote-id": ["threadIds": ["remote"]], "b": ["threadIds": ["thread-b"]]]
        remoteSlot["globals"] = remoteGlobals; remoteSlots["owner-B"] = remoteSlot; remoteRenderer["inactive"] = remoteSlots; remoteTarget["electron-account-renderer-state-v1"] = remoteRenderer
        let remoteOutput = try object(NativeProjectState.prepare(json(remoteTarget), source: a, target: b)!)
        let remoteState = remoteOutput["electron-account-renderer-state-v1"] as! [String: Any], remoteInactive = remoteState["inactive"] as! [String: Any]
        let remoteResult = (remoteInactive["owner-B"] as! [String: Any])["globals"] as! [String: Any]
        let assignments = remoteResult["thread-project-assignments"] as! [String: Any]
        precondition((assignments["remote"] as! [String: String])["projectKind"] == "remote" && assignments["thread-a"] != nil)
        precondition(remoteResult["project-order"] as! [String] == ["remote-id", "b", "a"])
        precondition(((remoteResult["sidebar-project-thread-orders"] as! [String: Any])["remote-id"] as! [String: [String]])["threadIds"] == ["remote"])
        var boolConflict = state(), boolRenderer = boolConflict["electron-account-renderer-state-v1"] as! [String: Any]
        var boolSlots = boolRenderer["inactive"] as! [String: Any], boolSlot = boolSlots["owner-B"] as! [String: Any], boolGlobals = boolSlot["globals"] as! [String: Any]
        boolConflict["project-appearances"] = ["a": ["flag": true]]
        boolGlobals["project-appearances"] = ["a": ["flag": 1]]
        boolSlot["globals"] = boolGlobals; boolSlots["owner-B"] = boolSlot; boolRenderer["inactive"] = boolSlots; boolConflict["electron-account-renderer-state-v1"] = boolRenderer
        let boolBytes = try json(boolConflict)
        do {
            _ = try NativeProjectState.merge(boolBytes, targetPath: ["electron-account-renderer-state-v1", "inactive", "owner-B", "globals"],
                                             sourceData: boolBytes, sourcePath: [])
            fatalError("strict recovery accepted different metadata")
        } catch PotetoError.projectState { }
        let base = String(data: try json(state()), encoding: .utf8)!
        for literal in ["9007199254740993", "1.2345678901234567890123456789", "5e-324", "-0"] {
            let input = Data(base.replacingOccurrences(of: "\"other\":1", with: "\"other\":\(literal)").utf8)
            precondition(input != Data(base.utf8))
            try write(a.data, authURL); try write(input, stateURL, 0o644)
            try activateAccount(b, authURL: authURL, isRunning: { false })
            let output = try Data(contentsOf: stateURL)
            precondition(String(decoding: output, as: UTF8.self).contains("\"other\":\(literal)"))
        }
        var remoteSource = state()
        remoteSource["project-order"] = ["remote-id", "a"]
        remoteSource["pinned-project-ids"] = ["remote-id", "a"]
        remoteSource["sidebar-project-thread-orders"] = ["remote-id": ["threadIds": ["remote-thread"]], "a": ["threadIds": ["thread-a", "remote-thread"]]]
        remoteSource["thread-project-assignments"] = ["remote-thread": ["projectKind": "remote", "projectId": "remote-id"], "thread-a": ["projectKind": "local", "projectId": "a"]]
        remoteSource["thread-workspace-root-hints"] = ["remote-thread": "/remote", "thread-a": "/synthetic/shared"]
        let remoteSourceBytes = try json(remoteSource)
        let inherited = try object(NativeProjectState.prepare(remoteSourceBytes, source: a, target: b)!)
        let inheritedRenderer = inherited["electron-account-renderer-state-v1"] as! [String: Any]
        let inheritedSlots = inheritedRenderer["inactive"] as! [String: Any]
        let inheritedGlobals = (inheritedSlots["owner-B"] as! [String: Any])["globals"] as! [String: Any]
        precondition(inheritedGlobals["project-order"] as! [String] == ["b", "a"])
        precondition(inheritedGlobals["pinned-project-ids"] as! [String] == ["a"])
        precondition((inheritedGlobals["sidebar-project-thread-orders"] as! [String: Any])["remote-id"] == nil)
        let inheritedSidebars = inheritedGlobals["sidebar-project-thread-orders"] as! [String: [String: [String]]]
        precondition(inheritedSidebars["a"]?["threadIds"] == ["thread-a"], "remote thread leaked into inherited local sidebar")
        precondition((inheritedGlobals["thread-project-assignments"] as! [String: Any])["remote-thread"] == nil)
        precondition((inheritedGlobals["thread-workspace-root-hints"] as! [String: Any])["remote-thread"] == nil)
        var collision = remoteSource
        collision["thread-project-assignments"] = ["remote-thread": ["projectKind": "remote", "projectId": "a"]]
        try rejected(json(collision))
        var targetCollision = state(), collisionRenderer = targetCollision["electron-account-renderer-state-v1"] as! [String: Any]
        var collisionSlots = collisionRenderer["inactive"] as! [String: Any], collisionSlot = collisionSlots["owner-B"] as! [String: Any]
        var collisionGlobals = collisionSlot["globals"] as! [String: Any]
        collisionGlobals["thread-project-assignments"] = ["remote-thread": ["projectKind": "remote", "projectId": "a"]]
        collisionSlot["globals"] = collisionGlobals; collisionSlots["owner-B"] = collisionSlot
        collisionRenderer["inactive"] = collisionSlots; targetCollision["electron-account-renderer-state-v1"] = collisionRenderer
        try rejected(json(targetCollision))
        for field in ["project-order", "pinned-project-ids", "sidebar-project-thread-orders"] {
            var unknown = remoteSource
            unknown[field] = field == "sidebar-project-thread-orders" ? ["unknown": ["threadIds": []]] : ["unknown"]
            let output = try NativeProjectState.prepare(json(unknown), source: a, target: b)!
            let selected = try object(select(output, "owner-B"))
            precondition((selected["project-order"] as? [String])?.contains("unknown") == false)
            precondition((selected["pinned-project-ids"] as? [String])?.contains("unknown") != true)
            precondition((selected["sidebar-project-thread-orders"] as? [String: Any])?["unknown"] == nil)
        }
        let rootMerged = try NativeProjectState.merge(try json(globals("b")), targetPath: [], sourceData: remoteSourceBytes, sourcePath: [])
        let rootResult = try object(rootMerged)
        precondition(Set((rootResult["local-projects"] as! [String: Any]).keys) == ["a", "b"])
        precondition((rootResult["thread-project-assignments"] as! [String: Any])["remote-thread"] == nil)
        let numericSource = Data("{\"local-projects\":{\"a\":{\"id\":\"a\",\"name\":\"a\",\"rootPaths\":[\"/synthetic/shared\"],\"createdAt\":1,\"updatedAt\":2}},\"project-appearances\":{\"a\":{\"amount\":1.2345678901234567890123456789}}}".utf8)
        let numericTarget = Data("{\"unrelated\":-0,\"local-projects\":{},\"project-appearances\":{\"remote\":{\"amount\":5e-324}}}".utf8)
        let numericMerged = try NativeProjectState.merge(numericTarget, targetPath: [], sourceData: numericSource, sourcePath: [])
        let numericText = String(decoding: numericMerged, as: UTF8.self)
        precondition(numericText.contains("\"unrelated\":-0") && numericText.contains("\"amount\":5e-324"))
        precondition(numericText.contains("\"amount\":1.2345678901234567890123456789"))
        let numericRepeated = try NativeProjectState.merge(numericMerged, targetPath: [], sourceData: numericSource, sourcePath: [])
        precondition(numericRepeated == numericMerged)
        let conflictingNumeric = Data(String(decoding: numericSource, as: UTF8.self).replacingOccurrences(of: "1.2345678901234567890123456789", with: "1.2345678901234567890123456788").utf8)
        do { _ = try NativeProjectState.merge(conflictingNumeric, targetPath: [], sourceData: numericSource, sourcePath: []); fatalError("numeric conflict accepted") } catch PotetoError.projectState { }
        var conflict = state(), renderer = conflict["electron-account-renderer-state-v1"] as! [String: Any], inactive = renderer["inactive"] as! [String: Any], slot = inactive["owner-B"] as! [String: Any], target = slot["globals"] as! [String: Any]
        var changedProject = project("a"); changedProject["rootPaths"] = ["/synthetic/different"]; target["local-projects"] = ["a": changedProject]; slot["globals"] = target; inactive["owner-B"] = slot; renderer["inactive"] = inactive; conflict["electron-account-renderer-state-v1"] = renderer
        try write(a.data, authURL); try write(json(conflict), stateURL, 0o644)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("conflict accepted") } catch PotetoError.projectState { }
        precondition(try! Data(contentsOf: authURL) == a.data)
        var missing = state(), missingState = missing["electron-account-renderer-state-v1"] as! [String: Any]
        missingState["inactive"] = [:]; missing["electron-account-renderer-state-v1"] = missingState
        try write(json(missing), stateURL, 0o644)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("missing target accepted") } catch PotetoError.projectNeedsInitialization { }
        var wrong = state(); wrong["electron-persisted-atom-state"] = atom("C")
        try write(json(wrong), stateURL, 0o644)
        do { try activateAccount(b, authURL: authURL, isRunning: { false }); fatalError("wrong source accepted") } catch PotetoError.projectState { }
        var threadConflict = state(), rs = threadConflict["electron-account-renderer-state-v1"] as! [String: Any], slots = rs["inactive"] as! [String: Any], bs = slots["owner-B"] as! [String: Any], bg = bs["globals"] as! [String: Any]
        threadConflict["projectless-thread-ids"] = NSNull()
        bg["projectless-thread-ids"] = NSNull()
        bg["thread-project-assignments"] = ["thread-a": ["projectKind": "local", "projectId": "b"]]; bs["globals"] = bg; slots["owner-B"] = bs; rs["inactive"] = slots; threadConflict["electron-account-renderer-state-v1"] = rs
        try write(json(threadConflict), stateURL, 0o644)
        try activateAccount(b, authURL: authURL, isRunning: { false })
        let movedLayout = try object(select(Data(contentsOf: stateURL), "owner-B"))
        precondition((movedLayout["thread-project-assignments"] as? [String: [String: String]])?["thread-a"]?["projectId"] == "b")
        precondition(movedLayout["projectless-thread-ids"] is NSNull)
        precondition(try! Data(contentsOf: authURL) == b.data)
        try write(a.data, authURL)
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
        precondition(try! NativeProjectState.prepare(json(nullRoot), source: a, target: a) == nil)
        try write(json(nullRoot), stateURL, 0o644); try activateAccount(b, authURL: authURL, isRunning: { false })
        let nullPrepared = try object(Data(contentsOf: stateURL)), nullRenderer = nullPrepared["electron-account-renderer-state-v1"] as! [String: Any], nullInactive = nullRenderer["inactive"] as! [String: Any], nullB = nullInactive["owner-B"] as! [String: Any], nullGlobals = nullB["globals"] as! [String: Any]
        precondition(nullRenderer["owner"] is NSNull)
        precondition((nullPrepared["electron-persisted-atom-state"] as! NSDictionary) == (atom("A") as NSDictionary))
        precondition(Set((nullGlobals["local-projects"] as! [String: Any]).keys) == ["a", "b"])
        precondition(nullGlobals["project-order"] as! [String] == ["b", "a"])
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
        try recoveryTests(dir: dir, authURL: authURL, stateURL: stateURL, write: write)
        print("Synthetic project inheritance tests passed")
    }
    static func recoveryTests(dir: URL, authURL: URL, stateURL: URL, write: (Data, URL, Int) throws -> Void) throws {
        let backup = dir.appendingPathComponent("backups"), a = try bundle("A")
        let initial = try json(state())
        try write(a.data, authURL, 0o600); try write(initial, stateURL, 0o644)
        let status = try ProjectRecovery.status(authURL: authURL, isRunning: { true })
        precondition(status.nativeClientRunning && status.localProjects == 1 && status.localAssignments == 1)
        precondition(status.sources.count == 1 && status.sources[0].slot == "owner-B")
        let report = String(data: try JSONEncoder().encode(status), encoding: .utf8)!
        precondition(!report.contains("fake") && !report.contains("/synthetic") && !report.contains("thread-b"))
        do { _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { true }); fatalError("running accepted") } catch PotetoError.running { }
        precondition(try! Data(contentsOf: stateURL) == initial)
        let result = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { false })
        precondition(result.restored && result.localProjects == 2 && result.localAssignments == 2)
        let files = try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
        precondition(files.count == 1 && (try! Data(contentsOf: files[0])) == initial)
        let attrs = try FileManager.default.attributesOfItem(atPath: files[0].path)
        precondition((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
        let restored = try Data(contentsOf: stateURL)
        let root = try object(restored)
        precondition(Set((root["local-projects"] as! [String: Any]).keys) == ["a", "b"])
        precondition(try! Data(contentsOf: authURL) == a.data)
        let repeated = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { false })
        precondition(!repeated.restored && (try! Data(contentsOf: stateURL)) == restored)
        do { _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, sourceSlot: "missing", isRunning: { false }); fatalError("unknown source accepted") } catch PotetoError.projectSource { }
        var ambiguous = state(), renderer = ambiguous["electron-account-renderer-state-v1"] as! [String: Any]
        var slots = renderer["inactive"] as! [String: Any]
        slots.removeValue(forKey: "other")
        slots["owner-C"] = ["atoms": atom("C"), "globals": globals("c")]
        renderer["inactive"] = slots; ambiguous["electron-account-renderer-state-v1"] = renderer
        let ambiguousBytes = try json(ambiguous); try write(ambiguousBytes, stateURL, 0o644)
        do { _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { false }); fatalError("ambiguous sources accepted") } catch PotetoError.projectAmbiguous { }
        precondition(try! Data(contentsOf: stateURL) == ambiguousBytes)
        let selected = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, sourceSlot: "owner-C", isRunning: { false })
        precondition(selected.restored && selected.sourceSlot == "owner-C")
        var mixed = state(), mixedRenderer = mixed["electron-account-renderer-state-v1"] as! [String: Any]
        var mixedSlots = mixedRenderer["inactive"] as! [String: Any]
        mixedSlots.removeValue(forKey: "other")
        mixedSlots["owner-B"] = ["atoms": atom("B"), "globals": globals("a")]
        mixedSlots["owner-C"] = ["atoms": atom("C"), "globals": globals("c")]
        mixedRenderer["inactive"] = mixedSlots; mixed["electron-account-renderer-state-v1"] = mixedRenderer
        try write(json(mixed), stateURL, 0o644)
        do { _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { false }); fatalError("no-op and changing sources accepted") } catch PotetoError.projectAmbiguous { }
        var precise = state(), preciseRenderer = precise["electron-account-renderer-state-v1"] as! [String: Any]
        var preciseSlots = preciseRenderer["inactive"] as! [String: Any]
        preciseSlots.removeValue(forKey: "other")
        var left = globals("b"), right = globals("b")
        left["project-appearances"] = ["b": ["value": "BIG_ONE"]]
        right["project-appearances"] = ["b": ["value": "BIG_TWO"]]
        preciseSlots["owner-B"] = ["atoms": atom("B"), "globals": left]
        preciseSlots["owner-C"] = ["atoms": atom("C"), "globals": right]
        preciseRenderer["inactive"] = preciseSlots; precise["electron-account-renderer-state-v1"] = preciseRenderer
        let preciseText = String(data: try json(precise), encoding: .utf8)!
            .replacingOccurrences(of: "\"BIG_ONE\"", with: "9007199254740992")
            .replacingOccurrences(of: "\"BIG_TWO\"", with: "9007199254740993")
        try write(Data(preciseText.utf8), stateURL, 0o644)
        do { _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { false }); fatalError("distinct numeric bytes accepted") } catch PotetoError.projectAmbiguous { }
        var none = state(), noneRenderer = none["electron-account-renderer-state-v1"] as! [String: Any]
        for key in ["local-projects", "project-order", "thread-project-assignments", "project-appearances", "sidebar-project-thread-orders"] { none.removeValue(forKey: key) }
        noneRenderer["inactive"] = [:]; none["electron-account-renderer-state-v1"] = noneRenderer
        try write(json(none), stateURL, 0o644)
        do { _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { false }); fatalError("empty state without source accepted") } catch PotetoError.projectSource { }
        var unsafe = state(), unsafeRenderer = unsafe["electron-account-renderer-state-v1"] as! [String: Any]
        var unsafeSlots = unsafeRenderer["inactive"] as! [String: Any]
        unsafeSlots["unsafe\nslot"] = unsafeSlots.removeValue(forKey: "owner-B")
        unsafeRenderer["inactive"] = unsafeSlots; unsafe["electron-account-renderer-state-v1"] = unsafeRenderer
        try write(json(unsafe), stateURL, 0o644)
        let unsafeStatus = try ProjectRecovery.status(authURL: authURL, isRunning: { false })
        precondition(unsafeStatus.sources.isEmpty)
        do { _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, sourceSlot: "unsafe\nslot", isRunning: { false }); fatalError("unsafe slot accepted") } catch PotetoError.projectSource { }
        var conflicting = state(), conflictRenderer = conflicting["electron-account-renderer-state-v1"] as! [String: Any]
        var conflictSlots = conflictRenderer["inactive"] as! [String: Any], conflictSlot = conflictSlots["owner-B"] as! [String: Any]
        var conflictGlobals = globals("b"), conflictProject = project("a")
        conflictProject["name"] = "different"; conflictGlobals["local-projects"] = ["a": conflictProject, "b": project("b")]
        conflictSlot["globals"] = conflictGlobals; conflictSlots["owner-B"] = conflictSlot
        conflictRenderer["inactive"] = conflictSlots; conflicting["electron-account-renderer-state-v1"] = conflictRenderer
        try write(json(conflicting), stateURL, 0o644)
        do { _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { false }); fatalError("conflict ignored") } catch PotetoError.projectState { }
        try write(initial, stateURL, 0o644)
        let backupCount = try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil).count
        var race = 0
        do {
            _ = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: {
                race += 1
                if race == 2 { try! write(Data("external".utf8), stateURL, 0o644) }
                return false
            }); fatalError("state race accepted")
        } catch PotetoError.changed { }
        precondition(try! Data(contentsOf: stateURL) == Data("external".utf8))
        precondition((try! FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)).count == backupCount)
        var bad = state(); bad["electron-persisted-atom-state"] = atom("C")
        try write(json(bad), stateURL, 0o644)
        do { _ = try ProjectRecovery.status(authURL: authURL, isRunning: { false }); fatalError("wrong identity accepted") } catch PotetoError.projectState { }
        var nullRoot = state(), nullState = nullRoot["electron-account-renderer-state-v1"] as! [String: Any]
        var nullSlots = nullState["inactive"] as! [String: Any]
        nullSlots["owner-A"] = ["atoms": atom("A"), "globals": globals("a")]
        nullState["owner"] = NSNull(); nullState["inactive"] = nullSlots; nullRoot["electron-account-renderer-state-v1"] = nullState
        try write(json(nullRoot), stateURL, 0o644)
        let nullResult = try ProjectRecovery.restore(authURL: authURL, backupDirectory: backup, isRunning: { false })
        precondition(nullResult.restored && nullResult.localProjects == 2)
        let selectedRoot = try object(select(Data(contentsOf: stateURL), "owner-A"))
        precondition(Set((selectedRoot["local-projects"] as! [String: Any]).keys) == ["a", "b"])
    }

}
