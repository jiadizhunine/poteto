import Foundation

@main
struct LoginStartTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("poteto-login-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let bundle = home.appendingPathComponent("Applications/poteto.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/poteto")
        let plist = home.appendingPathComponent("Library/LaunchAgents/io.poteto.menubar.plist")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        func payload(_ path: String, label: String = launchLabel) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": [path]], format: .xml, options: 0)
        }
        try PrivateFiles.write(payload("/Applications/poteto.app/Contents/MacOS/poteto"), to: plist)
        var calls = [[String]]()
        var hostRunning = true
        let command: ([String]) -> Int32 = { calls.append($0); if $0.contains("bootout") { hostRunning = false }; return 0 }
        try LoginStart.configure(true, bundle: bundle, home: home, plist: plist, command: command)
        precondition(hostRunning, "changing login startup must not terminate the app")
        let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        precondition(result["ProgramArguments"] as? [String] == [executable.path])
        precondition(calls.map { $0[1] } == ["enable", "print"])
        calls.removeAll()
        try LoginStart.configure(false, bundle: bundle, home: home, plist: plist, command: command)
        precondition(hostRunning && !fm.fileExists(atPath: plist.path) && calls.map { $0[1] } == ["disable"])
        calls.removeAll()
        try LoginStart.configure(true, bundle: bundle, home: home, plist: plist, command: { args in
            calls.append(args)
            return args[1] == "print" ? 1 : 0
        })
        precondition(calls.map { $0[1] } == ["enable", "print", "bootstrap"])
        precondition(fm.fileExists(atPath: plist.path))
        try PrivateFiles.write(payload("/tmp/other"), to: plist)
        calls.removeAll()
        do { try LoginStart.configure(true, bundle: bundle, home: home, plist: plist, command: command); fatalError("accepted foreign plist") } catch {}
        precondition(calls.isEmpty && fm.fileExists(atPath: plist.path))
        do { _ = try LoginStart.executable(bundle: home.appendingPathComponent("other.app"), home: home); fatalError("accepted arbitrary bundle") } catch {}
        let systemExecutable = try LoginStart.executable(bundle: URL(fileURLWithPath: "/Applications/poteto.app"), home: home)
        precondition(systemExecutable.path == "/Applications/poteto.app/Contents/MacOS/poteto")
        try LoginStart.owned(payload(executable.path), home: home)
        print("LoginStart fake migration and rejection tests passed")
    }
}
