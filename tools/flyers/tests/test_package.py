"""Portable package round trips, filter integrity and failed-build isolation."""

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from flyerkit.download import write_json
from flyerkit.package import build_package
from flyerkit.package_verify import verify_package
from flyerkit.pipeline import database, save_offer
from flyerkit.source import geography, stable_id
from test_pipeline import flyer_page, proposal, seed_image


class PackageTests(unittest.TestCase):
    def dataset(self, root):
        flyer, page = flyer_page()
        first = proposal()
        seed_image(root, first)
        page["sha256"] = first["evidence"]["image_sha256"]
        flyer["pages"] = [page]
        write_json((root / page["path"]).parent / "manifest.json", flyer)
        first["review"].update(
            status="validated", reviewer="SYNTHETIC fixture reviewer"
        )
        second = copy.deepcopy(first)
        second["offer_id"] = stable_id("pending fixture")
        second["review"].update(status="needs_review", reviewer=None)
        other = copy.deepcopy(flyer)
        other["flyer_id"] = "b" * 24
        other["geography"] = geography("Sobeys (QC) Flyer")
        write_json(root / "regions" / "QC" / "test" / "manifest.json", other)
        third = copy.deepcopy(second)
        third.update(
            offer_id=stable_id("rejected fixture"),
            flyer_id=other["flyer_id"],
            geography=other["geography"],
        )
        third["review"].update(status="rejected", reviewer="SYNTHETIC fixture reviewer")
        with database(root) as db:
            for offer in (first, second, third):
                save_offer(db, offer)
        return [first, second, third]

    def build(self, directory):
        root = directory / "source"
        self.dataset(root)
        output = directory / "snapshot"
        result = build_package(root, output, as_of="2026-10-18", expected_offers=3)
        return output, result

    def rehash(self, output, name):
        manifest = json.loads((output / "package.json").read_text())
        data = (output / name).read_bytes()
        entry = next(f for f in manifest["files"] if f["path"] == name)
        entry.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        write_json(output / "package.json", manifest)

    def test_archive_verifies_outside_the_collector_and_preserves_states(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            output, result = self.build(directory)
            self.assertEqual(result["validation"]["offers"], 3)
            self.assertEqual(result["validation"]["needs_review"], 1)
            self.assertEqual(result["validation"]["validated_deals"], 1)
            self.assertEqual(result["validation"]["rejected"], 1)
            target = directory / "unpacked"
            with zipfile.ZipFile(result["archive"]) as archive:
                archive.extractall(target)
            package = target / output.name
            completed = subprocess.run(
                [sys.executable, str(package / "verify.py"), str(package)],
                cwd=target,
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(json.loads(completed.stdout)["status"], "pass")
            self.assertFalse(list(package.rglob("*.sqlite3")))
            self.assertFalse(list(package.rglob("*.png")))

    def test_unreviewed_offer_cannot_leak_into_checked_export(self):
        with tempfile.TemporaryDirectory() as temp:
            output, _ = self.build(Path(temp))
            manifest = json.loads((output / "package.json").read_text())
            offers = json.loads((output / manifest["layout"]["offers"]).read_text())
            pending = next(o for o in offers if o["review"]["status"] == "needs_review")
            name = manifest["layout"]["validated_deals"]
            with (output / name).open("a") as stream:
                stream.write(json.dumps(pending) + "\n")
            self.rehash(output, name)
            with self.assertRaisesRegex(ValueError, "filtered export"):
                verify_package(output)

    def test_inventory_tampering_and_path_escape_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            output, _ = self.build(Path(temp))
            (output / "retailers.json").write_text("[]")
            with self.assertRaisesRegex(ValueError, "integrity mismatch"):
                verify_package(output)
            manifest = json.loads((output / "package.json").read_text())
            manifest["files"][0]["path"] = "../outside.json"
            write_json(output / "package.json", manifest)
            with self.assertRaisesRegex(ValueError, "escapes"):
                verify_package(output)

    def test_exact_count_failure_does_not_publish_or_replace_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            root = directory / "source"
            self.dataset(root)
            output = directory / "snapshot"
            with self.assertRaisesRegex(ValueError, "Expected 4 offers"):
                build_package(root, output, as_of="2026-10-18", expected_offers=4)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_suffix(".zip").exists())
            output.mkdir()
            (output / "keep.txt").write_text("keep")
            with self.assertRaisesRegex(ValueError, "already exists"):
                build_package(root, output, as_of="2026-10-18")
            self.assertEqual((output / "keep.txt").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
