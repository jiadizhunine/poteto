# Recover the local project sidebar

Use poteto v1.0.2 or later. Find the installed bundle and inspect the current layout:

```sh
poteto_app=/Applications/poteto.app
if [ ! -x "$poteto_app/Contents/MacOS/poteto" ]; then
  poteto_app="$HOME/Applications/poteto.app"
fi
poteto_cli="$poteto_app/Contents/MacOS/poteto"
"$poteto_cli" --project-status
```

The report gives local project and thread assignment counts and lists compatible saved source slots. The slot is the identifier used by the restore command on this Mac. For a profile at a custom location, pass `--codex-home /absolute/path/to/codex-home` to both commands. Use the path the native client actually uses. The menu's account switch uses the default profile.

If the original account still shows the projects, that layout can serve as the source after you return to the destination account. For a new destination account, sign in once in ChatGPT and let it initialize. Confirm the destination and source before writing. After tasks finish, have the user fully quit ChatGPT and Codex. With a single compatible source, run:

```sh
"$poteto_cli" --restore-projects
```

If the status lists several sources, identify the intended layout with the user. Check the layout in the original account if the counts are insufficient. Then run `"$poteto_cli" --restore-projects --from '<slot>'` with the selected slot. Each restore uses one source.

A successful write saves a private copy of the previous native state in `~/Library/Application Support/poteto/Project Recovery/`. Read `--project-status` again and compare the counts, then reopen ChatGPT and check the sidebar.

The restore command merges supported local project definitions and thread assignments into the current account's layout. Cloud and remote projects remain with their original accounts. For a conflict, an unrecognized state format, or an absent file-based login, stop at the reported reason and inspect the layout in the native app. Avoid hand-editing the state file, manufacturing an owner slot, or replacing an entire profile with an older copy. A missing source layout requires a separately verified local backup.
