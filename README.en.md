<div align="center">

**English** | [简体中文](./README.md)

</div>

<h1 align="center">🥔 poteto</h1>

<p align="center"><img src="assets/icon.png" width="144" alt="poteto"></p>

<p align="center">Codex subscription usage and account management in your macOS menu bar</p>

poteto shows usage and reset times for official Codex subscriptions and lets you save and switch between official accounts. It requires macOS 14 or later. Menu switching uses the current user's `~/.codex/auth.json`. Adding accounts and starting the usage timer use the CLI bundled with the official ChatGPT app, in the system or user Applications folder or another location registered with macOS.

## Install

Download `poteto-v1.0.3-macos-universal.dmg` or `poteto-v1.0.3-macos-universal.zip` for v1.0.3 from [Releases](https://github.com/jiadizhunine/poteto/releases). Both packages include Apple Silicon and Intel binaries. Open the DMG or extract the ZIP, drag `poteto.app` to `/Applications` or `~/Applications`, and open it.

If macOS blocks the first launch, try opening the app, then go to **System Settings → Privacy & Security** and select **Open Anyway**. See [Apple's app-opening instructions](https://support.apple.com/en-us/102445).

Manage launch at login in settings. After moving the app, enable launch at login again to update its path.

## Use

1. Open poteto and click 🥔 in the menu bar.
2. Select **添加账号** (Add account) and sign in on the official login page.
3. View the plan, usage, reset times, and any balance or reset credits returned by the service. poteto refreshes every 5 minutes and marks failed reads separately.
4. Before switching accounts, quit ChatGPT and Codex normally, then select the target account.

<p align="center">
  <a href="assets/screenshot-menu-redacted.png"><img src="assets/screenshot-menu-redacted.png" width="340" alt="poteto menu panel"></a>
  <a href="assets/screenshot-redacted.png"><img src="assets/screenshot-redacted.png" width="224" alt="poteto usage details"></a>
</p>

When all ordinary usage windows are full and the reset timer has not started, poteto sends one short message with that account's default model in a separate session to start the timer, at most once per period. The test consumes a small amount of subscription usage.

When you switch to an account that ChatGPT has already initialized, poteto merges local projects and thread assignments automatically. The destination keeps its existing project names, appearances, order, and thread assignments. Switching preserves both accounts' projects, chat history, model, and reasoning settings.

To bring local projects to a new account, sign in to the destination account once in ChatGPT. Then use poteto to switch to it from the account with the projects. Cloud projects stay with their original account. poteto flags conflicting project folders.

If the project sidebar is empty after switching, recover local projects and thread assignments from an account layout saved on this Mac. Use `--project-status` to inspect layouts. Quit ChatGPT and Codex before running `--restore-projects`. [See the recovery steps](.agents/skills/poteto/references/project-recovery.md)

Account credentials are stored in the macOS Keychain. Account display information and usage records are saved locally.

## Build from source

The macOS Swift compiler is required. `setup-signing.sh` creates a fixed local signing identity that later builds reuse.

```sh
git clone https://github.com/jiadizhunine/poteto.git
cd poteto
bash setup-signing.sh
bash build.sh
bash test.sh
bash install.sh
```

`install.sh` installs to `~/Applications/poteto.app` and enables launch at login.

To have an agent install, maintain, or troubleshoot the app, invoke `$poteto` in this checkout. [Project skill](.agents/skills/poteto/SKILL.md)

## License

[MIT](./LICENSE)
