"""Offline tests for digit geometry and the bundled neural recognition path."""

import hashlib
import copy
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PIL import Image, ImageDraw, ImageFont
from flyerkit.download import write_json
from flyerkit.pipeline import extract, load_offers
from test_pipeline import flyer_page

AVAILABLE = bool(importlib.util.find_spec("rapidocr_onnxruntime"))


@unittest.skipUnless(
    AVAILABLE, "Install requirements-ocr.txt for local neural OCR tests"
)
class LocalVisionTests(unittest.TestCase):
    def test_raised_cents_are_required_before_inserting_a_decimal(self):
        import numpy as np
        from flyerkit.vision import raised_cents

        image = Image.new("RGB", (600, 300), "white")
        draw = ImageDraw.Draw(image)
        big = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 100
        )
        small = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 50
        )
        draw.text((50, 50), "2", fill="red", font=big)
        draw.text((125, 50), "99", fill="red", font=small)
        pixels = np.asarray(image)
        self.assertTrue(raised_cents(pixels, [45, 45, 160, 125], "299"))
        image = Image.new("RGB", (600, 300), "white")
        ImageDraw.Draw(image).text((50, 50), "100", fill="red", font=big)
        self.assertFalse(raised_cents(np.asarray(image), [45, 45, 230, 125], "100"))

    def test_local_hybrid_engine_to_persistent_review_queue(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            flyer, page = flyer_page()
            page["path"] = str(Path(page["path"]).with_suffix(".avif"))
            image = Image.new("RGB", (1200, 1200), "white")
            draw = ImageDraw.Draw(image)
            font = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 42
            )
            big = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 80
            )
            draw.text((100, 300), "Strawberries", fill="black", font=font)
            draw.text((100, 355), "400g", fill="black", font=font)
            draw.text((100, 430), "$2.99", fill="black", font=big)
            path = root / page["path"]
            path.parent.mkdir(parents=True)
            image.save(path)
            page["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            flyer["pages"] = [page]
            flyer["download_complete"] = True
            flyer["expected_page_count"] = 1
            write_json(path.parent / "manifest.json", flyer)
            second = copy.deepcopy(flyer)
            second["flyer_id"] = "b" * 24
            write_json(root / "regions" / "second-edition" / "manifest.json", second)
            report = extract(root, languages="eng", engine="hybrid", workers=2)
            self.assertEqual(report["status"], "complete")
            self.assertEqual(len(report["pages"]), 2)
            self.assertTrue(any(p["cache_hit"] for p in report["pages"]))
            offers = load_offers(root)
            self.assertTrue(any(o["price"]["amount_cents"] == 299 for o in offers))
            self.assertTrue(
                all(o["review"]["status"] == "needs_review" for o in offers)
            )
            self.assertEqual((root / "exports/validated-deals.jsonl").read_text(), "")
            from flyerkit.audit import audit

            readiness = audit(root)
            self.assertTrue(readiness["ready_for_review"])
            self.assertEqual(readiness["processed_pages"], 2)


if __name__ == "__main__":
    unittest.main()
