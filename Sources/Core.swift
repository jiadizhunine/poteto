import Foundation
import Security
import LocalAuthentication
import Darwin

enum PotetoError: Error, LocalizedError {
    case invalidAuth, privateFile, changed, missingAccount, running, startupRace, network, loginRequired, wrongIdentity, malformed, projectState, projectPartial, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .projectState: return "本地项目状态不受支持、身份无法确认或存在冲突；未切换账号。请先检查原生项目和目标账号。"
        case .projectPartial: return "目标账号的本地项目已准备，但账号切换未完成；请确认当前登录后重试。"
        case .invalidAuth: return "登录凭据格式无效；未更改原账号。"
        case .privateFile: return "凭据必须是本用户独占的普通文件，不能使用符号链接。"
        case .changed: return "账号凭据正在变化，请稍后重试。"
        case .missingAccount: return "未找到此账号，请重新打开菜单。"
        case .running: return "请先手动正常退出 ChatGPT/Codex，再点切换。运行中不会切换或自动关闭。"
        case .startupRace: return "检测到 Codex 在切换过程中启动。已停止操作，请确认当前登录；不会强退或回写旧凭据。"
        case .network: return "额度暂时查询失败，请稍后刷新。"
        case .loginRequired: return "登录凭据已失效，请通过原生登录或重新添加此账号。"
        case .wrongIdentity: return "服务端身份与保存的账号不一致，未采用结果。"
        case .malformed: return "官方响应格式未确认，未猜测额度。"
        case .keychain(let code): return "暂时无法访问本机钥匙串（\(code)）；解锁后重试。"
        }
    }
}

func safeLabel(_ value: Any?, max: Int = 180) -> String? {
    guard let s = value as? String, !s.isEmpty, s.count <= max,
          !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          !s.contains("Bearer "), !s.hasPrefix("sk-") else { return nil }
    return s
}

struct Identity: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let workspace: String
    let plan: String?
}

struct NativeAccountDescriptor: Equatable {
    let accountId: String
    let userId: String

    init(auth: AuthBundle) throws {
        _ = try auth.identity
        guard let jwt = try auth.token("id_token") else { throw PotetoError.invalidAuth }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw PotetoError.invalidAuth }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { throw PotetoError.invalidAuth }
        var keys = UniqueJSONKeys(bytes: Array(data))
        do { try keys.validate() } catch { throw PotetoError.invalidAuth }
        guard let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let namespace = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = safeLabel(namespace["chatgpt_account_id"]) else { throw PotetoError.invalidAuth }
        let first = safeLabel(namespace["chatgpt_user_id"]), second = safeLabel(namespace["user_id"])
        guard (namespace["chatgpt_user_id"] == nil || first != nil),
              (namespace["user_id"] == nil || second != nil),
              first == nil || second == nil || first == second,
              let user = first ?? second else { throw PotetoError.invalidAuth }
        accountId = account; userId = user
    }
}

struct AuthBundle: Codable, Equatable, Sendable {
    let data: Data
    var document: [String: Any] {
        get throws {
            guard data.count <= 1_048_576,
                  let d = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  d["auth_mode"] == nil || ["chatgpt", "chatgptAuthTokens"].contains(d["auth_mode"] as? String ?? ""),
                  let t = d["tokens"] as? [String: Any] else { throw PotetoError.invalidAuth }
            for key in ["access_token", "refresh_token", "id_token", "account_id"] {
                if let v = t[key] {
                    guard let s = v as? String, !s.isEmpty, s.utf8.count <= 262_144,
                          !s.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw PotetoError.invalidAuth }
                }
            }
            return d
        }
    }
    func token(_ key: String) throws -> String? { (try document["tokens"] as? [String: Any])?[key] as? String }
    var identity: Identity {
        get throws {
            guard let jwt = try token("id_token") else { throw PotetoError.invalidAuth }
            let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) }) else { throw PotetoError.invalidAuth }
            var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            b += String(repeating: "=", count: (4 - b.count % 4) % 4)
            guard let decoded = Data(base64Encoded: b),
                  let claims = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
                  let subject = safeLabel(claims["email"]) ?? safeLabel(claims["sub"]) else { throw PotetoError.invalidAuth }
            let namespace = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
            let claimed = safeLabel(namespace["chatgpt_account_id"]), selected = try token("account_id")
            if let claimed, let selected, claimed != selected { throw PotetoError.invalidAuth }
            guard let workspace = claimed ?? selected, safeLabel(workspace) != nil else { throw PotetoError.invalidAuth }
            let email = safeLabel(claims["email"]) ?? subject
            let idData = try JSONSerialization.data(withJSONObject: [email.lowercased(), workspace])
            return Identity(id: idData.base64EncodedString(), email: email, workspace: workspace, plan: safeLabel(namespace["chatgpt_plan_type"], max: 60))
        }
    }
    var refreshedAt: Date? {
        guard let d = try? document, let s = d["last_refresh"] as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    func replacingTokens(_ response: [String: Any]) throws -> AuthBundle {
        var d = try document, t = d["tokens"] as! [String: Any]
        guard let access = response["access_token"] as? String, !access.isEmpty else { throw PotetoError.malformed }
        for key in ["access_token", "refresh_token", "id_token"] {
            if let value = response[key] { t[key] = value }
        }
        d["tokens"] = t; d["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let result = AuthBundle(data: try JSONSerialization.data(withJSONObject: d, options: .sortedKeys))
        guard try result.identity.id == identity.id else { throw PotetoError.wrongIdentity }
        return result
    }
}

struct SavedAccount: Codable, Equatable, Sendable {
    var auth: AuthBundle
    var capturedRefresh: String?
}
struct Vault: Codable, Equatable, Sendable {
    var version = 1
    var accounts: [SavedAccount] = []
    mutating func put(_ auth: AuthBundle, fromNative: Bool = false) throws {
        let id = try auth.identity.id
        if let i = try accounts.firstIndex(where: { try $0.auth.identity.id == id }) {
            let saved = accounts[i]
            if let incoming = auth.refreshedAt, let previous = saved.auth.refreshedAt, incoming < previous { return }
            if fromNative, let captured = saved.capturedRefresh, captured == (try auth.token("refresh_token")),
               captured != (try saved.auth.token("refresh_token")) { return }
            accounts[i].auth = auth
            if fromNative { accounts[i].capturedRefresh = try auth.token("refresh_token") }
        } else {
            guard accounts.count < 128 else { throw PotetoError.malformed }
            accounts.append(SavedAccount(auth: auth, capturedRefresh: fromNative ? try auth.token("refresh_token") : nil))
        }
    }
    func validate() throws {
        guard version == 1, accounts.count <= 128 else { throw PotetoError.malformed }
        var ids = Set<String>()
        for account in accounts { guard try ids.insert(account.auth.identity.id).inserted else { throw PotetoError.malformed } }
    }
}

enum CredentialStore {
    static let service = "io.poteto.accounts"
    static func query() -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "vault-v1"] }
    static func load(allowInteraction: Bool = false) throws -> Vault {
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return Vault() }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 8_388_608 else { throw PotetoError.keychain(status) }
        let vault = try JSONDecoder().decode(Vault.self, from: data); try vault.validate(); return vault
    }
    static func save(_ vault: Vault) throws {
        try vault.validate()
        let data = try JSONEncoder().encode(vault); guard data.count <= 8_388_608 else { throw PotetoError.malformed }
        var q = query(); let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(); add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PotetoError.keychain(status) }
    }
}

struct PrivateSnapshot: Equatable {
    let device: dev_t; let inode: ino_t; let size: off_t; let timeSec: Int; let timeNano: Int; let changeSec: Int; let changeNano: Int
    init(_ s: stat) { device = s.st_dev; inode = s.st_ino; size = s.st_size; timeSec = s.st_mtimespec.tv_sec; timeNano = s.st_mtimespec.tv_nsec; changeSec = s.st_ctimespec.tv_sec; changeNano = s.st_ctimespec.tv_nsec }
}
enum PrivateFiles {
    static func directory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw PotetoError.privateFile }
    }
    static func snapshot(_ url: URL) throws -> PrivateSnapshot? {
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw PotetoError.privateFile }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & 0o077) == 0, info.st_size <= 8_388_608 else { throw PotetoError.privateFile }
        return PrivateSnapshot(info)
    }
    static func read(_ url: URL) throws -> Data? {
        guard let before = try snapshot(url) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw PotetoError.privateFile }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, PrivateSnapshot(info) == before else { throw PotetoError.changed }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { break }; guard n > 0, data.count + n <= 8_388_608 else { throw PotetoError.privateFile }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard fstat(fd, &info) == 0, PrivateSnapshot(info) == before, try snapshot(url) == before else { throw PotetoError.changed }
        return data
    }
    static func write(_ data: Data, to url: URL, expected: PrivateSnapshot? = nil, compare: Bool = false) throws {
        var parent = stat()
        guard lstat(url.deletingLastPathComponent().path, &parent) == 0,
              (parent.st_mode & S_IFMT) == S_IFDIR, parent.st_uid == getuid() else { throw PotetoError.privateFile }
        let before = try snapshot(url)
        if compare && before != expected { throw PotetoError.changed }
        guard data.count <= 8_388_608 else { throw PotetoError.privateFile }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".poteto-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PotetoError.privateFile }
        defer { close(fd); unlink(temp.path) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw PotetoError.privateFile }; offset += count
            }
        }
        guard fsync(fd) == 0, try snapshot(url) == before else { throw PotetoError.changed }
        guard rename(temp.path, url.path) == 0 else { throw PotetoError.privateFile }
    }
}

struct UsageWindow: Codable, Equatable, Sendable {
    let label: String
    let durationMinutes: Double
    let remaining: Double
    let reset: Date?
    let ordinary: Bool
}
struct CreditBalance: Codable, Equatable, Sendable {
    let balance: String?
    let unlimited: Bool
    let expiresAt: Date?
    var formattedBalance: String? {
        guard let balance, let value = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }
}
struct ResetCredit: Codable, Equatable, Sendable {
    let id: String
    let title: String?
    let expiresAt: Date?
}
struct ResetAllowance: Codable, Equatable, Sendable {
    let availableCount: Int
    let applicableCount: Int?
    let credits: [ResetCredit]?
}
struct ActivationObservation: Codable, Equatable, Sendable {
    enum Slot: String, Codable, Sendable { case primary = "primary_window", secondary = "secondary_window" }
    let slot: Slot
    let duration: Double
    let usedPercent: Double
    let unstarted: Bool
    let allUnused: Bool
    let sendAllowed: Bool
    let absoluteReset: Date?
    let serverTime: Date?
}
struct Usage: Codable, Sendable {
    let plan: String?
    let windows: [UsageWindow]
    let checkedAt: Date
    let credits: CreditBalance?
    var resetAllowance: ResetAllowance?
    var activation: ActivationObservation?
    var ordinaryRemaining: Double? { windows.filter(\.ordinary).map(\.remaining).min() }
    init(plan: String?, windows: [UsageWindow], checkedAt: Date, credits: CreditBalance? = nil, resetAllowance: ResetAllowance? = nil, activation: ActivationObservation? = nil) {
        self.activation = activation
        self.plan = plan; self.windows = windows; self.checkedAt = checkedAt
        self.credits = credits; self.resetAllowance = resetAllowance
    }
}
func number(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }; return n.doubleValue
}
func allowanceCount(_ value: Any?) -> Int? {
    guard let n = number(value), n >= 0, n <= 1_000_000, n.rounded(.towardZero) == n else { return nil }
    return Int(n)
}
func serviceDate(_ value: Any?) -> Date? {
    if let n = number(value), n >= 0, n < 253_402_300_800 { return Date(timeIntervalSince1970: n) }
    guard let text = value as? String, text.count <= 60 else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: text)
}
func parseBalance(_ raw: Any?) -> CreditBalance? {
    guard let raw = raw as? [String: Any] else { return nil }
    let unlimited = (raw["unlimited"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
    let text = (raw["balance"] as? String) ?? number(raw["balance"]).map { String($0) }
    var balance: String?
    if let text, text.range(of: "^[0-9]{1,18}(\\.[0-9]{1,18})?$", options: .regularExpression) != nil,
       let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN {
        balance = NSDecimalNumber(decimal: value).stringValue
    }
    guard balance != nil || unlimited else { return nil }
    return CreditBalance(balance: balance, unlimited: unlimited, expiresAt: serviceDate(raw["expires_at"] ?? raw["expiresAt"]))
}
func parseResetRows(_ value: Any?) throws -> [ResetCredit]? {
    if value == nil || value is NSNull { return nil }
    guard let rows = value as? [[String: Any]], rows.count <= 128 else { throw PotetoError.malformed }
    var result: [ResetCredit] = [], seen: Set<String> = []
    for row in rows {
        guard let id = safeLabel(row["id"], max: 180), seen.insert(id).inserted,
              (row["status"] as? String) == "available" else { continue }
        result.append(ResetCredit(id: id, title: safeLabel(row["title"], max: 70), expiresAt: serviceDate(row["expires_at"] ?? row["expiresAt"])))
    }
    return result.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
}
func parseResetAllowance(_ raw: Any?) -> ResetAllowance? {
    guard let raw = raw as? [String: Any], let count = allowanceCount(raw["available_count"] ?? raw["availableCount"]) else { return nil }
    let applicable = allowanceCount(raw["applicable_available_count"] ?? raw["applicableAvailableCount"])
    return ResetAllowance(availableCount: count, applicableCount: applicable.flatMap { $0 <= count ? $0 : nil }, credits: (try? parseResetRows(raw["credits"])) ?? nil)
}
func parseResetDetails(_ data: Data, summary: ResetAllowance, identity: Identity) throws -> ResetAllowance {
    guard data.count <= 262_144, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let credits = try parseResetRows(raw["credits"]) else { throw PotetoError.malformed }
    if let account = raw["account_id"] as? String, account != identity.workspace { throw PotetoError.wrongIdentity }
    let count = allowanceCount(raw["available_count"] ?? raw["availableCount"]) ?? summary.availableCount
    return ResetAllowance(availableCount: count, applicableCount: summary.applicableCount.flatMap { $0 <= count ? $0 : nil }, credits: credits)
}
private struct UniqueJSONKeys {
    let bytes: [UInt8]
    var index = 0
    mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func string() throws -> String {
        let start = index; index += 1
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { throw PotetoError.malformed }; index += 1 }
            else if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
        }
        throw PotetoError.malformed
    }
    mutating func value(_ depth: Int = 0) throws {
        whitespace(); guard depth <= 128, index < bytes.count else { throw PotetoError.malformed }
        if bytes[index] == 34 { _ = try string(); return }
        if bytes[index] == 123 {
            index += 1; whitespace(); var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true {
                whitespace(); guard index < bytes.count && bytes[index] == 34 else { throw PotetoError.malformed }
                guard try keys.insert(string()).inserted else { throw PotetoError.malformed }
                whitespace(); guard index < bytes.count && bytes[index] == 58 else { throw PotetoError.malformed }; index += 1
                try value(depth + 1); whitespace(); guard index < bytes.count else { throw PotetoError.malformed }
                let separator = bytes[index]; index += 1
                if separator == 125 { return }; guard separator == 44 else { throw PotetoError.malformed }
            }
        }
        if bytes[index] == 91 {
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth + 1); whitespace(); guard index < bytes.count else { throw PotetoError.malformed }
                let separator = bytes[index]; index += 1
                if separator == 93 { return }; guard separator == 44 else { throw PotetoError.malformed }
            }
        }
        while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
    }
    mutating func objectMembers() throws -> [String: Range<Int>] {
        whitespace(); guard index < bytes.count, bytes[index] == 123 else { throw PotetoError.projectState }
        index += 1; whitespace(); var result: [String: Range<Int>] = [:]
        if index < bytes.count && bytes[index] == 125 { index += 1; return result }
        while true {
            whitespace(); guard index < bytes.count, bytes[index] == 34 else { throw PotetoError.projectState }
            let key = try string(); whitespace()
            guard index < bytes.count, bytes[index] == 58 else { throw PotetoError.projectState }
            index += 1; whitespace(); let start = index; try value(); result[key] = start..<index
            whitespace(); guard index < bytes.count else { throw PotetoError.projectState }
            let separator = bytes[index]; index += 1
            if separator == 125 { return result }
            guard separator == 44 else { throw PotetoError.projectState }
        }
    }
    mutating func range(_ path: [String]) throws -> Range<Int> {
        whitespace(); let start = index
        guard let key = path.first else { try value(); return start..<index }
        let members = try objectMembers()
        guard let member = members[key] else { throw PotetoError.projectState }
        index = member.lowerBound
        return try range(Array(path.dropFirst()))
    }
    mutating func validate() throws { try value(); whitespace(); guard index == bytes.count else { throw PotetoError.malformed } }
}
func activationObservation(_ root: [String: Any], serverTime: Date?) -> ActivationObservation? {
    guard let group = root["rate_limit"] as? [String: Any] else { return nil }
    let allowed = group["allowed"] as? NSNumber, reached = group["limit_reached"] as? NSNumber
    let sendAllowed = allowed.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true &&
        reached.map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } == true
    let slots: [ActivationObservation.Slot] = [.primary, .secondary]
    guard group["primary_window"] is [String: Any] else { return nil }
    guard !group.contains(where: { key, value in key == "windows" || (key.hasSuffix("_window") && !slots.map(\.rawValue).contains(key)) || (value is [String: Any] && !slots.map(\.rawValue).contains(key)) }) else { return nil }
    var rows: [(ActivationObservation.Slot, Double, Double, Double?, Date?)] = []
    for slot in slots {
        guard let raw = group[slot.rawValue], !(raw is NSNull) else { continue }
        guard let row = raw as? [String: Any],
              ["windowDurationMins", "usedPercent", "remainingPercent", "resetsAt"].allSatisfy({ row[$0] == nil }),
              let duration = number(row["limit_window_seconds"]), duration > 0,
              let used = number(row["used_percent"]), used >= 0 else { return nil }
        if let remainingRaw = row["remaining_percent"] {
            guard let remaining = number(remainingRaw), abs(remaining - max(0, 100 - used)) < 0.000001 else { return nil }
        }
        let delay = number(row["reset_after_seconds"])
        if row["reset_after_seconds"] != nil && (delay == nil || delay! < 0 || delay! >= 8_640_000_000_000) { return nil }
        let absolute = serviceDate(row["reset_at"])
        if row["reset_at"] != nil && !(row["reset_at"] is NSNull) && absolute == nil { return nil }
        rows.append((slot, duration, used, delay, absolute))
    }
    guard let longest = rows.max(by: { $0.1 < $1.1 }), rows.filter({ $0.1 == longest.1 }).count == 1 else { return nil }
    return ActivationObservation(slot: longest.0, duration: longest.1, usedPercent: longest.2,
                                 unstarted: longest.2 == 0 && longest.3 == longest.1,
                                 allUnused: rows.allSatisfy { $0.2 == 0 }, sendAllowed: sendAllowed, absoluteReset: longest.4, serverTime: serverTime)
}
func parseUsage(_ data: Data, for identity: Identity, now: Date = Date(), serverTime: Date? = nil) throws -> Usage {
    guard data.count <= 262_144, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PotetoError.malformed }
    guard root["account_id"] as? String == identity.workspace,
          (root["email"] as? String)?.lowercased() == identity.email.lowercased() else { throw PotetoError.wrongIdentity }
    var groups: [(String, String, [String: Any], Bool)] = []
    for (key, raw) in root where key == "rate_limit" || key.hasSuffix("_rate_limit") {
        if let group = raw as? [String: Any] {
            groups.append((key, key == "code_review_rate_limit" ? "代码审查" : (safeLabel(group["limit_name"], max: 80) ?? (key == "rate_limit" ? "Codex" : key)), group, key == "rate_limit"))
        }
    }
    let additional = (root["additional_rate_limits"] as? [[String: Any]]) ?? (root["additional_rate_limits"] as? [String: [String: Any]]).map { Array($0.values) } ?? []
    for item in additional {
        if let group = item["rate_limit"] as? [String: Any] { groups.append(("additional", safeLabel(item["limit_name"], max: 80) ?? safeLabel(item["metered_feature"], max: 80) ?? "附加额度", group, false)) }
    }
    guard groups.count <= 128 else { throw PotetoError.malformed }
    var windows: [UsageWindow] = []
    for (_, name, group, ordinary) in groups {
        var candidates = group.values.compactMap { $0 as? [String: Any] }
        if let extra = group["windows"] as? [[String: Any]] { candidates += extra }
        guard candidates.count <= 128 else { throw PotetoError.malformed }
        for window in candidates {
            let duration = number(window["windowDurationMins"]) ?? number(window["limit_window_seconds"]).map { $0 / 60 }
            guard let duration, duration > 0 else { continue }
            let used = number(window["used_percent"] ?? window["usedPercent"])
            let remaining = number(window["remaining_percent"] ?? window["remainingPercent"])
            if (window["used_percent"] ?? window["usedPercent"]) != nil && (used == nil || used! < 0) { continue }
            if (window["remaining_percent"] ?? window["remainingPercent"]) != nil && (remaining == nil || remaining! < 0 || remaining! > 100) { continue }
            guard used != nil || remaining != nil else { continue }
            let value = used.map { max(0, 100 - $0) } ?? remaining!
            if let remaining, abs(value - remaining) > 0.000_001 { continue }
            let absolute = number(window["reset_at"] ?? window["resetsAt"])
            let delay = number(window["reset_after_seconds"])
            let reset: Date?
            if used == 0, let delay, delay >= 0 && delay < 8_640_000_000_000, delay == duration * 60 {
                reset = nil
            } else {
                reset = absolute.flatMap { $0 >= 0 && $0 < 8_640_000_000_000 ? Date(timeIntervalSince1970: $0) : nil }
                    ?? delay.flatMap { $0 >= 0 && $0 < 8_640_000_000_000 ? now.addingTimeInterval($0) : nil }
            }
            windows.append(UsageWindow(label: name, durationMinutes: duration, remaining: value, reset: reset, ordinary: ordinary))
        }
    }
    let credits = parseBalance(root["credits"]), resets = parseResetAllowance(root["rate_limit_reset_credits"] ?? root["rateLimitResetCredits"])
    guard !windows.isEmpty || credits != nil || resets != nil else { throw PotetoError.malformed }
    windows.sort { ($0.ordinary ? 0 : 1, $0.label, $0.durationMinutes) < ($1.ordinary ? 0 : 1, $1.label, $1.durationMinutes) }
    var uniqueKeys = UniqueJSONKeys(bytes: Array(data))
    let activation = (try? uniqueKeys.validate()) != nil ? activationObservation(root, serverTime: serverTime) : nil
    return Usage(plan: safeLabel(root["plan_type"], max: 60), windows: windows, checkedAt: now, credits: credits, resetAllowance: resets, activation: activation)
}

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum OfficialHTTP {
    static let usage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCredits = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let token = URL(string: "https://auth.openai.com/oauth/token")!
    static let delegate = NoRedirect()
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.httpCookieStorage = nil; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 20
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }()
    static func response(_ request: URLRequest) async throws -> (Int, Data, Date?) {
        guard (request.httpMethod == "GET" && (request.url == usage || request.url == resetCredits)) ||
              (request.httpMethod == "POST" && request.url == token) else { throw PotetoError.network }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw PotetoError.network }
        var data = Data()
        for try await byte in bytes { guard data.count < 262_144 else { throw PotetoError.malformed }; data.append(byte) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let serverTime = response.value(forHTTPHeaderField: "Date").flatMap { formatter.date(from: $0) }
        return (response.statusCode, data, serverTime)
    }
    static func request(_ request: URLRequest) async throws -> (Int, Data) {
        let (code, data, _) = try await response(request); return (code, data)
    }
    static func readUsage(_ auth: AuthBundle) async throws -> Usage { try await readUsage(auth, includeDetails: true) }
    static func readUsageOnly(_ auth: AuthBundle) async throws -> Usage { try await readUsage(auth, includeDetails: false) }
    private static func readUsage(_ auth: AuthBundle, includeDetails: Bool) async throws -> Usage {
        let identity = try auth.identity
        guard let access = try auth.token("access_token") else { throw PotetoError.loginRequired }
        var req = URLRequest(url: usage); req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue(identity.workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
        let (code, data, serverTime) = try await response(req)
        if code == 401 { throw PotetoError.loginRequired }; guard code == 200 else { throw PotetoError.network }
        var usage = try parseUsage(data, for: identity, serverTime: serverTime)
        if includeDetails, let summary = usage.resetAllowance, summary.availableCount > 0, summary.credits == nil {
            var details = URLRequest(url: resetCredits)
            details.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            details.setValue(identity.workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
            // Optional expiry details must never turn a successful quota read into a failure.
            if let (status, body) = try? await request(details), status == 200 {
                usage.resetAllowance = (try? parseResetDetails(body, summary: summary, identity: identity)) ?? summary
            }
        }
        return usage
    }
    static func refresh(_ auth: AuthBundle) async throws -> AuthBundle {
        guard let refresh = try auth.token("refresh_token") else { throw PotetoError.loginRequired }
        var req = URLRequest(url: token); req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"])
        let (code, data) = try await request(req)
        if [400, 401, 403].contains(code) { throw PotetoError.loginRequired }
        guard code == 200, let tokens = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PotetoError.network }
        return try auth.replacingTokens(tokens)
    }
}

func nativeClientIsRunning() -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "comm="]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return true }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return true }
    return text.split(separator: "\n").contains { line in
        let name = URL(fileURLWithPath: String(line).trimmingCharacters(in: .whitespaces)).lastPathComponent
        return ["ChatGPT", "Codex", "codex", "codex.exe"].contains(name)
    }
}

struct LocalProject: Equatable {
    let id: String; let name: String; let roots: [String]; let created: Int64; let updated: Int64
    init(_ id: String, _ raw: Any) throws {
        guard let d = raw as? [String: Any], Set(d.keys) == Set(["id", "name", "rootPaths", "createdAt", "updatedAt"]),
              let actual = d["id"] as? String, actual == id, !id.isEmpty,
              let name = d["name"] as? String, let roots = d["rootPaths"] as? [String],
              roots.allSatisfy({ $0.hasPrefix("/") }),
              let c = d["createdAt"] as? NSNumber, CFGetTypeID(c) != CFBooleanGetTypeID(),
              let u = d["updatedAt"] as? NSNumber, CFGetTypeID(u) != CFBooleanGetTypeID(),
              c.doubleValue == Double(c.int64Value), u.doubleValue == Double(u.int64Value) else { throw PotetoError.projectState }
        self.id = id; self.name = name; self.roots = roots; created = c.int64Value; updated = u.int64Value
    }
}

struct LocalProjectLayout {
    let projects: [String: LocalProject]
    let raw: [String: Any]
    init(_ raw: [String: Any]) throws {
        guard let records = (raw["local-projects"] ?? [:]) as? [String: Any] else { throw PotetoError.projectState }
        var projects: [String: LocalProject] = [:]
        for (id, record) in records { projects[id] = try LocalProject(id, record) }
        self.projects = projects; self.raw = raw
    }
    static func equal(_ a: Any, _ b: Any) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: [a], options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: [b], options: [.sortedKeys]) else { return false }
        return left == right
    }
    static func merged(_ target: [String: Any], _ source: [String: Any]) throws -> [String: Any] {
        let s = try LocalProjectLayout(source), t = try LocalProjectLayout(target)
        var out = target
        var records = target["local-projects"] as? [String: Any] ?? [:]
        let incoming = source["local-projects"] as? [String: Any] ?? [:]
        for (id, project) in s.projects {
            if let existing = t.projects[id], existing != project { throw PotetoError.projectState }
            records[id] = records[id] ?? incoming[id]
        }
        out["local-projects"] = records
        func strings(_ value: Any?) throws -> [String] {
            guard let value else { return [] }; guard let a = value as? [String] else { throw PotetoError.projectState }; return a
        }
        func ordered(_ a: [String], _ b: [String]) -> [String] {
            var seen = Set(a); return a + b.filter { seen.insert($0).inserted }
        }
        guard let sourceAssignments = (source["thread-project-assignments"] ?? [:]) as? [String: Any] else { throw PotetoError.projectState }
        var remoteIDs = Set<String>()
        for value in sourceAssignments.values {
            guard let item = value as? [String: Any], let kind = item["projectKind"] as? String,
                  let id = item["projectId"] as? String, !id.isEmpty else { throw PotetoError.projectState }
            if kind == "remote" { guard s.projects[id] == nil else { throw PotetoError.projectState }; remoteIDs.insert(id) }
            else if kind != "local" { throw PotetoError.projectState }
        }
        let targetAssignments = (target["thread-project-assignments"] ?? [:]) as? [String: Any]
        guard let targetAssignments else { throw PotetoError.projectState }
        for value in targetAssignments.values {
            guard let item = value as? [String: Any], item["projectKind"] as? String == "remote",
                  let id = item["projectId"] as? String else { continue }
            guard s.projects[id] == nil else { throw PotetoError.projectState }
        }
        guard remoteIDs.isDisjoint(with: t.projects.keys) else { throw PotetoError.projectState }
        let sourceOrder = try strings(source["project-order"])
        guard sourceOrder.allSatisfy({ s.projects[$0] != nil || remoteIDs.contains($0) }) else { throw PotetoError.projectState }
        let order = sourceOrder.filter { s.projects[$0] != nil }
        let targetOrder = try strings(target["project-order"])
        out["project-order"] = ordered(targetOrder, order + s.projects.keys.sorted().filter { !order.contains($0) })
        for key in ["project-appearances", "project-files"] {
            guard let src = (source[key] ?? [:]) as? [String: Any], var dst = (target[key] ?? [:]) as? [String: Any] else { throw PotetoError.projectState }
            for (id, value) in src {
                if remoteIDs.contains(id) { continue }
                guard s.projects[id] != nil else { throw PotetoError.projectState }
                if let old = dst[id], !equal(old, value) { throw PotetoError.projectState }; dst[id] = value
            }
            if source[key] != nil || target[key] != nil { out[key] = dst }
        }
        if source["pinned-project-ids"] != nil || target["pinned-project-ids"] != nil {
            let pins = try strings(source["pinned-project-ids"])
            guard pins.allSatisfy({ s.projects[$0] != nil || remoteIDs.contains($0) }) else { throw PotetoError.projectState }
            out["pinned-project-ids"] = ordered(try strings(target["pinned-project-ids"]), pins.filter { s.projects[$0] != nil })
        }
        var dest = targetAssignments
        var threads = Set<String>()
        let projectless = Set(try strings(target["projectless-thread-ids"]))
        for (thread, value) in sourceAssignments {
            guard let item = value as? [String: Any], let kind = item["projectKind"] as? String,
                  let id = item["projectId"] as? String else { throw PotetoError.projectState }
            if kind == "remote" { continue }
            guard kind == "local", Set(item.keys) == Set(["projectKind", "projectId"]), s.projects[id] != nil,
                  !projectless.contains(thread) else { throw PotetoError.projectState }
            if let old = dest[thread], !equal(old, value) { throw PotetoError.projectState }
            dest[thread] = value; threads.insert(thread)
        }
        if source["thread-project-assignments"] != nil || target["thread-project-assignments"] != nil { out["thread-project-assignments"] = dest }
        for key in ["thread-workspace-root-hints", "thread-projectless-output-directories"] {
            guard let src = (source[key] ?? [:]) as? [String: Any], var dst = (target[key] ?? [:]) as? [String: Any] else { throw PotetoError.projectState }
            for thread in threads { if let value = src[thread] {
                guard value is String else { throw PotetoError.projectState }
                if let old = dst[thread], !equal(old, value) { throw PotetoError.projectState }; dst[thread] = value
            } }
            if source[key] != nil || target[key] != nil { out[key] = dst }
        }
        guard let sides = (source["sidebar-project-thread-orders"] ?? [:]) as? [String: Any],
              var targetSides = (target["sidebar-project-thread-orders"] ?? [:]) as? [String: Any] else { throw PotetoError.projectState }
        func canPlaceInSidebar(_ assignment: Any?, projectID: String) -> Bool {
            guard let assignment else { return true }
            guard let item = assignment as? [String: Any] else { return false }
            return item["projectKind"] as? String == "local" && item["projectId"] as? String == projectID
        }
        for (id, value) in sides {
            if remoteIDs.contains(id) { continue }
            guard s.projects[id] != nil, let entry = value as? [String: Any], Set(entry.keys) == ["threadIds"],
                  let ids = entry["threadIds"] as? [String] else { throw PotetoError.projectState }
            var previous: [String] = []
            if let old = targetSides[id] {
                guard let entry = old as? [String: Any], Set(entry.keys) == ["threadIds"], let ids = entry["threadIds"] as? [String] else { throw PotetoError.projectState }; previous = ids
            }
            let localOrder = ids.filter { thread in
                !projectless.contains(thread) && canPlaceInSidebar(sourceAssignments[thread], projectID: id)
                    && canPlaceInSidebar(dest[thread], projectID: id)
            }
            targetSides[id] = ["threadIds": ordered(previous, localOrder)]
        }
        if source["sidebar-project-thread-orders"] != nil || target["sidebar-project-thread-orders"] != nil { out["sidebar-project-thread-orders"] = targetSides }
        return out
    }
}

enum NativeProjectState {
    static func numbers(_ data: Data) throws -> [String] {
        let bytes = Array(data); var i = 0, result: [String] = []
        while i < bytes.count {
            if bytes[i] == 34 {
                i += 1
                while i < bytes.count {
                    if bytes[i] == 92 { i += 2; continue }
                    if bytes[i] == 34 { i += 1; break }
                    i += 1
                }
            } else if bytes[i] == 45 || (48...57).contains(bytes[i]) {
                let start = i
                while i < bytes.count && ((48...57).contains(bytes[i]) || [43, 45, 46, 69, 101].contains(bytes[i])) { i += 1 }
                let literal = String(decoding: bytes[start..<i], as: UTF8.self).lowercased()
                let parts = literal.split(separator: "e", omittingEmptySubsequences: false)
                guard parts.count <= 2, let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { throw PotetoError.projectState }
                var mantissa = String(parts[0]); let negative = mantissa.first == "-"
                if negative { mantissa.removeFirst() }
                let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
                guard decimal.count <= 2 else { throw PotetoError.projectState }
                var digits = decimal.joined(); let fractional = decimal.count == 2 ? decimal[1].count : 0
                while digits.first == "0" { digits.removeFirst() }
                if digits.isEmpty { result.append(negative ? "-0" : "0"); continue }
                var trailing = 0
                while digits.last == "0" { digits.removeLast(); trailing += 1 }
                let (adjusted, overflow1) = exponent.subtractingReportingOverflow(fractional)
                let (power, overflow2) = adjusted.addingReportingOverflow(trailing)
                guard !overflow1 && !overflow2 else { throw PotetoError.projectState }
                result.append((negative ? "-" : "") + digits + "e" + String(power))
            } else { i += 1 }
        }
        return result.sorted()
    }

    static func merge(_ targetData: Data, targetPath: [String], sourceData: Data, sourcePath: [String]) throws -> Data {
        func parse(_ data: Data, _ path: [String]) throws -> (Data, [String: Any]) {
            var parser = UniqueJSONKeys(bytes: Array(data))
            do { try parser.validate(); parser.index = 0; let range = try parser.range(path)
                let raw = data.subdata(in: range)
                guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw PotetoError.projectState }
                return (raw, object)
            } catch { throw PotetoError.projectState }
        }
        let (targetRaw, target) = try parse(targetData, targetPath)
        let (sourceRaw, source) = try parse(sourceData, sourcePath)
        let merged = try LocalProjectLayout.merged(target, source)
        let layout = try LocalProjectLayout(source)
        func members(_ data: Data) throws -> [String: Range<Int>] {
            var parser = UniqueJSONKeys(bytes: Array(data)); return try parser.objectMembers()
        }
        let targetMembers = try members(targetRaw), sourceMembers = try members(sourceRaw)
        for key in ["local-projects", "project-appearances", "project-files"] {
            guard let targetRange = targetMembers[key], let sourceRange = sourceMembers[key] else { continue }
            let targetField = targetRaw.subdata(in: targetRange), sourceField = sourceRaw.subdata(in: sourceRange)
            let targetEntries = try members(targetField), sourceEntries = try members(sourceField)
            for id in layout.projects.keys {
                guard let leftRange = targetEntries[id], let rightRange = sourceEntries[id] else { continue }
                let left = targetField.subdata(in: leftRange), right = sourceField.subdata(in: rightRange)
                let leftNumbers = try numbers(left), rightNumbers = try numbers(right)
                guard leftNumbers == rightNumbers else { throw PotetoError.projectState }
                if left != right && !leftNumbers.isEmpty {
                    let leftValue = try JSONSerialization.jsonObject(with: left, options: [.fragmentsAllowed])
                    let rightValue = try JSONSerialization.jsonObject(with: right, options: [.fragmentsAllowed])
                    let leftSerialized = try JSONSerialization.data(withJSONObject: [leftValue], options: [.sortedKeys])
                    let rightSerialized = try JSONSerialization.data(withJSONObject: [rightValue], options: [.sortedKeys])
                    guard try numbers(leftSerialized) == leftNumbers, try numbers(rightSerialized) == rightNumbers else { throw PotetoError.projectState }
                }
            }
        }
        func encoded(_ value: Any) throws -> Data {
            let wrapper = try JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed, .sortedKeys])
            return wrapper.subdata(in: 1..<(wrapper.count - 1))
        }
        func build(_ oldRaw: Data?, _ old: Any?, _ new: Any, _ incomingRaw: Data?, _ incoming: Any?) throws -> Data {
            if let oldRaw, let old, LocalProjectLayout.equal(old, new) { return oldRaw }
            if old == nil, let incomingRaw, let incoming, LocalProjectLayout.equal(incoming, new) { return incomingRaw }
            if let dict = new as? [String: Any] {
                let previous = old as? [String: Any] ?? [:], incomingDict = incoming as? [String: Any] ?? [:]
                let oldMembers = try oldRaw.map(members) ?? [:], incomingMembers = try incomingRaw.map(members) ?? [:]
                var output = oldRaw ?? Data("{}".utf8)
                var edits: [(Range<Int>, Data)] = [], additions: [Data] = []
                for key in dict.keys.sorted() {
                    let oldPart = oldMembers[key].map { output.subdata(in: $0) }
                    let newPart = incomingMembers[key].flatMap { r in incomingRaw.map { $0.subdata(in: r) } }
                    let part = try build(oldPart, previous[key], dict[key]!, newPart, incomingDict[key])
                    if let range = oldMembers[key] { if part != oldPart { edits.append((range, part)) } }
                    else { additions.append(try encoded(key) + Data(":".utf8) + part) }
                }
                for (range, part) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { output.replaceSubrange(range, with: part) }
                if !additions.isEmpty {
                    guard let end = output.lastIndex(of: 125) else { throw PotetoError.projectState }
                    var suffix = Data(previous.isEmpty ? [] : [44])
                    for (index, item) in additions.enumerated() { if index > 0 { suffix.append(44) }; suffix.append(item) }
                    output.insert(contentsOf: suffix, at: end)
                }
                return output
            }
            if let array = new as? [String], let oldArray = old as? [String], let oldRaw,
               array.starts(with: oldArray) {
                var output = oldRaw
                let extra = Array(array.dropFirst(oldArray.count))
                if !extra.isEmpty {
                    guard let end = output.lastIndex(of: 93) else { throw PotetoError.projectState }
                    var suffix = Data(oldArray.isEmpty ? [] : [44])
                    for (index, item) in extra.enumerated() { if index > 0 { suffix.append(44) }; suffix.append(try encoded(item)) }
                    output.insert(contentsOf: suffix, at: end)
                }
                return output
            }
            guard old == nil else { throw PotetoError.projectState }
            let result = try encoded(new)
            if let incomingRaw { guard try numbers(incomingRaw) == numbers(result) else { throw PotetoError.projectState } }
            return result
        }
        let result = try build(targetRaw, target, merged, sourceRaw, source)
        var parser = UniqueJSONKeys(bytes: Array(targetData)); let range = try parser.range(targetPath)
        var output = targetData; output.replaceSubrange(range, with: result); return output
    }

    static func matches(_ atoms: Any?, _ descriptor: NativeAccountDescriptor) -> Bool {
        guard let atoms = atoms as? [String: Any], let identity = atoms["local-document-identity"] as? [String: Any],
              identity["accountId"] as? String == descriptor.accountId, identity["userId"] as? String == descriptor.userId else { return false }
        return true
    }
    static func prepare(_ data: Data, source: AuthBundle, target: AuthBundle) throws -> Data? {
        var unique = UniqueJSONKeys(bytes: Array(data)); do { try unique.validate() } catch { throw PotetoError.projectState }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = root["electron-account-renderer-state-v1"] as? [String: Any],
              let inactive = state["inactive"] as? [String: Any], state.keys.contains("owner") else { throw PotetoError.projectState }
        let sourceID = try NativeAccountDescriptor(auth: source), targetID = try NativeAccountDescriptor(auth: target)
        let sourceGlobals: [String: Any]
        let sourcePath: [String]
        let statePath = ["electron-account-renderer-state-v1", "inactive"]
        if let owner = state["owner"] as? String {
            guard !owner.isEmpty, inactive[owner] == nil, matches(root["electron-persisted-atom-state"], sourceID) else { throw PotetoError.projectState }
            sourceGlobals = root; sourcePath = []
        } else if state["owner"] is NSNull {
            let candidates = inactive.compactMap { key, value -> String? in
                guard let slot = value as? [String: Any], matches(slot["atoms"], sourceID) else { return nil }; return key
            }
            guard candidates.count == 1, let slot = inactive[candidates[0]] as? [String: Any],
                  let globals = slot["globals"] as? [String: Any] else { throw PotetoError.projectState }
            sourceGlobals = globals; sourcePath = statePath + [candidates[0], "globals"]
        } else { throw PotetoError.projectState }
        let layout = try LocalProjectLayout(sourceGlobals)
        _ = try LocalProjectLayout.merged([:], sourceGlobals)
        if sourceID == targetID {
            guard !(state["owner"] is NSNull) else { throw PotetoError.projectState }
            _ = try LocalProjectLayout.merged(sourceGlobals, sourceGlobals)
            return nil
        }
        let candidates = inactive.compactMap { key, value -> String? in
            guard let slot = value as? [String: Any], matches(slot["atoms"], targetID) else { return nil }; return key
        }
        guard candidates.count == 1, let slot = inactive[candidates[0]] as? [String: Any],
              let globals = slot["globals"] as? [String: Any], sourceID != targetID else { throw PotetoError.projectState }
        _ = try LocalProjectLayout.merged(globals, sourceGlobals)
        if layout.projects.isEmpty { return nil }
        return try merge(data, targetPath: statePath + [candidates[0], "globals"], sourceData: data, sourcePath: sourcePath)
    }
}

enum NativeStateFile {
    static let limit = 32 * 1024 * 1024
    static func snapshot(_ url: URL) throws -> PrivateSnapshot? {
        var s = stat(); if lstat(url.path, &s) != 0 { if errno == ENOENT { return nil }; throw PotetoError.projectState }
        guard (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1, (s.st_mode & 0o022) == 0, s.st_size >= 0, s.st_size <= limit else { throw PotetoError.projectState }
        return PrivateSnapshot(s)
    }
    static func read(_ url: URL, expected: PrivateSnapshot) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK); guard fd >= 0 else { throw PotetoError.projectState }; defer { close(fd) }
        var s = stat(); guard fstat(fd, &s) == 0, PrivateSnapshot(s) == expected else { throw PotetoError.changed }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true { let n = Darwin.read(fd, &buffer, buffer.count); if n == 0 { break }; guard n > 0, data.count + n <= limit else { throw PotetoError.projectState }; data.append(contentsOf: buffer.prefix(n)) }
        guard fstat(fd, &s) == 0, PrivateSnapshot(s) == expected, try snapshot(url) == expected else { throw PotetoError.changed }; return data
    }
    static func write(_ data: Data, to url: URL, expected: PrivateSnapshot) throws {
        guard data.count <= limit, try snapshot(url) == expected else { throw PotetoError.changed }
        var s = stat(); guard lstat(url.path, &s) == 0, PrivateSnapshot(s) == expected else { throw PotetoError.changed }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".poteto-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PotetoError.projectState }; defer { close(fd); unlink(temp.path) }
        try data.withUnsafeBytes { raw in var offset = 0; while offset < raw.count { let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset); guard n > 0 else { throw PotetoError.projectState }; offset += n } }
        guard fchmod(fd, s.st_mode & 0o777) == 0, fsync(fd) == 0, try snapshot(url) == expected else { throw PotetoError.changed }
        guard rename(temp.path, url.path) == 0 else { throw PotetoError.projectState }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw PotetoError.projectPartial }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw PotetoError.projectPartial }
    }
}

func activateAccount(_ auth: AuthBundle, authURL: URL, isRunning: () -> Bool = nativeClientIsRunning) throws {
    _ = try auth.identity
    if isRunning() { throw PotetoError.running }
    let before = try PrivateFiles.snapshot(authURL)
    let previous = try PrivateFiles.read(authURL)
    if let previous { _ = try AuthBundle(data: previous).identity }
    let stateURL = authURL.deletingLastPathComponent().appendingPathComponent(".codex-global-state.json")
    var prepared = false
    var stateVersion: PrivateSnapshot?
    if let version = try NativeStateFile.snapshot(stateURL) {
        let data = try NativeStateFile.read(stateURL, expected: version)
        guard let previous else { throw PotetoError.projectState }
        if let updated = try NativeProjectState.prepare(data, source: AuthBundle(data: previous), target: auth), updated != data {
            if isRunning() { throw PotetoError.running }
            guard try PrivateFiles.snapshot(authURL) == before else { throw PotetoError.changed }
            try NativeStateFile.write(updated, to: stateURL, expected: version); prepared = true
            do {
                guard let after = try NativeStateFile.snapshot(stateURL), try NativeStateFile.read(stateURL, expected: after) == updated else { throw PotetoError.projectPartial }
                stateVersion = after
            } catch { throw PotetoError.projectPartial }
        } else { stateVersion = version }
    }
    do {
        if isRunning() { throw PotetoError.running }
        guard try NativeStateFile.snapshot(stateURL) == stateVersion else { throw PotetoError.changed }
        try PrivateFiles.write(auth.data, to: authURL, expected: before, compare: true)
    } catch { if prepared { throw PotetoError.projectPartial }; throw error }
    if isRunning() { throw PotetoError.startupRace }
    do {
        guard try NativeStateFile.snapshot(stateURL) == stateVersion else { throw PotetoError.projectPartial }
    } catch { throw PotetoError.projectPartial }
    guard try PrivateFiles.read(authURL) == auth.data else { throw PotetoError.changed }
}

final class InstanceLock {
    private var fd: Int32 = -1
    init(_ url: URL) throws {
        fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0 else { if fd >= 0 { close(fd) }; throw PotetoError.privateFile }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); fd = -1; throw PotetoError.changed }
    }
    deinit { if fd >= 0 { close(fd) } }
}
