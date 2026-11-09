import AppKit
import SwiftUI

@main
struct PanelSnapshot {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let state = PanelState()
        state.theme = DesktopTheme(surface: DesktopTheme.hex("#f3eee3")!, ink: DesktopTheme.hex("#2b2924")!, accent: DesktopTheme.hex("#d97857")!, uiFont: nil)
        state.availableScreenSize = NSSize(width: 800, height: 600)
        let later = Date().addingTimeInterval(172800)
        let usage = Usage(plan: "pro", windows: [UsageWindow(label: "Codex", durationMinutes: 10080, remaining: 33, reset: later, ordinary: true)], checkedAt: Date(),
                          credits: CreditBalance(balance: "56509.1182155", unlimited: false, expiresAt: nil),
                          resetAllowance: ResetAllowance(availableCount: 2, applicableCount: 2, credits: [ResetCredit(id: "fixture-reset", title: "额度重置", expiresAt: later)]))
        state.snapshot = Snapshot(accounts: [AccountView(id: "fixture-current", email: "current@example.invalid", workspace: "fixture", current: true, plan: "pro", usage: usage, error: nil),
            AccountView(id: "fixture-other", email: "other@example.invalid", workspace: "fixture", current: false, plan: "free", usage: nil, error: nil)], refreshing: false, error: nil, loginRunning: false)
        if CommandLine.arguments.contains("--details") { state.previewAccount("fixture-current") }
        state.settings = CommandLine.arguments.contains("--settings")
        precondition(potetoIcon().tiffRepresentation != nil, "poteto alert icon must render without bundle resources")
        let view = NSHostingView(rootView: PotetoPanel(state: state, refresh: {}, addAccount: {}, switchAccount: { _ in }, forget: { _ in }, toggleStart: {}, quit: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 568), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.sizingOptions = [.intrinsicContentSize]
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        precondition(size.width <= state.bounds.width + 1 && size.height <= state.bounds.maximumHeight + 1, "native panel exceeds available screen")
        window.setContentSize(size)
        view.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PotetoError.malformed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PotetoError.malformed }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("poteto: native panel snapshot checked (\(Int(size.width)) × \(Int(size.height)) points)")
    }
}
