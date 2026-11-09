import Foundation

@main
struct SigningVaultSmoke {
    static func main() {
        // Explicit, read-only check of poteto's vault; no native auth/config or network access.
        guard CommandLine.arguments.dropFirst() == ["--read-poteto-vault"] else { exit(2) }
        do {
            let vault = try CredentialStore.load()
            guard !vault.accounts.isEmpty else { exit(1) }
            print("different signed binary read \(vault.accounts.count) poteto accounts non-interactively; no data logged or changed")
        } catch {
            fputs("Non-interactive poteto vault access failed; no credentials logged.\n", stderr)
            exit(1)
        }
    }
}
