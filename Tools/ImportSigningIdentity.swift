import Foundation
import Security

func checked(_ status: OSStatus) {
    guard status == errSecSuccess else {
        fputs("Signing identity import failed (\(status)); no credentials were logged.\n", stderr)
        exit(1)
    }
}

guard CommandLine.arguments.count == 3 else { exit(2) }
let passwordData = FileHandle.standardInput.readDataToEndOfFile()
guard passwordData.count <= 256,
      let text = String(data: passwordData, encoding: .utf8),
      !text.trimmingCharacters(in: .newlines).isEmpty else { exit(2) }
let password = text.trimmingCharacters(in: .newlines) as CFString
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard data.count <= 65_536 else { exit(2) }
var keychain: SecKeychain?
checked(SecKeychainOpen(CommandLine.arguments[2], &keychain))
var trusted: SecTrustedApplication?
checked(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted))
var access: SecAccess?
checked(SecAccessCreate("poteto Local Code Signing" as CFString, [trusted!] as CFArray, &access))
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged.passUnretained(password)
parameters.accessRef = Unmanaged.passUnretained(access!)
let usage = [kSecAttrCanSign] as CFArray
let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
parameters.keyUsage = Unmanaged.passUnretained(usage)
parameters.keyAttributes = Unmanaged.passUnretained(attributes)
var format = SecExternalFormat.formatPKCS12
var itemType = SecExternalItemType.itemTypeAggregate
checked(SecItemImport(data as CFData, "p12" as CFString, &format, &itemType, [], &parameters, keychain, nil))
