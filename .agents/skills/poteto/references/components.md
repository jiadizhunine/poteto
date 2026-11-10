# Components and paths

| Component | Location and purpose |
| --- | --- |
| poteto app | `/Applications/poteto.app` or `~/Applications/poteto.app`. The menu bar UI and local commands use `Contents/MacOS/poteto` in this bundle. |
| Official CLI | `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex` in the official ChatGPT app. poteto looks in the system and user Applications folders and checks the registered app. It validates the CLI signature before login or quota activation. |
| poteto app data | `~/Library/Application Support/poteto/`. The app writes quota status, the activation ledger, and private project recovery backups here. |
| Saved accounts | macOS Keychain service `io.poteto.accounts`. The app stores its saved official logins there. |
| Login item | `~/Library/LaunchAgents/io.poteto.menubar.plist`. Toggle it in poteto settings. If you move poteto between the two Applications folders, enable it again from the new location. |
| Codex profile | The menu uses the file-based profile at `~/.codex`. `auth.json` is its login. `.codex-global-state.json` holds the native project sidebar layout. The recovery commands accept an explicit alternative profile path. |
| `Sources/PotetoApp.swift` | Menu bar app, account monitor, login flow, login item, and command entry points. |
| `Sources/Core.swift` | Credentials, quota parsing, native project state, and account switching. |
| `Sources/Activation.swift` | Official CLI lookup and quota timer activation in a separate Codex profile. |
| `Sources/Panel.swift` | Menu panel, account details, and display state. |
| `build.sh`, `test.sh`, `install.sh`, `package-release.sh` | Build, run checks, install a source build, or create universal release archives. |

If quota refresh fails for one account, check that account's status in the menu. For the current account, use the native sign-in flow. For another saved account, add it again in poteto. An HTTP 401 from the usage service concerns the saved login. The project recovery commands read local layout data separately.
