"""Release metadata and rehearsal safeguards; real cryptography is exercised by rehearse."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("clipx_release_assets", ROOT / "Scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class UpdateAssetTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="clipx-update-tests-")
        self.addCleanup(workspace.cleanup)
        self.directory = Path(workspace.name)
        self.updates = self.directory / "updates"
        self.updates.mkdir()
        self.archive = "Clipx-0.1.0-1.zip"
        self.sources = "FFmpeg-sources.tar.gz"
        (self.updates / self.archive).write_bytes(b"archive fixture")
        (self.updates / self.sources).write_bytes(b"source fixture")
        (self.updates / "SHA256SUMS").write_text("fixture\n")
        self.feed = ET.fromstring(f'''<rss xmlns:sparkle="{release.SPARKLE}"><channel><item>
            <sparkle:version>1</sparkle:version>
            <enclosure url="https://github.com/{release.CONFIG['repository']}/releases/download/v0.1.0-1/{self.archive}"
                length="15" sparkle:edSignature="fixture-only"/>
            </item></channel></rss>''')
        self.manifest = {"tag": "v0.1.0-1", "version": "0.1.0", "build": "1",
                         "archive": self.archive, "sources": self.sources, "assets": {}}
        self.save_feed()
        self.manifest["assets"] = {path.name: release.digest(path) for path in self.updates.iterdir()}

    def save_feed(self):
        path = self.updates / "appcast.xml"
        path.write_bytes(ET.tostring(self.feed))
        self.manifest["assets"][path.name] = release.digest(path)

    def verify_metadata(self):
        # Only the metadata contract is tested here. Never claim that placeholder
        # signatures or fixture archives have passed the real Sparkle verifier.
        with patch.object(release, "sparkle_run"):
            release.verify_update_assets(self.directory, Path("unused"), self.manifest)

    def test_consistent_metadata_passes(self):
        self.verify_metadata()

    def test_changed_archive_is_rejected(self):
        (self.updates / self.archive).write_bytes(b"changed archive")
        with self.assertRaisesRegex(ValueError, "asset changed"):
            self.verify_metadata()

    def test_wrong_download_url_is_rejected_even_with_current_manifest_hash(self):
        self.feed.find("./channel/item/enclosure").set("url", "https://example.invalid/wrong.zip")
        self.save_feed()
        with self.assertRaisesRegex(ValueError, "URL or length"):
            self.verify_metadata()

    def test_wrong_download_size_is_rejected(self):
        self.feed.find("./channel/item/enclosure").set("length", "1000")
        self.save_feed()
        with self.assertRaisesRegex(ValueError, "URL or length"):
            self.verify_metadata()

    def test_duplicate_build_is_rejected(self):
        self.feed.find("channel").append(copy.deepcopy(self.feed.find("./channel/item")))
        self.save_feed()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify_metadata()

    def test_wrong_build_is_rejected(self):
        self.feed.find(f"./channel/item/{{{release.SPARKLE}}}version").text = "2"
        self.save_feed()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify_metadata()

    def test_missing_sources_are_rejected(self):
        del self.manifest["assets"][self.sources]
        with self.assertRaisesRegex(ValueError, "missing"):
            self.verify_metadata()

    def test_asset_outside_updates_is_rejected(self):
        outside = self.directory / "outside.txt"
        outside.write_text("outside updates")
        self.manifest["assets"]["../outside.txt"] = release.digest(outside)
        with self.assertRaisesRegex(ValueError, "asset changed"):
            self.verify_metadata()

    def test_renamed_source_archive_is_rejected_before_packaging(self):
        manifest = {"source_archive": "expected.tar.gz", "source_archive_sha256": release.digest(self.updates / self.sources)}
        with self.assertRaisesRegex(ValueError, "filename"):
            release.matching_sources(manifest, self.updates / self.sources)

    def test_reused_build_number_is_rejected_before_archive_generation(self):
        def fetch(destination):
            shutil.copy2(self.updates / "appcast.xml", destination)
        with patch.object(release, "fetch_feed", side_effect=fetch), patch.object(release, "sparkle_run"):
            with self.assertRaisesRegex(ValueError, "increase"):
                release.prepare_update_feed(self.directory / "candidate", {"CFBundleVersion": "1"}, Path("unused"))

    def test_newer_build_retains_the_base_feed_checksum(self):
        def fetch(destination):
            shutil.copy2(self.updates / "appcast.xml", destination)
        with patch.object(release, "fetch_feed", side_effect=fetch), patch.object(release, "sparkle_run"):
            baseline = release.prepare_update_feed(self.directory / "candidate", {"CFBundleVersion": "2"}, Path("unused"))
        self.assertEqual(baseline, release.digest(self.updates / "appcast.xml"))

    def test_rehearsal_is_rejected_before_keys_or_publication_even_with_release_manifest(self):
        (self.directory / "rehearsal.json").write_text(json.dumps({"publishable": False}))
        (self.directory / "release.json").write_text(json.dumps(self.manifest))
        blocked = AssertionError("A rehearsal must not access credentials or external tools")
        with patch.object(release, "sparkle_tools", side_effect=blocked), \
             patch.object(release, "run", side_effect=blocked), \
             patch.object(release, "output", side_effect=blocked):
            with self.assertRaisesRegex(ValueError, "Local rehearsal"):
                release.verify_package(self.directory)
            with self.assertRaisesRegex(ValueError, "Local rehearsal"):
                release.publish(SimpleNamespace(directory=self.directory, sparkle_bin=None))


if __name__ == "__main__":
    unittest.main()
