<div align="center">

**English** | [简体中文](./README.md)

</div>

<h1 align="center">🥔 poteto</h1>

<p align="center"><img src="assets/icon.png" width="144" alt="poteto"></p>

<p align="center">Codex subscription usage and account management in your macOS menu bar</p>

poteto shows usage and reset times for official Codex subscriptions and lets you save and switch between official accounts. It requires macOS 14 or later. Menu switching uses the current user's `~/.codex/auth.json`. Adding accounts and starting the usage timer use the CLI bundled with the official ChatGPT app, in the system or user Applications folder or another location registered with macOS.

## Install

Download `poteto-v1.0.7-macos-universal.dmg` or `poteto-v1.0.7-macos-universal.zip` for v1.0.7 from [Releases](https://github.com/jiadizhunine/poteto/releases). Both packages include Apple Silicon and Intel binaries. Open the DMG or extract the ZIP, drag `poteto.app` to `/Applications` or `~/Applications`, and open it.

If macOS blocks the first launch, try opening the app, then go to **System Settings → Privacy & Security** and select **Open Anyway**. See [Apple's app-opening instructions](https://support.apple.com/en-us/102445).

Manage launch at login in settings. After moving the app, enable launch at login again to update its path.

## Use

1. Open poteto and click 🥔 in the menu bar.
2. Select **添加账号** (Add account) and sign in on the official login page.
3. View the plan, subscription validity date, usage, reset times, and any balance or reset credits returned by the service. Usage refreshes every 5 minutes, the subscription date updates with the login credentials, and failed reads are marked separately.
4. Before switching accounts, quit ChatGPT and Codex normally, then select the target account.

<p align="center">
  <a href="assets/screenshot-menu-redacted.png"><img src="assets/screenshot-menu-redacted.png" width="340" alt="poteto menu panel"></a>
  <a href="assets/screenshot-redacted.png"><img src="assets/screenshot-redacted.png" width="224" alt="poteto usage details"></a>
</p>

When all ordinary usage windows are full and the reset timer has not started, poteto sends one short message with that account's default model in a separate session to start the timer, at most once per period. The test consumes a small amount of subscription usage.

ChatGPT desktop versions with a shared layout retain local projects and their chat assignments when you switch accounts. Cloud projects stay with their original account.

On ChatGPT desktop versions `26.1111.21308` and `26.1111.71704`, poteto restores missing `@` reference records for existing chats when ChatGPT quits or when you switch accounts in poteto. This applies to unarchived local chats that previously supported native references. Open poteto, then quit and reopen ChatGPT. If `zstd` is installed, poteto can also read reference records from compressed logs.

For older ChatGPT versions with separate account layouts, poteto adds missing local projects and thread assignments while keeping the destination's organization. Before bringing projects to an account for the first time, sign in to it once in ChatGPT, then quit ChatGPT and Codex.

For an empty sidebar in an older account layout, use `--project-status` to inspect saved sources. Quit ChatGPT and Codex before running `--restore-projects`. For the newer shared layout, inspect projects directly in ChatGPT. [See the recovery steps](.agents/skills/poteto/references/project-recovery.md)

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
