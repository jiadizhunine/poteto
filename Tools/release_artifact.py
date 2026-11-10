#!/usr/bin/env python3
import dataclasses
from pathlib import Path
import plistlib
import re
import subprocess
import sys

REQUIREMENT = '=identifier "io.poteto.menubar" and certificate leaf[subject.CN] = "poteto Local Code Signing"'
EXPECTED_FILES = {"Contents/Info.plist", "Contents/MacOS/poteto", "Contents/Resources/poteto.icns", "Contents/_CodeSignature/CodeResources"}


@dataclasses.dataclass(frozen=True)
class ReleaseArtifact:
    version: str
    slices: tuple[str, ...]
    minimumOS: str


def command(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout


def inspect(app: Path, source_root: Path) -> ReleaseArtifact:
    if app.is_symlink() or not app.is_dir():
        raise ValueError("app must be a directory, not a symlink")
    files = set()
    directories = set()
    for path in app.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"symlink in bundle: {path}")
        if path.is_file():
            files.add(path.relative_to(app).as_posix())
        elif path.is_dir():
            directories.add(path.relative_to(app).as_posix())
        else:
            raise ValueError(f"unsupported bundle entry: {path}")
    if directories != {"Contents", "Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature"}:
        raise ValueError("unexpected bundle directories")
    if files != EXPECTED_FILES:
        raise ValueError(f"unexpected bundle files: {sorted(files ^ EXPECTED_FILES)}")
    with (app / "Contents/Info.plist").open("rb") as f:
        info = plistlib.load(f)
    if info.get("CFBundleIdentifier") != "io.poteto.menubar" or info.get("CFBundleExecutable") != "poteto":
        raise ValueError("unexpected bundle identity or executable")
    version = info.get("CFBundleShortVersionString")
    minimum = info.get("LSMinimumSystemVersion")
    if version != "1.0.3" or not isinstance(minimum, str) or not re.fullmatch(r"\d+(?:\.\d+){1,2}", minimum):
        raise ValueError("unexpected bundle version or minimum OS")
    command("/usr/bin/codesign", "--verify", "--strict", "-R", REQUIREMENT, str(app))
    binary = app / "Contents/MacOS/poteto"
    slices = tuple(sorted(command("/usr/bin/lipo", "-archs", str(binary)).split()))
    if slices != ("arm64", "x86_64"):
        raise ValueError(f"expected both supported slices, got {slices}")
    for arch in slices:
        output = command("/usr/bin/vtool", "-arch", arch, "-show-build", str(binary))
        versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+){1,2})\s*$", output, re.M)
        if len(versions) != 1 or (tuple(map(int, versions[0].split('.'))) + (0, 0))[:3] != (tuple(map(int, minimum.split('.'))) + (0, 0))[:3]:
            raise ValueError(f"minimum OS mismatch for {arch}: {versions}")
    prohibited = [str(source_root.resolve()).encode(), str(Path.home()).encode()]
    for relative in files:
        data = (app / relative).read_bytes()
        if any(value and value in data for value in prohibited) or re.search(rb"/Users/[^/\x00\s]+/", data):
            raise ValueError(f"personal build path in {relative}")
    return ReleaseArtifact(version, slices, minimum)


def compare_contents(original: Path, candidate: Path):
    for relative in EXPECTED_FILES:
        if (original / relative).read_bytes() != (candidate / relative).read_bytes():
            raise ValueError(f"archive content differs: {relative}")


def inspect_root(root: Path, kind: str):
    expected = {"poteto.app"} if kind == "zip" else {"poteto.app", "Applications"}
    if kind not in {"zip", "dmg"} or {p.name for p in root.iterdir()} != expected:
        raise ValueError("unexpected archive root entries")
    app = root / "poteto.app"
    if app.is_symlink() or not app.is_dir():
        raise ValueError("archive app must be a directory")
    if kind == "dmg":
        link = root / "Applications"
        if not link.is_symlink() or str(link.readlink()) != "/Applications":
            raise ValueError("invalid Applications link")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--compare":
            compare_contents(Path(sys.argv[2]), Path(sys.argv[3]))
        elif sys.argv[1] == "--root":
            inspect_root(Path(sys.argv[2]), sys.argv[3])
        else:
            artifact = inspect(Path(sys.argv[1]), Path(sys.argv[2]))
            print(f"version={artifact.version} slices={','.join(artifact.slices)} minimumOS={artifact.minimumOS}")
    except (IndexError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Release bundle validation failed: {error}", file=sys.stderr)
        sys.exit(1)
