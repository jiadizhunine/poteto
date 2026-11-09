import AppKit
import SwiftUI

struct DesktopTheme {
    let surface: NSColor
    let ink: NSColor
    let accent: NSColor
    let uiFont: String?
    var dark: Bool { (surface.redComponent * 0.2126 + surface.greenComponent * 0.7152 + surface.blueComponent * 0.0722) < 0.45 }

    static func hex(_ text: String?) -> NSColor? {
        guard let text, text.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
              let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func fallback() -> DesktopTheme {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return DesktopTheme(surface: hex(dark ? "#242424" : "#f5f5f5")!, ink: hex(dark ? "#f2f2f2" : "#242424")!, accent: NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? hex("#007aff")!, uiFont: nil)
    }
    // Read only documented scalar/inline color fields; never parse or write the rest of Codex's configuration.
    static func parse(_ text: String, systemDark: Bool) -> DesktopTheme? {
        guard text.utf8.count <= 1_048_576 else { return nil }
        var section = "", mode = "system", inline: [String: String] = [:], nested: [String: [String: String]] = [:]
        func quoted(_ key: String, _ line: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: "(?:^|[,{\\s])\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"([^\"\\\\\\r\\n]{1,180})\""),
                  let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range])
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            if section == "[desktop]" {
                if let value = quoted("appearanceTheme", line), ["light", "dark", "system"].contains(value) { mode = value }
                for key in ["appearanceLightChromeTheme", "appearanceDarkChromeTheme"] where line.hasPrefix(key + " ") || line.hasPrefix(key + "=") { inline[key] = line }
            } else if section == "[desktop.appearanceLightChromeTheme]" || section == "[desktop.appearanceDarkChromeTheme]" {
                let key = String(section.dropFirst("[desktop.".count).dropLast())
                for field in ["surface", "ink", "accent"] { if let value = quoted(field, line) { nested[key, default: [:]][field] = value } }
            }
        }
        let key = (mode == "dark" || mode == "system" && systemDark) ? "appearanceDarkChromeTheme" : "appearanceLightChromeTheme"
        let line = inline[key] ?? ""
        guard let surface = hex(nested[key]?["surface"] ?? quoted("surface", line)),
              let ink = hex(nested[key]?["ink"] ?? quoted("ink", line)),
              let accent = hex(nested[key]?["accent"] ?? quoted("accent", line)) else { return nil }
        return DesktopTheme(surface: surface, ink: ink, accent: accent, uiFont: quoted("ui", line))
    }
    static func load() -> DesktopTheme {
        guard let data = try? PrivateFiles.read(nativeHome.appendingPathComponent("config.toml")),
              let text = String(data: data, encoding: .utf8) else { return fallback() }
        return parse(text, systemDark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) ?? fallback()
    }
}

struct PanelBounds: Equatable {
    let width: CGFloat
    let maximumHeight: CGFloat
    let listHeight: CGFloat
    static func fitting(width: CGFloat, height: CGFloat, settings: Bool = false, error: Bool = false) -> PanelBounds {
        let maximum = max(1, min(600, height - 32))
        return PanelBounds(width: max(1, min(380, width - 24)), maximumHeight: maximum,
                           listHeight: max(0, min(360, maximum - 218 - (settings ? 44 : 0) - (error ? 44 : 0))))
    }
}
func deadlineText(_ date: Date, now: Date = Date()) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy/MM/dd HH:mm"
    let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
    let remaining = minutes == 0 ? "已到时间" : minutes >= 1440 ? "\(minutes / 1440)天\(minutes % 1440 / 60)小时后" : minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分钟后" : "\(minutes)分钟后"
    return "\(formatter.string(from: date))（\(remaining)）"
}

@MainActor
final class PanelState: ObservableObject {
    @Published var snapshot = Snapshot(accounts: [], refreshing: true, error: nil, loginRunning: false)
    @Published var theme = DesktopTheme.fallback()
    @Published var nativeRunning = true
    @Published var busy = false
    @Published var startup = LoginStart.enabled
    @Published var startupChanging = false
    @Published var settings = false
    @Published private(set) var detailAccountID: String?
    private var pinnedAccountID: String?
    private var hoveredAccountID: String?
    private var hoveringDetails = false
    private var previewChange: Task<Void, Never>?
    static let hoverDelay = 0.24
    static let dismissDelay = 0.18
    static let transitionDuration = 0.24
    @Published fileprivate var viewportHeight: CGFloat?
    @Published var availableScreenSize = NSSize(width: 1440, height: 900)
    var bounds: PanelBounds {
        PanelBounds.fitting(width: availableScreenSize.width, height: availableScreenSize.height,
                            settings: settings, error: snapshot.error != nil)
    }
    private func cancelPreviewChange() { previewChange?.cancel(); previewChange = nil }
    func cancelAccountHover() {
        cancelPreviewChange(); hoveredAccountID = nil; hoveringDetails = false
    }
    private func schedulePreview(_ id: String?, delay: TimeInterval, reduceMotion: Bool) {
        cancelPreviewChange()
        guard detailAccountID != id else { return }
        previewChange = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            let target = id.flatMap { candidate in
                self.snapshot.accounts.contains(where: { $0.id == candidate }) ? candidate : nil
            }
            withAnimation(reduceMotion ? nil : .smooth(duration: Self.transitionDuration)) {
                self.detailAccountID = target
            }
            self.previewChange = nil
        }
    }
    func hoverAccount(_ id: String, inside: Bool, reduceMotion: Bool = false) {
        if inside {
            hoveredAccountID = id; hoveringDetails = false
            schedulePreview(id, delay: Self.hoverDelay, reduceMotion: reduceMotion)
        } else if hoveredAccountID == id {
            hoveredAccountID = nil
            if !hoveringDetails { schedulePreview(pinnedAccountID, delay: Self.dismissDelay, reduceMotion: reduceMotion) }
        }
    }
    func hoverDetails(_ inside: Bool, reduceMotion: Bool = false) {
        hoveringDetails = inside
        if inside { cancelPreviewChange() }
        else if hoveredAccountID == nil { schedulePreview(pinnedAccountID, delay: Self.dismissDelay, reduceMotion: reduceMotion) }
    }
    func leaveAccountArea(reduceMotion: Bool = false) {
        hoveredAccountID = nil; hoveringDetails = false
        schedulePreview(pinnedAccountID, delay: Self.dismissDelay, reduceMotion: reduceMotion)
    }
    func previewAccount(_ id: String) { cancelAccountHover(); detailAccountID = id }
    func clearAccountPreview() { cancelAccountHover(); detailAccountID = pinnedAccountID }
    func toggleAccountDetails(_ id: String) {
        cancelAccountHover()
        pinnedAccountID = pinnedAccountID == id ? nil : id
        detailAccountID = pinnedAccountID
    }
    func resetAccountPreview() { cancelAccountHover(); pinnedAccountID = nil; detailAccountID = nil }
    deinit { previewChange?.cancel() }
}

@MainActor
final class PanelHostingController: NSViewController {
    var animatesSizeChanges = false
    weak var popover: NSPopover?
    private var requestedSize: NSSize?
    private var sizeChange: Task<Void, Never>?
    private var savedPopoverAnimation: Bool?
    private let panelState: PanelState

    init(rootView: PotetoPanel) {
        panelState = rootView.state
        super.init(nibName: nil, bundle: nil)
        panelState.viewportHeight = 240
        var panel = rootView
        panel.reportSize = { [weak self] size in self?.resize(to: size) }
        let hosting = NSHostingView(rootView: panel)
        // Drive the popover's size ourselves: automatic intrinsic updates otherwise jump to the final height.
        hosting.sizingOptions = []
        view = hosting
        preferredContentSize = NSSize(width: rootView.state.bounds.width, height: 240)
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        view.layoutSubtreeIfNeeded()
    }
    required init?(coder: NSCoder) { return nil }
    private func resize(to size: NSSize) {
        guard size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 else { return }
        if let requestedSize, abs(size.height - requestedSize.height) < 0.5 && abs(size.width - requestedSize.width) < 0.5 { return }
        sizeChange?.cancel(); sizeChange = nil; requestedSize = nil
        restorePopoverAnimation()
        let start = popover?.contentSize ?? preferredContentSize
        guard animatesSizeChanges, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(size.height - start.height) > 1 else { applySize(size); return }
        requestedSize = size
        savedPopoverAnimation = popover?.animates
        popover?.animates = false
        let began = ProcessInfo.processInfo.systemUptime
        sizeChange = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / PanelState.transitionDuration)
                let eased = progress * progress * (3 - 2 * progress)
                self.applySize(NSSize(width: size.width, height: start.height + (size.height - start.height) * eased))
                if progress >= 1 { self.requestedSize = nil; self.sizeChange = nil; self.restorePopoverAnimation(); return }
                do { try await Task.sleep(nanoseconds: 8_333_333) }
                catch { return }
            }
        }
    }
    private func applySize(_ size: NSSize) {
        panelState.viewportHeight = size.height
        preferredContentSize = size; popover?.contentSize = size
    }
    private func restorePopoverAnimation() {
        if let savedPopoverAnimation { popover?.animates = savedPopoverAnimation }
        savedPopoverAnimation = nil
    }
    func stopSizeAnimation() {
        animatesSizeChanges = false; sizeChange?.cancel(); sizeChange = nil; requestedSize = nil
        restorePopoverAnimation()
    }
    func prepareForShow() {
        stopSizeAnimation()
        panelState.viewportHeight = nil
        view.frame.size.width = panelState.bounds.width
        let hosting = view as! NSHostingView<PotetoPanel>
        hosting.sizingOptions = [.intrinsicContentSize]
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let size = view.intrinsicContentSize
        hosting.sizingOptions = []
        applySize(size)
        view.frame.size = size
        view.layoutSubtreeIfNeeded()
    }
    deinit { sizeChange?.cancel() }
}

#if POTETO_TEST
extension PanelState {
    var presentationViewportHeight: CGFloat? { viewportHeight }
}
extension PanelHostingController {
    var presentationHasSizeAnimation: Bool { sizeChange != nil }
}
#endif

struct MenuButtonStyle: ButtonStyle {
    let theme: DesktopTheme
    var selected = false
    static func backgroundOpacity(enabled: Bool, hovered: Bool, pressed: Bool, selected: Bool) -> Double {
        guard enabled else { return 0 }
        return pressed ? 0.18 : hovered ? 0.10 : selected ? 0.06 : 0
    }
    func makeBody(configuration: Configuration) -> some View {
        MenuButtonBody(configuration: configuration, theme: theme, selected: selected)
    }
    private struct MenuButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let theme: DesktopTheme
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        // Disambiguate the property wrapper from the new SDK's same-named State macro.
        private typealias HoverState = SwiftUI.State<Bool>
        @HoverState private var hovered = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(Color(theme.ink).opacity(MenuButtonStyle.backgroundOpacity(
                    enabled: enabled, hovered: hovered, pressed: configuration.isPressed, selected: selected)),
                    in: RoundedRectangle(cornerRadius: 7))
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

struct PotetoPanel: View {
    @ObservedObject var state: PanelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias ContentHeightState = SwiftUI.State<CGFloat>
    @ContentHeightState private var accountContentHeight: CGFloat = 0
    let refresh: () -> Void
    let addAccount: () -> Void
    let switchAccount: (String) -> Void
    let forget: (String) -> Void
    let toggleStart: () -> Void
    let quit: () -> Void
    var reportSize: @MainActor (NSSize) -> Void = { _ in }
    private var theme: DesktopTheme { state.theme }
    private func resetCreditText(_ credit: ResetCredit) -> String {
        let expiry = credit.expiresAt.map { "到期 \(deadlineText($0))" } ?? "未提供到期时间"
        return "\(credit.title ?? "额度重置")：\(expiry)"
    }
    private func period(_ minutes: Double) -> String {
        if minutes >= 1440 && minutes.truncatingRemainder(dividingBy: 1440) == 0 { return "\(Int(minutes / 1440))天" }
        if minutes >= 60 && minutes.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(minutes / 60))小时" }
        return "\(Int(minutes.rounded()))分钟"
    }
    private func action(_ title: String, _ icon: String, disabled: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18, height: 18)
                Text(title)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
            .buttonStyle(MenuButtonStyle(theme: theme))
            .foregroundStyle(disabled ? Color(theme.ink).opacity(0.35) : Color(theme.ink)).disabled(disabled)
            .accessibilityLabel(title)
    }
    @ViewBuilder
    private func accountDetails(_ account: AccountView) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let usage = account.usage {
                ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                    HStack {
                        Text("\(window.label) · \(period(window.durationMinutes))")
                        Spacer(); Text("剩余 \(Int(window.remaining.rounded()))%").monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(theme.ink).opacity(0.08))
                            Capsule().fill(Color(theme.accent)).frame(width: geometry.size.width * window.remaining / 100)
                        }
                    }.frame(height: 4)
                    if let date = window.reset { Text("重置：\(deadlineText(date))").font(.caption).foregroundStyle(Color(theme.ink).opacity(0.6)).fixedSize(horizontal: false, vertical: true) }
                    else { Text("重置时间暂不可确定").font(.caption).foregroundStyle(Color(theme.ink).opacity(0.6)).fixedSize(horizontal: false, vertical: true) }
                }
                if let balance = usage.credits {
                    HStack { Text("账户余额"); Spacer(); Text(balance.unlimited ? "不限额" : (balance.formattedBalance ?? "未返回")).monospacedDigit() }
                    if let date = balance.expiresAt { Text("余额到期：\(deadlineText(date))").font(.caption).foregroundStyle(Color(theme.ink).opacity(0.6)) }
                }
                if let resets = usage.resetAllowance {
                    HStack { Text("可用重置"); Spacer(); Text("\(resets.availableCount) 次").monospacedDigit() }
                    if let count = resets.applicableCount, count != resets.availableCount {
                        Text("当前可用：\(count) 次").font(.caption).foregroundStyle(Color(theme.ink).opacity(0.6))
                    }
                    if let credits = resets.credits {
                        ForEach(credits, id: \.id) { credit in
                            Text(resetCreditText(credit))
                                .font(.caption).foregroundStyle(Color(theme.ink).opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                        }
                    } else if resets.availableCount > 0 {
                        Text("到期详情暂不可用").font(.caption).foregroundStyle(Color(theme.ink).opacity(0.6))
                    }
                }
            } else { Text(state.snapshot.refreshing ? "正在查询…" : "尚无额度结果") }
            if let note = account.activationNote { Text(note).font(.caption).foregroundStyle(Color(theme.ink).opacity(0.6)).fixedSize(horizontal: false, vertical: true) }
            if let error = account.error { Text(error).foregroundStyle(Color(theme.accent)).fixedSize(horizontal: false, vertical: true) }
            action("切换到此账号…", "arrow.triangle.2.circlepath", disabled: state.nativeRunning || state.busy || state.snapshot.refreshing || state.snapshot.loginRunning) { switchAccount(account.id) }
            if !account.current { action("移除此账号…", "minus.circle", disabled: state.busy || state.snapshot.refreshing || state.snapshot.loginRunning) { forget(account.id) } }
        }.padding(.horizontal, 8).padding(.top, 4)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = state.snapshot.error { Text(error).foregroundStyle(Color(theme.accent)).fixedSize(horizontal: false, vertical: true) }
            if state.snapshot.accounts.isEmpty { Text("暂无已保存账号").foregroundStyle(Color(theme.ink).opacity(0.6)) }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.snapshot.accounts, id: \.id) { account in
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration: PanelState.transitionDuration)) {
                                state.toggleAccountDetails(account.id)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                if account.current { Image(systemName: "checkmark").foregroundStyle(Color(theme.accent)) }
                                Text(account.email).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(account.subscriptionTitle).font(.caption).fixedSize()
                                    .foregroundStyle(Color(theme.ink).opacity(0.65))
                                    .help("官方套餐：\(account.subscriptionTitle)")
                                if let left = account.usage?.ordinaryRemaining { Text(account.error == nil ? "\(Int(left.rounded()))%" : "!").foregroundStyle(Color(theme.accent)).monospacedDigit() }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(MenuButtonStyle(theme: theme, selected: state.detailAccountID == account.id))
                        .onHover { state.hoverAccount(account.id, inside: $0, reduceMotion: reduceMotion) }
                        .accessibilityHint("显示此账号的额度详情")
                        .accessibilityValue(state.detailAccountID == account.id ? "已展开" : "已收起")
                    }
                    // Keep the account headers in place while moving the pointer into details.
                    // Inserting details between rows moves other accounts under the pointer and causes hover flicker.
                    ZStack(alignment: .topLeading) {
                        if let account = state.snapshot.accounts.first(where: { $0.id == state.detailAccountID }) {
                            accountDetails(account).id(account.id).transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).clipped()
                    .onHover { state.hoverDetails($0, reduceMotion: reduceMotion) }
                }
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { accountContentHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in accountContentHeight = height }
                })
            }.frame(maxHeight: state.bounds.listHeight).fixedSize(horizontal: false, vertical: true)
            // Fractional animation heights can look like overflow to the native, pixel-rounded viewport.
            .scrollIndicators(accountContentHeight > state.bounds.listHeight + 1 ? .visible : .never)
            .onHover { if !$0 { state.leaveAccountArea(reduceMotion: reduceMotion) } }
            Rectangle().fill(Color(theme.ink).opacity(0.12)).frame(height: 1)
            action(state.snapshot.refreshing ? "刷新中…" : "刷新", "arrow.clockwise",
                   disabled: state.snapshot.refreshing || state.busy || state.snapshot.loginRunning, run: refresh)
            action(state.snapshot.loginRunning ? "取消登录" : "添加账号…", "person.badge.plus", disabled: state.snapshot.refreshing || state.busy, run: addAccount)
            // The mounted hidden row must not add another outer menu gap.
            VStack(alignment: .leading, spacing: 0) {
                action("设置", "gearshape") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { state.settings.toggle() }
                }
                Button(action: toggleStart) {
                    HStack {
                        Label("登录时启动", systemImage: "power")
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Color(theme.accent)).opacity(state.startup ? 1 : 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuButtonStyle(theme: theme))
                .disabled(state.startupChanging)
                .padding(.horizontal, 12)
                .frame(height: state.settings ? 32 : 0, alignment: .top).clipped()
                .opacity(state.settings ? 1 : 0).allowsHitTesting(state.settings).accessibilityHidden(!state.settings)
                .accessibilityValue(state.startup ? "已开启" : "已关闭")
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: state.startup)
            }
            action("退出", "rectangle.portrait.and.arrow.right", run: quit)
        }
        .padding(14).frame(width: state.bounds.width).frame(maxHeight: state.bounds.maximumHeight)
        .foregroundStyle(Color(theme.ink)).background(Color(theme.surface))
        .font(theme.uiFont == nil || theme.uiFont == "-apple-system" ? .system(size: 13) : .custom(theme.uiFont!, size: 13))
        .preferredColorScheme(theme.dark ? .dark : .light)
        .onHover { if !$0 { state.leaveAccountArea(reduceMotion: reduceMotion) } }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { reportSize(geometry.size) }
                .onChange(of: geometry.size) { _, size in reportSize(size) }
        })
        .frame(maxWidth: .infinity)
        .frame(height: state.viewportHeight, alignment: .topLeading)
        .background(Color(theme.surface))
    }
}
