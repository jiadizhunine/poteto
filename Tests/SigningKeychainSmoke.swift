import Foundation
import Security

#if UPDATED_BINARY
let version = "updated"
#else
let version = "original"
#endif

func checked(_ status: OSStatus, _ action: String) {
    guard status == errSecSuccess else {
        fputs("Signing smoke \(action) failed (\(status)).\n", stderr)
        exit(1)
    }
}

guard CommandLine.arguments.count == 3 else { exit(2) }
let command = CommandLine.arguments[1]
let path = URL(fileURLWithPath: CommandLine.arguments[2])
guard path.lastPathComponent == "fixture.keychain",
      path.deletingLastPathComponent().lastPathComponent.hasPrefix("poteto-signing-smoke.") else { exit(2) }
checked(SecKeychainSetUserInteractionAllowed(false), "disable interaction in test process")
var keychain: SecKeychain?
if command == "create" {
    guard !FileManager.default.fileExists(atPath: path.path) else { exit(2) }
    var searchList: CFArray?
    checked(SecKeychainCopySearchList(&searchList), "read search list")
    var password = [UInt8](repeating: 0, count: 48)
    checked(SecRandomCopyBytes(kSecRandomDefault, password.count, &password), "random fixture password")
    let status = password.withUnsafeBytes {
        SecKeychainCreate(path.path, UInt32(password.count), $0.baseAddress, false, nil, &keychain)
    }
    // A private fixture must not remain in the user's Keychain search list.
    checked(SecKeychainSetSearchList(searchList!), "restore search list")
    checked(status, "create isolated Keychain")
} else {
    checked(SecKeychainOpen(path.path, &keychain), "open isolated Keychain")
}
guard let keychain = keychain else { exit(1) }
let service = "io.poteto.signing-smoke"
let data = Data("fictional test value - not an account credential".utf8)
if command == "create" {
    checked(SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccount: "fixture", kSecValueData: data,
                       kSecUseKeychain: keychain] as CFDictionary, nil), "create fictional item")
    print("created fictional item in isolated Keychain")
} else if command == "cleanup" {
    checked(SecKeychainDelete(keychain), "delete isolated Keychain")
} else {
    guard command == "read" || command == "deny" else { exit(2) }
    var result: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: service, kSecAttrAccount: "fixture",
                                     kSecMatchSearchList: [keychain], kSecReturnData: true,
                                     kSecUseAuthenticationUI: kSecUseAuthenticationUIFail] as CFDictionary, &result)
    if command == "deny" {
        guard status == errSecInteractionNotAllowed || status == errSecAuthFailed else {
            fputs("Unexpected untrusted signer result (\(status)).\n", stderr); exit(1)
        }
        print("untrusted signature denied without a password dialog")
    } else {
        checked(status, "\(version) non-interactive read")
        guard result as? Data == data else { exit(1) }
        print("\(version) binary read the same item without a password dialog")
    }
}
