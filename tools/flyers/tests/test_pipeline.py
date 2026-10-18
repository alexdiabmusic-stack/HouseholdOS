"""All inputs are synthetic fixtures, not downloaded SmartCanucks content."""

import hashlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from PIL import Image, ImageDraw, ImageFont
from flyerkit.download import (
    Client,
    DownloadError,
    NetworkPolicyBlocked,
    download_flyers,
    write_json,
)
from flyerkit.offers import (
    extract_offers,
    match_offer,
    parse_price,
    parse_size,
    unit_price,
    source_context_hash,
)
from flyerkit.pipeline import (
    apply_reviews,
    export,
    extract,
    load_offers,
    database,
    save_offer,
)
from flyerkit.source import (
    BASE_URL,
    discover_links,
    geography,
    parse_dates,
    parse_flyer,
    retailer,
)

URL = BASE_URL + "sobeys-on-flyer-october-11-to-18-2026"
HOME = f'<a href="{URL}">Sobeys (ON) Flyer October 11 to 18, 2026</a><a href="/sobeys-flyer">Sobeys Flyer</a><a href="https://evil.invalid/sobeys-flyer">Sobeys Flyer</a>'
DETAIL = """<html><h1>Sobeys (ON) Flyer October 11 to 18, 2026</h1><main>
<div class="flyer-pages"><img data-src="/uploads/pages/one.jpg"><img srcset="/uploads/pages/two-small.jpg 400w, /uploads/pages/two.jpg 1200w"></div>
<aside class="related-flyers"><img src="/uploads/pages/unrelated.jpg"></aside></main></html>"""


def word(text, x, y, w=110, h=30, line="1", confidence=95):
    return {
        "text": text,
        "x": x,
        "y": y,
        "w": w,
        "h": h,
        "line_id": line,
        "confidence": confidence,
    }


def flyer_page():
    flyer = parse_flyer(DETAIL, URL)
    flyer["retrieved_at"] = "2026-10-18T00:00:00+00:00"
    page = {
        "width": 1200,
        "height": 1200,
        "page_number": 1,
        "path": "regions/ON/sobeys/test/page-001.png",
        "source_image_url": "https://example.invalid/SYNTHETIC.png",
        "sha256": "fixturehash",
    }
    return flyer, page


def proposal():
    flyer, page = flyer_page()
    words = [
        word("Strawberries", 110, 120, 200, line="name"),
        word("400g", 110, 170, line="size"),
        word("$2.99", 110, 230, 150, 60, line="price"),
    ]
    return extract_offers(words, flyer, page, "fixture")[0]


def reviewed_fields(offer=None):
    return {
        "size_text": "400g",
        "purchase_quantity": 1,
        "basis": "each",
        "kind": "sale",
        "requires_membership": False,
        "conditions": [],
        "offer_valid_from": "2026-10-11",
        "offer_valid_to": "2026-10-18",
        "source_context_hash": source_context_hash(offer or proposal()),
    }


def seed_image(root, offer):
    path = root / offer["evidence"]["image_path"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"SYNTHETIC image evidence bytes")
    offer["evidence"]["image_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    f, p = flyer_page()
    p["sha256"] = offer["evidence"]["image_sha256"]
    f["pages"] = [p]
    write_json(path.parent / "manifest.json", f)


class SourceTests(unittest.TestCase):
    def test_english_french_and_year_rollover(self):
        for raw, expected in [
            ("October 11-18, 2026", ("2026-10-11", "2026-10-18")),
            ("11 au 18 octobre 2026", ("2026-10-11", "2026-10-18")),
            ("December 26 to January 1 2027", ("2026-12-26", "2027-01-01")),
            ("Dec 26 2026 - Jan 1 2027", ("2026-12-26", "2027-01-01")),
            ("2026-10-11 to 2026-10-18", ("2026-10-11", "2026-10-18")),
        ]:
            with self.subTest(raw=raw):
                self.assertEqual(parse_dates(raw), expected)

    def test_invalid_or_missing_validity_never_becomes_today(self):
        for raw in [
            "October 11 to 18",
            "February 30 to March 5 2026",
            "October 18 to 11 2026",
            "October 2026",
            "October 11 2026",
        ]:
            with self.subTest(raw=raw):
                self.assertEqual(parse_dates(raw), (None, None))

    def test_banner_and_geography_are_distinct(self):
        self.assertEqual(retailer("Atlantic Superstore (NS)"), "atlantic-superstore")
        self.assertEqual(
            geography("Atlantic Superstore (NS) Flyer")["provinces"], ["NS"]
        )
        self.assertEqual(geography("Sobeys (ON) Flyer")["cities"], [])
        self.assertEqual(geography("Sobeys Ottawa Flyer")["provinces"], ["ON"])
        self.assertEqual(geography("No Frills on sale")["scope"], "unknown")

    def test_discovery_stays_on_source_and_retains_indexes(self):
        links = discover_links(HOME, BASE_URL, {"sobeys"})
        self.assertEqual({x["kind"] for x in links}, {"flyer", "index"})
        self.assertEqual(len(links), 2)

    def test_full_resolution_pages_exclude_related_flyers(self):
        f = parse_flyer(DETAIL, URL)
        self.assertEqual(
            f["image_urls"],
            [BASE_URL + "uploads/pages/one.jpg", BASE_URL + "uploads/pages/two.jpg"],
        )
        self.assertEqual(f["valid_to"], "2026-10-18")
        self.assertEqual(f["warnings"], [])

    def test_json_ld_does_not_combine_dates_from_different_events(self):
        html = '<h1>Sobeys (ON) Flyer</h1><script type="application/ld+json">[{"startDate":"2026-10-11"},{"endDate":"2026-10-18"}]</script>'
        self.assertIsNone(
            parse_flyer(html, URL.replace("october-11-to-18-2026", "unknown"))[
                "valid_from"
            ]
        )


class PriceTests(unittest.TestCase):
    def test_decimal_cents_and_french_decimal(self):
        self.assertEqual(parse_price("$2.99")["amount_cents"], 299)
        self.assertEqual(parse_price("2,99 $")["amount_cents"], 299)
        self.assertEqual(parse_price("99¢/lb")["amount_cents"], 99)
        self.assertIsNone(parse_price("400g"))
        self.assertIsNone(parse_price("$2.999"))
        self.assertIsNone(parse_price("12345.99"))

    def test_multibuy_preserves_basket_amount_and_quantity(self):
        p = parse_price("2 for $5.00")
        self.assertEqual(
            (p["amount_cents"], p["purchase_quantity"], p["kind"]), (500, 2, "multibuy")
        )
        self.assertIn("multibuy_single_unit_price_unknown", p["flags"])

    def test_regular_savings_and_member_qualification(self):
        self.assertEqual(parse_price("Save $2.00")["kind"], "savings")
        self.assertEqual(parse_price("Reg $4.99")["kind"], "regular")
        self.assertTrue(parse_price("member price $2.99")["requires_membership"])

    def test_size_range_is_not_an_exact_package(self):
        self.assertTrue(parse_size("350-400 g")["ambiguous"])
        self.assertEqual(parse_size("350-400 g")["raw"], "350-400 g")
        self.assertEqual(parse_size("4 x 95/100g")["raw"], "4 x 95/100g")
        self.assertTrue(parse_size("350 or 400 g")["ambiguous"])
        self.assertIsNone(parse_size("350-400 g")["total_base_quantity"])
        self.assertEqual(parse_size("2 x 400g")["total_base_quantity"], "800")

    def test_unit_comparison_handles_packs_and_weight_basis(self):
        self.assertEqual(
            unit_price(parse_price("$2.99"), parse_size("400g")),
            {"amount_cents_decimal": "747.5000", "per": "kg"},
        )
        self.assertEqual(
            unit_price(parse_price("2 for $5"), parse_size("500g"))[
                "amount_cents_decimal"
            ],
            "500.0000",
        )
        self.assertEqual(
            unit_price(parse_price("99¢/lb"), parse_size(""))["amount_cents_decimal"],
            "218.2576",
        )

    def test_price_span_does_not_swallow_product_words(self):
        f, p = flyer_page()
        words = [
            word("$2.99", 100, 220, line="same"),
            word("Strawberries", 220, 220, 200, line="same"),
            word("400g", 220, 265, line="size"),
        ]
        offer = extract_offers(words, f, p, "fixture")[0]
        self.assertIn("Strawberries", offer["product"]["name"])
        self.assertEqual(offer["price"]["raw"], "$2.99")

    def test_raised_cents_are_not_a_separate_99_cent_deal(self):
        f, p = flyer_page()
        words = [
            word("Strawberries", 100, 120, 200, line="name"),
            word("2", 100, 220, 50, 90, "dollar"),
            word("99¢", 155, 220, 50, 35, "cents"),
        ]
        offers = extract_offers(words, f, p, "fixture")
        self.assertEqual(len(offers), 1)
        self.assertEqual(offers[0]["price"]["amount_cents"], 299)
        self.assertIn("split_price_reconstructed", offers[0]["review"]["reasons"])

    def test_opposite_product_tiles_remain_separate(self):
        f, p = flyer_page()
        words = [
            word("Strawberries", 60, 120, 200, line="a"),
            word("$2.99", 60, 220, 120, 60, "pa"),
            word("Chicken", 850, 120, 170, line="b"),
            word("$4.99", 850, 220, 120, 60, "pb"),
        ]
        offers = extract_offers(words, f, p, "fixture")
        self.assertEqual(len(offers), 2)
        self.assertNotIn("Chicken", offers[0]["product"]["name"])
        self.assertNotIn("Strawberries", offers[1]["product"]["name"])


class MatchReviewTests(unittest.TestCase):
    def test_unreviewed_expired_other_region_and_wrong_size_excluded(self):
        o = proposal()

        def match(q="strawberries", **kwargs):
            return match_offer(
                o,
                q,
                on=kwargs.pop("on", "2026-10-18"),
                province=kwargs.pop("province", "ON"),
                city="Ottawa",
                **kwargs,
            )

        self.assertIsNone(match())
        o["review"]["status"] = "validated"
        self.assertIsNotNone(match("fraises 400g"))
        self.assertIsNone(match("strawberries 500g"))
        self.assertIsNone(match(on="2026-10-19"))
        self.assertIsNone(match(province="QC"))
        self.assertIsNone(match("organic strawberries"))
        self.assertEqual(match()["match"]["location_basis"], "province_wide")

    def test_city_specific_flyer_is_not_available_everywhere_in_province(self):
        o = proposal()
        o["review"]["status"] = "validated"
        o["geography"] = geography("Sobeys Ottawa Flyer")
        self.assertIsNone(
            match_offer(
                o, "strawberries", on="2026-10-18", province="ON", city="Toronto"
            )
        )

    def test_savings_never_matches_as_sale_even_when_reviewed(self):
        o = proposal()
        o["review"]["status"] = "validated"
        o["price"]["kind"] = "savings"
        self.assertIsNone(
            match_offer(o, "strawberries", on="2026-10-18", province="ON")
        )

    def test_review_requires_hash_explicit_checked_price_and_reviewer(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            o = proposal()
            seed_image(root, o)
            with database(root) as db:
                save_offer(db, o)
            path = root / "decisions.jsonl"
            d = {
                "offer_id": o["offer_id"],
                "status": "validated",
                "reviewer": "test-fixture",
                "product_name": "Strawberries",
                "amount_cents": 299,
            }
            path.write_text(json.dumps(d))
            with self.assertRaises(ValueError):
                apply_reviews(root, path)
            d["image_sha256"] = o["evidence"]["image_sha256"]
            d.update(reviewed_fields(o))
            path.write_text(json.dumps(d))
            self.assertEqual(apply_reviews(root, path)["validated_deals"], 1)
            rows = load_offers(root)
            self.assertEqual(rows[0]["product"]["name"], "Strawberries")
            self.assertTrue((root / "review-audit.jsonl").exists())
            self.assertEqual(export(root)["offers"], 1)

    def test_restricted_day_offer_requires_checked_subrange(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            o = proposal()
            seed_image(root, o)
            o["review"]["reasons"].append("restricted_validity_unresolved")
            with database(root) as db:
                save_offer(db, o)
            path = root / "decisions.jsonl"
            d = {
                "offer_id": o["offer_id"],
                "image_sha256": o["evidence"]["image_sha256"],
                "status": "validated",
                "reviewer": "fixture",
                "product_name": "Strawberries",
                "amount_cents": 299,
            }
            path.write_text(json.dumps(d))
            with self.assertRaises(ValueError):
                apply_reviews(root, path)
            d.update(reviewed_fields(o))
            d.update(offer_valid_from="2026-10-17", offer_valid_to="2026-10-18")
            path.write_text(json.dumps(d))
            apply_reviews(root, path)
            checked = load_offers(root)[0]
            self.assertIsNone(
                match_offer(checked, "strawberries", on="2026-10-16", province="ON")
            )
            self.assertIsNotNone(
                match_offer(checked, "strawberries", on="2026-10-18", province="ON")
            )


class DownloadTests(unittest.TestCase):
    def test_policy_block_is_reported_without_fabricating_data(self):
        with (
            tempfile.TemporaryDirectory() as temp,
            patch.object(
                Client, "_request", side_effect=NetworkPolicyBlocked("blocked")
            ),
        ):
            r = download_flyers(
                Path(temp), stores={"sobeys"}, as_of=date(2026, 10, 18), provinces=set()
            )
            self.assertEqual(
                (r["status"], r["image_count"], r["flyer_count"]), ("blocked", 0, 0)
            )
            self.assertEqual(list(Path(temp).rglob("manifest.json")), [])

    def test_unknown_image_host_is_not_fetched(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(DownloadError):
                Client(Path(temp)).get("https://private.invalid/page.jpg", image=True)

    def test_robots_disallow_is_honored(self):
        with (
            tempfile.TemporaryDirectory() as temp,
            patch.object(
                Client, "_request", return_value=(b"User-agent: *\nDisallow: /\n", {})
            ) as request,
        ):
            with self.assertRaises(DownloadError):
                Client(Path(temp)).get(BASE_URL)
            self.assertEqual(request.call_count, 1)

    def test_download_cache_resume_and_manifest_provenance(self):
        image = Image.new("RGB", (800, 1000), "white")
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG")
        requests = []

        def fake_request(client, url, limit):
            requests.append(url)
            if url.endswith("robots.txt"):
                content = b"User-agent: *\nAllow: /\n"
            elif url == BASE_URL:
                content = HOME.encode()
            elif url.endswith("/sobeys-flyer"):
                content = HOME.encode()
            elif url == URL:
                content = DETAIL.encode()
            elif url.endswith(".jpg"):
                content = buffer.getvalue()
            else:
                self.fail(url)
            return content, {
                "retrieved_at": "2026-10-18T00:00:00+00:00",
                "content_type": "fixture",
            }

        with (
            tempfile.TemporaryDirectory() as temp,
            patch.object(Client, "_request", fake_request),
        ):
            root = Path(temp)
            r = download_flyers(
                root, stores={"sobeys"}, as_of=date(2026, 10, 18), provinces=set()
            )
            self.assertEqual((r["status"], r["image_count"]), ("complete", 2))
            m = json.loads((root / r["flyers"][0]["manifest"]).read_text())
            self.assertEqual(m["geography"]["provinces"], ["ON"])
            self.assertEqual(
                m["pages"][0]["sha256"], hashlib.sha256(buffer.getvalue()).hexdigest()
            )
            count = len(requests)
            again = download_flyers(
                root, stores={"sobeys"}, as_of=date(2026, 10, 18), provinces=set()
            )
            self.assertEqual(again["image_count"], 2)
            self.assertEqual(
                len(requests) - count, 1
            )  # Only robots is refreshed; cached content is reused.


@unittest.skipUnless(shutil.which("tesseract"), "Tesseract not installed")
class RealOCRTests(unittest.TestCase):
    def _exercise(self, label, languages):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            f, p = flyer_page()
            image = Image.new("RGB", (1200, 1200), "white")
            draw = ImageDraw.Draw(image)
            font = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 42
            )
            big = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 68
            )
            draw.text((80, 20), "SYNTHETIC TEST FIXTURE", fill="black", font=font)
            draw.text((100, 300), label, fill="black", font=font)
            draw.text((100, 355), "400g", fill="black", font=font)
            draw.text((100, 430), "$2.99", fill="black", font=big)
            path = root / p["path"]
            path.parent.mkdir(parents=True)
            image.save(path)
            p["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            f["pages"] = [p]
            write_json(path.parent / "manifest.json", f)
            report = extract(root, languages=languages, workers=1)
            self.assertEqual(report["status"], "complete")
            offers = load_offers(root)
            self.assertEqual(len(offers), 1)
            self.assertEqual(offers[0]["price"]["amount_cents"], 299)
            self.assertIn("strawberries", offers[0]["product"]["canonical_tokens"])
            self.assertEqual(export(root)["validated_deals"], 0)
            self.assertIsNotNone(
                match_offer(
                    offers[0],
                    "strawberries",
                    on="2026-10-18",
                    province="ON",
                    include_unreviewed=True,
                )
            )
            decision = {
                "offer_id": offers[0]["offer_id"],
                "image_sha256": p["sha256"],
                "status": "validated",
                "reviewer": "synthetic-test",
                "product_name": label,
                "amount_cents": 299,
                "size_text": "400g",
            }
            decision.update(reviewed_fields(offers[0]))
            decisions = root / "decisions.jsonl"
            decisions.write_text(json.dumps(decision))
            apply_reviews(root, decisions)
            self.assertTrue(
                extract(root, languages=languages, workers=1)["pages"][0]["cache_hit"]
            )
            checked = load_offers(root)[0]
            self.assertEqual(checked["review"]["status"], "validated")
            self.assertIsNotNone(
                match_offer(
                    checked, "strawberries 400g", on="2026-10-18", province="ON"
                )
            )
            f["geography"] = geography("Sobeys (QC) Flyer")
            write_json(path.parent / "manifest.json", f)
            changed = extract(root, languages=languages, workers=1)
            self.assertEqual(
                changed["invalidated_reviews_after_metadata_change"],
                [checked["offer_id"]],
            )
            self.assertEqual(load_offers(root)[0]["review"]["status"], "needs_review")

    def test_real_tesseract_to_database_export_and_reviewed_match(self):
        self._exercise("Strawberries", "eng")

    def test_french_ocr_alias_and_reviewed_match(self):
        available = subprocess.run(
            ["tesseract", "--list-langs"], capture_output=True, text=True, check=True
        ).stdout.splitlines()
        if "fra" not in available:
            self.skipTest("French OCR data not installed")
        self._exercise("Fraises", "eng+fra")


if __name__ == "__main__":
    unittest.main()
