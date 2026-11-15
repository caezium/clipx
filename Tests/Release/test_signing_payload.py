"""Real Mach-O/code-signing checks; no Apple identity or GUI session required."""
import importlib.util
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("clipx_release", ROOT / "Scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class SigningPayloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="clipx-signing-tests-")
        cls.root = Path(cls.workspace.name)
        cls.original = cls.root / "Original.app"
        executable = cls.original / "Contents/MacOS/Clipx"
        executable.parent.mkdir(parents=True)
        resources = cls.original / "Contents/Resources"
        resources.mkdir()
        (resources / "notice.txt").write_text("Original resource\n")
        (resources / "notice-link").symlink_to("notice.txt")
        with (cls.original / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.clipx.signing-fixture", "CFBundleExecutable": "Clipx",
                          "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}, stream)
        code = cls.root / "main.c"
        code.write_text("int main(void) { return 0; }\n")
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-arch", "x86_64", str(code), "-o", str(executable)], check=True, capture_output=True)
        cls.before = release.unsigned_payload_manifest(cls.original)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(dir=self.root)
        self.app = Path(self.scratch.name) / "Clipx.app"
        shutil.copytree(self.original, self.app, symlinks=True)
        self.addCleanup(self.scratch.cleanup)

    def sign_fixture(self):
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", str(self.app)],
                       check=True, capture_output=True)

    def test_real_code_signature_changes_preserve_payload(self):
        self.sign_fixture()
        self.assertEqual(self.before, release.unsigned_payload_manifest(self.app))
        # Normalizing uses a private copy and must leave the received signature valid.
        subprocess.run(["codesign", "--verify", "--strict", str(self.app)], check=True, capture_output=True)

    def test_changed_resource_is_detected(self):
        (self.app / "Contents/Resources/notice.txt").write_text("Different resource\n")
        self.sign_fixture()
        self.assertNotEqual(self.before, release.unsigned_payload_manifest(self.app))

    def test_changed_executable_is_detected(self):
        code = Path(self.scratch.name) / "changed.c"
        code.write_text("int main(void) { return 7; }\n")
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-arch", "x86_64", str(code), "-o", str(self.app / "Contents/MacOS/Clipx")],
                       check=True, capture_output=True)
        self.sign_fixture()
        self.assertNotEqual(self.before, release.unsigned_payload_manifest(self.app))

    def test_changed_symlink_is_detected(self):
        link = self.app / "Contents/Resources/notice-link"
        link.unlink()
        link.symlink_to("../Info.plist")
        self.assertNotEqual(self.before, release.unsigned_payload_manifest(self.app))

    def test_ad_hoc_signature_cannot_pass_developer_id_gate(self):
        self.sign_fixture()
        subprocess.run(["csreq", "-r", release.developer_id_requirement(), "-t"], check=True, capture_output=True)
        # Establish that codesign accepts the inline requirement syntax before
        # testing the Developer ID rejection, rather than accepting a parse error.
        subprocess.run(["codesign", "--verify", "-R", '=identifier "com.clipx.signing-fixture"', str(self.app)],
                       check=True, capture_output=True)
        with self.assertRaises(subprocess.CalledProcessError) as rejected:
            release.assert_developer_id(self.app)
        self.assertEqual(rejected.exception.returncode, 3)

    def test_signed_mode_requires_original_build(self):
        with self.assertRaisesRegex(ValueError, "unsigned-reference"):
            release.verify_signed_app(self.app, None)


if __name__ == "__main__":
    unittest.main()
