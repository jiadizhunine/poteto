import AppKit
import Foundation
import Darwin

@main
struct AppLifecycleSmoke {
    @MainActor
    static func main() {
        let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = NSApplication.shared
        // No native credentials or Keychain access in the AppKit lifecycle test.
        let monitor = Monitor(authURL: home.appendingPathComponent("absent-auth.json"),
                              statusURL: home.appendingPathComponent("status.json"),
                              load: { Vault() }, save: { _ in }, running: { false })
        let delegate = AppDelegate(monitor: monitor)
        app.delegate = delegate
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) {
            kill(getpid(), SIGTERM)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
