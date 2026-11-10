#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_artifact", ROOT / "Tools/release_artifact.py")
module = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="poteto-fixture-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / "poteto.app"
        for name in module.EXPECTED_FILES:
            path = self.app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.poteto.menubar", "CFBundleExecutable": "poteto", "CFBundleShortVersionString": "1.0.4", "LSMinimumSystemVersion": "14.0"}))
        self.slices = "arm64 x86_64"
        self.minimum = "14.0"
        self.calls = []

    def command(self, *args):
        self.calls.append(args)
        if args[0].endswith("lipo"):
            return self.slices
        if args[0].endswith("vtool"):
            return f"Load command 10\n      cmd LC_BUILD_VERSION\n    minos {self.minimum}\n"
        return ""

    def inspect(self):
        with patch.object(module, "command", self.command):
            return module.inspect(self.app, self.root / "checkout")

    def test_valid_bundle_derives_artifact_and_verifies_signature(self):
        artifact = self.inspect()
        self.assertEqual((artifact.version, artifact.slices, artifact.minimumOS), ("1.0.4", ("arm64", "x86_64"), "14.0"))
        self.assertTrue(any(call[0].endswith("codesign") and "--strict" in call for call in self.calls))

    def test_rejects_wrong_slices_and_minimum(self):
        self.slices = "arm64"
        with self.assertRaisesRegex(ValueError, "slices"):
            self.inspect()
        self.slices = "arm64 x86_64"
        self.minimum = "13.0"
        with self.assertRaisesRegex(ValueError, "minimum OS"):
            self.inspect()

    def test_rejects_private_paths_and_extra_files(self):
        binary = self.app / "Contents/MacOS/poteto"
        binary.write_bytes(b"/Users/person/private/source.swift\x00")
        with self.assertRaisesRegex(ValueError, "personal build path"):
            self.inspect()
        binary.write_bytes(b"fixture")
        (self.app / "Contents/secrets.json").write_text("secret")
        with self.assertRaisesRegex(ValueError, "unexpected bundle files"):
            self.inspect()

    def test_rejects_symlink_and_wrong_version(self):
        (self.app / "Contents/link").symlink_to("Info.plist")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.inspect()
        (self.app / "Contents/link").unlink()
        data = plistlib.loads(self.info.read_bytes())
        data["CFBundleShortVersionString"] = "2.0.0"
        self.info.write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(ValueError, "version"):
            self.inspect()



class RootTests(unittest.TestCase):
    def test_archive_roots_reject_extra_entries_and_wrong_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "poteto.app").mkdir()
            module.inspect_root(root, "zip")
            (root / "extra").mkdir()
            with self.assertRaisesRegex(ValueError, "root entries"):
                module.inspect_root(root, "zip")
            (root / "extra").rmdir()
            (root / "Applications").symlink_to("/Applications")
            module.inspect_root(root, "dmg")
            (root / "Applications").unlink()
            (root / "Applications").symlink_to("/tmp")
            with self.assertRaisesRegex(ValueError, "Applications"):
                module.inspect_root(root, "dmg")

    def test_changed_archive_content_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for side in ("original", "copy"):
                for name in module.EXPECTED_FILES:
                    path = root / side / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"same")
            module.compare_contents(root / "original", root / "copy")
            (root / "copy/Contents/MacOS/poteto").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "content differs"):
                module.compare_contents(root / "original", root / "copy")

    def test_rejects_extra_empty_bundle_directory(self):
        fixture = BundleTests("test_valid_bundle_derives_artifact_and_verifies_signature")
        fixture.setUp()
        try:
            (fixture.app / "Contents/Extra").mkdir()
            with self.assertRaisesRegex(ValueError, "directories"):
                fixture.inspect()
        finally:
            fixture.doCleanups()

if __name__ == "__main__":
    unittest.main()
