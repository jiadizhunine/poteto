<div align="center">

**English** | [简体中文](./README.md)

</div>

<h1 align="center">🥔 poteto</h1>

<p align="center"><img src="assets/icon.png" width="144" alt="poteto"></p>

<p align="center">Codex subscription usage and account management in your macOS menu bar</p>

![poteto menu bar interface with account information redacted](assets/screenshot-redacted.png)

poteto shows usage and reset times for official Codex subscriptions and lets you save and switch between official accounts. It requires macOS 14 or later. Adding accounts and starting the usage timer require the official ChatGPT desktop app at `/Applications/ChatGPT.app`.

## Install

Download `poteto-v1.0.0-macos-universal.dmg` or `poteto-v1.0.0-macos-universal.zip` for v1.0.0 from [Releases](https://github.com/jiadizhunine/poteto/releases). Both packages include Apple Silicon and Intel binaries. Open the DMG or extract the ZIP, drag `poteto.app` to `/Applications` or `~/Applications`, and open it. The download does not require a compiler.

The app uses a free self-signed certificate and is not notarized by Apple. A self-signed certificate is not an Apple Developer ID signature. If macOS blocks the first launch, try opening the app, then go to **System Settings → Privacy & Security** and select **Open Anyway**. See [Apple's guide to opening apps safely on your Mac](https://support.apple.com/en-us/102445).

Launch at login supports both installation locations. After moving the app, enable it again in settings to update the startup path. An already loaded startup job uses the new path at the next login; changing the setting does not quit the current app.

## Use

1. Open poteto and click 🥔 in the menu bar.
2. Select **添加账号** (Add account) and sign in on the official login page. Adding an account does not switch the current primary account.
3. View the plan, usage, reset times, and any balance or reset credits returned by the service. poteto refreshes every 5 minutes and marks failed reads separately.
4. Before switching accounts, quit ChatGPT and Codex normally, then select the target account. poteto checks for running native processes and does not switch while they are running.

When a successful read confirms that all ordinary usage windows are full and the longest window has a floating reset time for a full period, poteto sends one short test message using that account's native default model in an isolated temporary session. This starts the usage timer and consumes a small amount of subscription usage. If the result is uncertain, poteto does not retry automatically in that period. A reliable reset boundary is required before another period can trigger a test.

Before replacing `~/.codex/auth.json`, poteto merges ordinary local projects and their thread assignments into the target account's existing native project partition. Existing target projects stay in place and source projects are added. Conversation content, model and reasoning settings remain unchanged. Cloud account permissions are not copied.

If the target account has not been initialized in the native app, projects conflict, or the source contains an unsupported project structure, poteto stops before changing credentials. Sign in to a new account once in the native app, then quit it normally. poteto does not guess internal account identifiers to force inheritance. Keep the native app closed throughout switching.

Project inheritance has been tested with synthetic accounts and the installed app's native partition function, including switching back. A desktop switch between real accounts has not yet been tested.

Account credentials are stored in the local macOS Keychain. Display state such as email, plan and usage is saved in the local app data directory in files readable and writable only by the current user. Manage launch at login in poteto's settings.

## Build from source

The macOS Swift compiler is required. The first command creates a fixed self-signed identity on your Mac, with no Apple Developer membership required. Later builds reuse that identity.

```sh
git clone https://github.com/jiadizhunine/poteto.git
cd poteto
bash setup-signing.sh
bash build.sh
bash test.sh
bash install.sh
```

`install.sh` installs to `~/Applications/poteto.app` and enables launch at login.

## License

[MIT](./LICENSE)
