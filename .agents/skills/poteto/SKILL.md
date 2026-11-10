---
name: poteto
description: Use when installing or updating the poteto macOS menu bar app, troubleshooting its Codex account or quota features, or recovering local project layouts after an account switch.
---

# poteto

For installation, use the current [GitHub release](https://github.com/jiadizhunine/poteto/releases/latest) and the [English README](https://github.com/jiadizhunine/poteto/blob/main/README.en.md) or [中文 README](https://github.com/jiadizhunine/poteto/blob/main/README.md). The universal DMG and ZIP support macOS 14 and later on Apple Silicon and Intel. Keep an existing installation at its current path in `/Applications` or `~/Applications` so the login item and Keychain entry carry over. Quit poteto before replacing its bundle. Use the README's source build commands when the user asks to build from source.

Read [components and paths](references/components.md) to find the installed app, sign-in state, launch item, or source module. Use the menu to refresh quota or add an account. For a rejected credential, have the user sign in again through the app that owns it. Leave login and Keychain prompts to the user.

Read [project recovery](references/project-recovery.md) when switching fails or the local project sidebar is empty. Start with the read-only `--project-status` command. Use poteto's restore command for a compatible saved layout after the user has quit ChatGPT and Codex. Keep credential files, account IDs, and private paths out of reports and public issues.
