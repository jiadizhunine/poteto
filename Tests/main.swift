import Foundation
import Darwin

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
    guard try condition() else { fatalError(description) }; checks += 1
}
func rejected(_ description: String, _ action: () throws -> Void) throws {
    do { try action(); fatalError("not rejected: \(description)") } catch { checks += 1 }
}
func fixtureAuth(_ email: String, workspace: String = "fixture-workspace", refresh: String = "fixture-refresh", refreshed: String = "2026-10-11T12:00:00Z") throws -> AuthBundle {
    let claims: [String: Any] = ["email": email, "sub": "fixture-user", "https://api.openai.com/auth": ["chatgpt_account_id": workspace, "chatgpt_plan_type": "pro"]]
    let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    let d: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["id_token": "e30.\(payload).c2ln", "access_token": "fixture-access", "refresh_token": refresh, "account_id": workspace], "last_refresh": refreshed, "unknown_native_field": ["keep": true]]
    return AuthBundle(data: try JSONSerialization.data(withJSONObject: d, options: .sortedKeys))
}
func usageFixture(_ email: String, used: Any = 37, extra: [String: Any] = [:]) throws -> Data {
    var d: [String: Any] = ["account_id": "fixture-workspace", "email": email, "plan_type": "pro", "rate_limit": ["allowed": true, "primary_window": ["used_percent": used, "limit_window_seconds": 18_000, "reset_at": 1_900_000_000], "secondary_window": ["used_percent": 77, "limit_window_seconds": 604_800]], "code_review_rate_limit": ["primary_window": ["used_percent": 100, "limit_window_seconds": 604_800]]]
    for (k, v) in extra { d[k] = v }; return try JSONSerialization.data(withJSONObject: d)
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("poteto-test-\(UUID().uuidString)", isDirectory: true)
try PrivateFiles.directory(folder)
defer { try? FileManager.default.removeItem(at: folder) }
let a = try fixtureAuth("a@example.invalid"), b = try fixtureAuth("b@example.invalid")
try check(a.identity.email == "a@example.invalid", "identity")
try check(a.identity.id != b.identity.id, "identity separation")
try rejected("missing identity") { _ = try AuthBundle(data: Data("{}".utf8)).identity }
var mismatch = try a.document, tokens = mismatch["tokens"] as! [String: Any]; tokens["account_id"] = "other-workspace"; mismatch["tokens"] = tokens
try rejected("workspace mismatch") { _ = try AuthBundle(data: JSONSerialization.data(withJSONObject: mismatch)).identity }
var vault = Vault(); try vault.put(a, fromNative: true); try vault.put(b)
try check(vault.accounts.count == 2, "migrate accounts")
try vault.put(a, fromNative: true); try check(vault.accounts.count == 2, "deduplicate")
let rotated = try a.replacingTokens(["access_token": "fixture-new-access", "refresh_token": "fixture-new-refresh"])
try check(rotated.identity.id == a.identity.id, "refresh identity retained")
try check((rotated.document["unknown_native_field"] as? [String: Bool])?["keep"] == true, "unknown native field retained")
try vault.put(rotated); try vault.put(a, fromNative: true)
try check(vault.accounts[0].auth.token("refresh_token") == "fixture-new-refresh", "do not restore stale native refresh")
try vault.validate(); try check(try JSONDecoder().decode(Vault.self, from: JSONEncoder().encode(vault)) == vault, "vault round trip")

let usage = try parseUsage(usageFixture("a@example.invalid"), for: a.identity)
try check(usage.windows.count == 3, "all windows including review")
try check(usage.ordinaryRemaining == 23, "review must not exhaust ordinary quota")
try check(usage.windows.map(\.durationMinutes).contains(300), "actual window duration")
try check(usage.windows[0].reset?.timeIntervalSince1970 == 1_900_000_000, "actual reset")
try rejected("wrong email") { _ = try parseUsage(usageFixture("b@example.invalid"), for: a.identity) }
let over = try parseUsage(usageFixture("a@example.invalid", used: 130), for: a.identity)
try check(over.windows.contains(where: { $0.ordinary && $0.remaining == 0 }), "over-quota clamps remaining")
let bool = try parseUsage(usageFixture("a@example.invalid", used: true), for: a.identity)
try check(bool.windows.filter(\.ordinary).count == 1, "boolean percent is not numeric zero")
let missing: [String: Any] = ["account_id": "fixture-workspace", "email": "a@example.invalid", "rate_limit": ["primary_window": ["limit_window_seconds": 300]]]
try rejected("missing percent is not zero") { _ = try parseUsage(JSONSerialization.data(withJSONObject: missing), for: a.identity) }
try rejected("oversize response") { _ = try parseUsage(Data(repeating: 32, count: 262_145), for: a.identity) }
try check(safeLabel("Bearer fixture-secret") == nil, "redact server label")
try check(safeLabel("unsafe\ntext") == nil, "reject control label")

let authFile = folder.appendingPathComponent("auth.json"), config = folder.appendingPathComponent("config.toml"), history = folder.appendingPathComponent("history.jsonl")
try PrivateFiles.write(a.data, to: authFile)
let originalConfig = Data("model = \"fixture-model\"\nmodel_reasoning_effort = \"max\"\n".utf8), originalHistory = Data("{\"fixture\":\"history\"}\n".utf8)
try PrivateFiles.write(originalConfig, to: config); try PrivateFiles.write(originalHistory, to: history)
try rejected("busy native switch") { try activateAccount(b, authURL: authFile, isRunning: { true }) }
try check(PrivateFiles.read(authFile) == a.data, "busy switch leaves auth")
var gate = 0
try rejected("startup during switch") { try activateAccount(b, authURL: authFile, isRunning: { gate += 1; return gate == 3 }) }
try check(PrivateFiles.read(authFile) == b.data, "startup race does not overwrite native credentials")
try activateAccount(b, authURL: authFile, isRunning: { false })
try check(PrivateFiles.read(authFile) == b.data, "closed native switch accepted")
try check(PrivateFiles.read(config) == originalConfig && PrivateFiles.read(history) == originalHistory, "switch preserves config/history bytes")
var info = stat(); _ = lstat(authFile.path, &info); try check(info.st_mode & 0o077 == 0, "0600 credential mode")
let old = try PrivateFiles.snapshot(authFile); try PrivateFiles.write(a.data, to: authFile)
try rejected("compare and set race") { try PrivateFiles.write(b.data, to: authFile, expected: old, compare: true) }
let link = folder.appendingPathComponent("auth-link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: authFile)
try rejected("symlink read") { _ = try PrivateFiles.read(link) }
try rejected("symlink write") { try PrivateFiles.write(a.data, to: link) }
let hard = folder.appendingPathComponent("auth-hard"); guard Darwin.link(authFile.path, hard.path) == 0 else { fatalError("hardlink fixture") }
try rejected("hardlink read") { _ = try PrivateFiles.read(authFile) }; try FileManager.default.removeItem(at: hard)
_ = chmod(authFile.path, 0o644); try rejected("public credential") { _ = try PrivateFiles.read(authFile) }; _ = chmod(authFile.path, 0o600)
let lockURL = folder.appendingPathComponent("runtime.lock")
do { let lock = try InstanceLock(lockURL); withExtendedLifetime(lock) { do { _ = try InstanceLock(lockURL); fatalError("second instance") } catch { checks += 1 } } }
do { let lock = try InstanceLock(lockURL); withExtendedLifetime(lock) { checks += 1 } }
try check(OfficialHTTP.usage.host == "chatgpt.com" && OfficialHTTP.token.host == "auth.openai.com", "only official fixed endpoints")
try check(OfficialHTTP.session.configuration.httpCookieStorage == nil && OfficialHTTP.session.configuration.urlCache == nil, "no cookie/cache persistence")

let source = try String(contentsOfFile: "Sources/PotetoApp.swift", encoding: .utf8)
try check(!source.contains("StartInterval") && !source.contains("StartCalendarInterval"), "no scheduler tasks")
try check(!source.contains("app-server-restart") && !source.contains("remote-debugging-port"), "no backend takeover")
try check(!source.contains("killCodexProcess") && !source.contains("electronBridge"), "no injection or forced quit")
try check(source.contains("mayRefresh, try currentFileID() != id"), "current native account refresh is not taken over")

let credited = try parseUsage(usageFixture("a@example.invalid", extra: [
    "credits": ["has_credits": true, "unlimited": false, "balance": "56509.1182155000"],
    "rate_limit_reset_credits": ["available_count": 4, "applicable_available_count": 2]
]), for: a.identity)
try check(credited.credits?.balance == "56509.1182155", "balance preserves precise official value")
try check(credited.credits?.formattedBalance == "56,509.12", "grouped official credit balance, not currency")
try check(credited.resetAllowance?.availableCount == 4 && credited.resetAllowance?.applicableCount == 2, "authoritative total and applicable resets")
try check(credited.credits?.expiresAt == nil, "no invented credit expiry")
for invalid: Any in [true, "NaN", "-1", "1e12", "Bearer fixture-secret"] {
    try check(parseBalance(["balance": invalid]) == nil, "invalid balance does not become zero")
}
try check(parseBalance(["balance": "0"])?.balance == "0", "explicit zero balance retained")
try check(parseBalance(["unlimited": true])?.unlimited == true, "unlimited credits remain explicit")
try check(parseResetAllowance(["available_count": true]) == nil && parseResetAllowance(["available_count": -1]) == nil, "invalid reset count is unknown, not zero")
try check(parseResetAllowance(["available_count": 0])?.availableCount == 0, "real zero earned resets")
let resetRows: [[String: Any]] = [
    ["id": "credit-1", "status": "available", "title": "Full reset", "expires_at": "2026-11-17T00:00:00Z"],
    ["id": "credit-2", "status": "available", "expires_at": NSNull()],
    ["id": "credit-1", "status": "available", "expires_at": "2026-11-17T00:00:00Z"],
    ["id": "credit-spent", "status": "redeemed", "expires_at": "2026-11-17T00:00:00Z"]
]
let detailsData = try JSONSerialization.data(withJSONObject: ["credits": resetRows, "available_count": 4])
let details = try parseResetDetails(detailsData, summary: credited.resetAllowance!, identity: a.identity)
try check(details.availableCount == 4 && details.credits?.count == 2, "partial rows do not replace authoritative reset count")
try check(details.credits?.first?.expiresAt == serviceDate("2026-11-17T00:00:00Z"), "official ISO reset expiration")
try check(details.credits?.last?.expiresAt == nil, "null expiry remains unspecified")
try check(serviceDate("2026-11-17T00:00:00.250Z") != nil && serviceDate(true) == nil, "fractional ISO date and invalid boolean")
try rejected("oversize reset details") { _ = try parseResetDetails(Data(repeating: 32, count: 262145), summary: details, identity: a.identity) }
try rejected("foreign reset details") { _ = try parseResetDetails(JSONSerialization.data(withJSONObject: ["credits": [], "account_id": "foreign"]), summary: details, identity: a.identity) }
let oldUsage = Data("{\"plan\":\"fixture\",\"windows\":[],\"checkedAt\":0}".utf8)
try check(try JSONDecoder().decode(Usage.self, from: oldUsage).credits == nil, "old local status remains decodable")
try check(!source.contains("@objc private func about") && !source.contains("refreshNow"), "removed about and manual refresh actions")
let resetNow = Date(timeIntervalSince1970: 1_900_000_000)
for query in 0..<2 {
    let observedWindow: [String: Any] = ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": 604_800, "reset_at": 1_900_604_800 + query * 3]
    let replay = try parseUsage(usageFixture("a@example.invalid", extra: ["rate_limit": ["primary_window": observedWindow]]), for: a.identity, now: resetNow.addingTimeInterval(Double(query) * 3.661350965499878))
    let window = replay.windows.first(where: \.ordinary)!
    try check(window.durationMinutes == 10_080 && window.remaining == 100, "synthetic observed query \(query + 1) retains period and remaining")
    try check(window.reset == nil, "synthetic observed query \(query + 1) has no fixed reset")
}
let resetCases: [(String, [String: Any], Double?)] = [
    ("zero full delay without absolute", ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": 604_800], nil),
    ("zero shorter delay absolute priority", ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": 604_799, "reset_at": 1_900_000_100], 1_900_000_100),
    ("zero shorter delay fallback", ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": 604_799], 1_900_604_799),
    ("tiny positive use full delay", ["used_percent": 0.1, "limit_window_seconds": 604_800, "reset_after_seconds": 604_800, "reset_at": 1_900_000_100], 1_900_000_100),
    ("positive use full delay", ["used_percent": 25, "limit_window_seconds": 604_800, "reset_after_seconds": 604_800, "reset_at": 1_900_000_100], 1_900_000_100),
    ("positive use full delay fallback", ["used_percent": 25, "limit_window_seconds": 604_800, "reset_after_seconds": 604_800], 1_900_604_800),
    ("missing delay absolute", ["used_percent": 0, "limit_window_seconds": 604_800, "reset_at": 1_900_000_100], 1_900_000_100),
    ("null delay absolute", ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": NSNull(), "reset_at": 1_900_000_100], 1_900_000_100),
    ("boolean delay absolute", ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": true, "reset_at": 1_900_000_100], 1_900_000_100),
    ("negative delay absolute", ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": -1, "reset_at": 1_900_000_100], 1_900_000_100),
    ("upper bound delay absolute", ["used_percent": 0, "limit_window_seconds": 144_000_000_000, "reset_after_seconds": 8_640_000_000_000, "reset_at": 1_900_000_100], 1_900_000_100),
    ("remaining only full delay", ["remaining_percent": 100, "limit_window_seconds": 604_800, "reset_after_seconds": 604_800, "reset_at": 1_900_000_100], 1_900_000_100),
    ("thirty day full delay", ["used_percent": 0, "limit_window_seconds": 2_592_000, "reset_after_seconds": 2_592_000, "reset_at": 1_902_592_000], nil),
    ("minute and usage aliases full delay", ["usedPercent": 0, "windowDurationMins": 43_200, "reset_after_seconds": 2_592_000, "resetsAt": 1_902_592_000], nil),
    ("effective minute duration priority", ["usedPercent": 0, "windowDurationMins": 43_200, "limit_window_seconds": 604_800, "reset_after_seconds": 604_800, "resetsAt": 1_900_000_100], 1_900_000_100),
    ("fractional delay is not full", ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": 604_799.9, "reset_at": 1_900_000_100], 1_900_000_100)
]
for (name, raw, expectedReset) in resetCases {
    let parsed = try parseUsage(usageFixture("a@example.invalid", extra: ["rate_limit": ["primary_window": raw]]), for: a.identity, now: resetNow)
    let window = parsed.windows.first(where: \.ordinary)!
    try check(window.reset?.timeIntervalSince1970 == expectedReset, name)
    if name == "tiny positive use full delay" {
        try check(window.remaining == 99.9 && window.remaining.rounded() == 100, "rounded full quota does not imply zero use")
    }
    if name == "thirty day full delay" || name == "minute and usage aliases full delay" {
        try check(window.durationMinutes == 43_200 && window.remaining == 100, "nonweekly duration and aliases retained")
    }
}
let mixedReset = try parseUsage(usageFixture("a@example.invalid", extra: [
    "rate_limit": [
        "primary_window": ["used_percent": 0, "limit_window_seconds": 18_000, "reset_after_seconds": 18_000, "reset_at": 1_900_018_000],
        "secondary_window": ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": 604_799, "reset_at": 1_900_000_100]
    ],
    "code_review_rate_limit": ["primary_window": ["used_percent": 0, "limit_window_seconds": 604_800, "reset_after_seconds": 604_800, "reset_at": 1_900_604_800]]
]), for: a.identity, now: resetNow)
try check(mixedReset.windows.count == 3, "mixed windows retained")
try check(mixedReset.windows.first(where: { $0.ordinary && $0.durationMinutes == 300 })?.reset == nil, "mixed short floating window independent")
try check(mixedReset.windows.first(where: { $0.ordinary && $0.durationMinutes == 10_080 })?.reset?.timeIntervalSince1970 == 1_900_000_100, "mixed fixed window independent")
try check(mixedReset.windows.first(where: { !$0.ordinary })?.reset == nil, "review window follows same reset rule")
try check(try JSONDecoder().decode(Usage.self, from: JSONEncoder().encode(mixedReset)).windows == mixedReset.windows, "nil and dated usage reset round trip")
for resetValue in ["", ",\"reset\":null", ",\"reset\":100"] {
    let legacy = Data("{\"plan\":\"fixture\",\"windows\":[{\"label\":\"Codex\",\"durationMinutes\":300,\"remaining\":100,\"ordinary\":true\(resetValue)}],\"checkedAt\":0}".utf8)
    let decoded = try JSONDecoder().decode(Usage.self, from: legacy)
    try check(decoded.windows.first?.reset == (resetValue == ",\"reset\":100" ? Date(timeIntervalSinceReferenceDate: 100) : nil), "missing null and legacy dated usage reset decode \(resetValue)")
}
print("poteto: \(checks) checks passed")
