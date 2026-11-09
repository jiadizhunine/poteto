#!/usr/bin/env python3
"""Build in a temporary directory; simulate installation without system changes."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STAGE = Path("build/.poteto-staging.noindex/poteto-staging.app")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
REQUIREMENT = '=identifier "io.poteto.menubar" and certificate leaf[subject.CN] = "poteto Local Code Signing"'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def bundle_id(app, identifier):
    info = app / "Contents/Info.plist"
    info.parent.mkdir(parents=True, exist_ok=True)
    info.write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))


with tempfile.TemporaryDirectory(prefix="poteto-packaging-") as directory:
    scratch = Path(directory).resolve()
    native = scratch / "native"
    native.mkdir()
    for name in ("build.sh", "install.sh"):
        run("/bin/bash", "-n", str(ROOT / name))
        shutil.copy2(ROOT / name, native / name)
    shutil.copytree(ROOT / "Sources", native / "Sources")
    (native / "Tools").mkdir()
    shutil.copy2(ROOT / "Tools/Icon.swift", native / "Tools/Icon.swift")
    run("/bin/bash", "build.sh", cwd=native)
    packaged = native / STAGE
    run("/usr/bin/codesign", "--verify", "--strict", "-R", REQUIREMENT, str(packaged))
    assert not (native / "build/poteto.app").exists()
    info = plistlib.loads((packaged / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "io.poteto.menubar"
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "poteto"
    assert info["CFBundleIconFile"] == "poteto.icns"
    assert info["LSUIElement"] is True
    decoded = scratch / "decoded.iconset"
    run("/usr/bin/iconutil", "--convert", "iconset", str(packaged / "Contents/Resources/poteto.icns"), "--output", str(decoded))
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            png = (decoded / f"icon_{points}x{points}{suffix}.png").read_bytes()
            assert png[:8] == b"\x89PNG\r\n\x1a\n"
            assert struct.unpack(">II", png[16:24]) == (points * scale, points * scale)
    print("PASS: hidden signed native bundle, plist icon, and all 10 PNG sizes", flush=True)

    missing_identity = scratch / "missing-identity"
    missing_identity.mkdir()
    (missing_identity / "build.sh").write_text((ROOT / "build.sh").read_text().replace("poteto Local Code Signing", "poteto missing identity fixture"))
    old_stage = missing_identity / STAGE / "keep.txt"
    old_stage.parent.mkdir(parents=True)
    old_stage.write_text("do not remove a previous build when signing is unavailable")
    result = subprocess.run(["/bin/bash", "build.sh"], cwd=missing_identity, capture_output=True, text=True)
    assert result.returncode != 0 and "no ad-hoc fallback" in result.stderr
    assert old_stage.read_text().startswith("do not remove")

    adhoc = scratch / "adhoc-installer"
    adhoc.mkdir()
    shutil.copy2(ROOT / "install.sh", adhoc / "install.sh")
    shutil.copytree(packaged, adhoc / STAGE)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "io.poteto.menubar", str(adhoc / STAGE))
    environment = dict(os.environ, HOME=str(adhoc / "user"))
    result = subprocess.run(["/bin/bash", "install.sh"], cwd=adhoc, env=environment, capture_output=True, text=True)
    assert result.returncode != 0 and not (adhoc / "user/Applications/poteto.app").exists()
    assert "code failed to satisfy specified code requirement" in result.stderr, result.stderr
    print("PASS: missing identity fails before replacing staging; real installer rejects an ad-hoc App before any service change", flush=True)

    failed_build = scratch / "failed-build"
    failed_build.mkdir()
    (failed_build / "build.sh").write_text((ROOT / "build.sh").read_text().replace("/usr/bin/swiftc", "/usr/bin/false"))
    result = subprocess.run(["/bin/bash", "build.sh"], cwd=failed_build, capture_output=True, text=True)
    assert result.returncode != 0 and not (failed_build / STAGE).exists()

    mock = scratch / "mock.py"
    mock.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, subprocess, sys
tool = pathlib.Path(sys.argv[0]).name
with open(os.environ["POTETO_TEST_LOG"], "a") as log:
    log.write(json.dumps([tool, *sys.argv[1:]]) + "\\n")
if tool == os.environ.get("POTETO_TEST_FAIL_TOOL"):
    sys.exit(1)
if tool == "ditto":
    sys.exit(subprocess.run(["/usr/bin/ditto", *sys.argv[1:]]).returncode)
''')
    mock.chmod(0o755)
    commands = scratch / "commands"
    commands.mkdir()
    for name in ("codesign", "launchctl", "lsregister", "ditto"):
        shutil.copy2(mock, commands / name)

    def fixture(name, staged=True):
        project = scratch / name
        project.mkdir()
        seed = project / "seed.app"
        shutil.copytree(packaged, seed)
        shutil.copy2(mock, seed / "Contents/MacOS/poteto")
        app = project / STAGE
        if staged:
            shutil.copytree(seed, app)
        installer = (ROOT / "install.sh").read_text().replace("$HOME", "$POTETO_TEST_HOME")
        for command in ("codesign", "launchctl", "ditto"):
            prefix = "/bin" if command == "launchctl" else "/usr/bin"
            installer = installer.replace(f"{prefix}/{command}", str(commands / command))
        installer = installer.replace(LSREGISTER, str(commands / "lsregister"))
        (project / "install.sh").write_text(installer)
        (project / "build.sh").write_text(f'#!/bin/bash\nset -euo pipefail\nprintf \'["build"]\\n\' >> "$POTETO_TEST_LOG"\nmkdir -p "{app.parent}"\n/usr/bin/ditto "{seed}" "{app}"\n')
        test_home = project / "user"
        sentinel = test_home / "Applications/ChatGPT.app/keep.txt"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text("unrelated app must stay untouched")
        log = project / "calls.jsonl"
        environment = dict(os.environ, POTETO_TEST_HOME=str(test_home), POTETO_TEST_LOG=str(log))
        return project, app, project / "build/poteto.app", test_home / "Applications/poteto.app", sentinel, log, environment

    def install(case, *args, success=True):
        project, app, legacy, target, sentinel, log, environment = case
        result = subprocess.run(["/bin/bash", "install.sh", *args], cwd=project, env=environment, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        assert sentinel.read_text() == "unrelated app must stay untouched"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        if success:
            assert target.is_dir() and not app.exists() and not legacy.exists()
            assert (target / "Contents/Resources/poteto.icns").is_file()
            assert [call for call in calls if call[0] == "lsregister"] == [
                ["lsregister", "-u", str(legacy)], ["lsregister", "-u", str(app)], ["lsregister", "-f", str(target)]
            ], calls
        return calls

    fresh = fixture("fresh", staged=False)
    calls = install(fresh)
    assert calls[0] == ["build"] and calls[-1] == ["poteto", "--enable-login"]
    assert not any(call[0] == "launchctl" for call in calls)

    update = fixture("update with spaces")
    for app in (update[2], update[3]):
        bundle_id(app, "io.poteto.menubar")
    arguments = ("auth export/one.json", "auth export/two.json")
    calls = install(update, *arguments)
    assert [call for call in calls if call[0] == "launchctl"] == [["launchctl", "bootout", f"gui/{os.getuid()}/io.poteto.menubar"]]
    assert calls[-2:] == [["poteto", "--migrate", *arguments], ["poteto", "--enable-login"]]

    authorize = fixture("authorize-existing-vault")
    calls = install(authorize, "--authorize-keychain")
    assert calls[-2:] == [["poteto", "--migrate"], ["poteto", "--enable-login"]]

    for index, name in ((2, "unrelated-legacy"), (3, "unrelated-target")):
        case = fixture(name)
        bundle_id(case[index], "com.example.unrelated")
        assert install(case, success=False) == []
        assert case[index].is_dir() and case[1].is_dir()

    for index, name in ((1, "symlink-stage"), (2, "symlink-legacy"), (3, "symlink-target")):
        case = fixture(name)
        path = case[index]
        if path.exists():
            shutil.rmtree(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(case[4].parent, target_is_directory=True)
        assert install(case, success=False) == []
        assert path.is_symlink()

    unsigned = fixture("bad-signature")
    unsigned[6]["POTETO_TEST_FAIL_TOOL"] = "codesign"
    calls = install(unsigned, success=False)
    assert calls == [["codesign", "--verify", "--strict", "-R", REQUIREMENT, str(unsigned[1])]]
    assert unsigned[1].is_dir() and not unsigned[3].exists()

    failed_copy = fixture("failed-copy")
    bundle_id(failed_copy[2], "io.poteto.menubar")
    failed_copy[6]["POTETO_TEST_FAIL_TOOL"] = "ditto"
    calls = install(failed_copy, success=False)
    assert calls[-1] == ["ditto", str(failed_copy[1]), str(failed_copy[3])]
    assert failed_copy[1].is_dir() and failed_copy[2].is_dir()
    assert not any(call[0] in ("lsregister", "poteto") for call in calls)

    failed_migration = fixture("failed-migration")
    bundle_id(failed_migration[2], "io.poteto.menubar")
    failed_migration[6]["POTETO_TEST_FAIL_TOOL"] = "poteto"
    calls = install(failed_migration, "auth export/one.json", success=False)
    assert not failed_migration[1].exists() and not failed_migration[2].exists()
    assert calls[-1] == ["poteto", "--migrate", "auth export/one.json"]
    print("PASS: fresh/update install, exact cleanup, migration/login arguments, unrelated and symlink guards, and failure paths (mocked)")
