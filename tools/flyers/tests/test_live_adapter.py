"""Regression cases derived from the live HTML structure and actual failures.

HTML is a minimal reproduction; these tests do not make network requests.
"""

import json
import io
import hashlib
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest.mock import patch
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from flyerkit.download import Client, download_flyers
from flyerkit.offers import parse_tsv, parse_price, match_offer
from flyerkit.offers import parse_size, unit_price
from flyerkit.source import (
    BASE_URL,
    discover_links,
    parse_flyer,
    next_index_url,
    flyer_url,
    geography,
)
from flyerkit.pipeline import (
    apply_reviews,
    database,
    save_offer,
    merge_page,
    load_offers,
    manual_proposal,
)
from flyerkit.reviews import apply_source_reviews, checked_image
from flyerkit.reviews import apply_source_override
from flyerkit.review_ui import render_review
from test_pipeline import proposal, reviewed_fields, seed_image, flyer_page
from flyerkit.download import write_json

DETAIL_URL = BASE_URL + "canada/no-frills-on-flyer-october-15-to-211"
LIVE_SHAPE = f'''<title>No Frills (ON) Flyer October 15 to 21</title>
<h1>No Frills Canada Flyers</h1><div class="info"><span><i class="icon-time"></i> Thu, Oct 15, 2026 - Wed, Oct 21, 2026</span><span>411,977 Views</span></div>
<div class="flyer-container"><h3 id="flyer-title">No Frills (ON) Flyer October 15 to 21</h3>
<a href="{DETAIL_URL}/all">All</a><div class="pagination"><a href="{DETAIL_URL}/single/23">Last ›</a></div>
<img src="/uploads/pages/303550/no-frills-on-flyer-october-15-to-211-1.jpg"></div>'''


def card(url, title, period):
    return f'<a href="{url}"><div class="flyer-card"><div class="flyer-store-inner"><h3>{title}</h3><span>{period}</span></div><a href="{url}">View Flyer</a></div></a>'


class LiveAdapterRegressionTests(unittest.TestCase):
    def test_jpg_url_containing_avif_is_preserved_with_the_correct_format(self):
        buffer = io.BytesIO()
        Image.new("RGB", (800, 1000), "white").save(buffer, format="AVIF")
        body = buffer.getvalue()
        html = '<h1>Sobeys (ON) Flyer October 11 to 18, 2026</h1><main><img src="/uploads/pages/actually-avif.jpg"></main>'

        def get(client, url, **kwargs):
            data = body if url.endswith(".jpg") else html.encode()
            return data, {
                "retrieved_at": "2026-10-18T00:00:00+00:00",
                "sha256": hashlib.sha256(data).hexdigest(),
            }

        with tempfile.TemporaryDirectory() as temp, patch.object(Client, "get", get):
            root = Path(temp)
            report = download_flyers(
                root,
                stores={"sobeys"},
                provinces=set(),
                as_of=date(2026, 10, 18),
                flyer_urls=[BASE_URL + "sobeys-on-flyer-october-11-to-18-2026"],
            )
            self.assertEqual(report["status"], "complete")
            flyer = json.loads((root / report["flyers"][0]["manifest"]).read_text())
            page = flyer["pages"][0]
            self.assertTrue(page["path"].endswith(".avif"))
            self.assertEqual((root / page["path"]).read_bytes(), body)

    def test_real_title_date_field_and_all_24_pages(self):
        f = parse_flyer(LIVE_SHAPE, DETAIL_URL)
        self.assertEqual((f["valid_from"], f["valid_to"]), ("2026-10-15", "2026-10-21"))
        self.assertEqual(f["source_title"], "No Frills (ON) Flyer October 15 to 21")
        self.assertEqual(f["geography"]["provinces"], ["ON"])
        self.assertEqual(f["expected_page_count"], 24)
        self.assertEqual(f["all_pages_url"], DETAIL_URL + "/all")
        self.assertEqual(f["warnings"], [])

    def test_nested_view_link_does_not_erase_its_card_dates(self):
        html = card(
            DETAIL_URL,
            "No Frills (ON) Flyer October 15 to 21",
            "Thu, Oct 15, 2026 - Wed, Oct 21, 2026",
        )
        links = discover_links(html, BASE_URL, {"no-frills"})
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0]["kind"], "flyer")
        self.assertEqual(links[0]["valid_to"], "2026-10-21")
        self.assertIn("(ON)", links[0]["label"])

    def test_modes_and_page_numbers_are_one_edition(self):
        for ending in ("", "/all", "/book", "/single", "/single/23", "/thumbnail"):
            self.assertEqual(flyer_url(DETAIL_URL + ending), DETAIL_URL)

    def test_non_grocery_superstores_are_not_discovered(self):
        html = '<a href="/bad-boy-superstore-canada">Bad Boy Superstore Flyer</a><a href="/pipers-superstore-canada">Pipers Superstore Flyer</a>'
        self.assertEqual(
            discover_links(html, BASE_URL, {"real-canadian-superstore"}), []
        )

    def test_retailer_name_does_not_invent_provincial_availability(self):
        self.assertEqual(geography("Real Atlantic Superstore Flyer")["provinces"], [])
        self.assertEqual(geography("Sobeys (Atlantic) Flyer")["scope"], "regional")

    def test_pagination_follows_next_offset_not_last(self):
        html = '<div class="pagination"><a href="/sobeys-canada/page/32">3</a><a href="/sobeys-canada/page/3600">Last</a><a href="/sobeys-canada/page/16">2</a></div>'
        self.assertEqual(
            next_index_url(html, BASE_URL + "sobeys-canada"),
            BASE_URL + "sobeys-canada/page/16",
        )
        self.assertEqual(
            next_index_url(html, BASE_URL + "sobeys-canada/page/16"),
            BASE_URL + "sobeys-canada/page/32",
        )

    def test_expired_weekly_does_not_hide_live_monthly_on_next_page(self):
        first = BASE_URL + "sobeys-canada"
        second = first + "/page/16"
        third = first + "/page/32"
        one = BASE_URL + "canada/sobeys-on-weekly"
        two = BASE_URL + "canada/sobeys-on-monthly"
        responses = {
            BASE_URL: f'<a href="{first}">Sobeys Flyers</a>',
            first: card(
                one, "Sobeys (ON) Flyer", "Thu, Oct 8, 2026 - Wed, Oct 14, 2026"
            )
            + f'<div class="pagination"><a href="{second}">Next</a></div>',
            second: card(
                two,
                "Sobeys (ON) Monthly Flyer",
                "Thu, Sep 24, 2026 - Wed, Oct 21, 2026",
            )
            + f'<div class="pagination"><a href="{third}">Next</a></div>',
            third: card(
                BASE_URL + "canada/sobeys-old",
                "Sobeys (ON) Old Flyer",
                "Thu, Jun 4, 2026 - Wed, Jun 10, 2026",
            ),
        }

        def get(client, url, **kwargs):
            return responses[url].encode(), {}

        with tempfile.TemporaryDirectory() as temp, patch.object(Client, "get", get):
            report = download_flyers(
                Path(temp),
                stores={"sobeys"},
                as_of=date(2026, 10, 18),
                provinces=set(),
                discover_only=True,
            )
        self.assertEqual(report["status"], "complete")
        self.assertEqual([c["url"] for c in report["candidates"]], [two])


class ExtractionRegressionTests(unittest.TestCase):
    def test_tsv_quote_is_a_word_not_a_multiline_csv_field(self):
        header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"
        rows = '5\t1\t1\t1\t1\t1\t10\t20\t30\t40\t95\t"Brand\n5\t1\t2\t1\t1\t1\t50\t60\t70\t80\t96\t$2.99\n'
        words = parse_tsv(header + rows)
        self.assertEqual([w["text"] for w in words], ['"Brand', "$2.99"])

    def test_package_sizes_never_become_prices_or_multi_buy_counts(self):
        for raw in [
            "3.45/3.85",
            "3.45/3.85 L",
            "3.85 L",
            "1.86L",
            "400g",
            "1.75/1.89L",
        ]:
            with self.subTest(raw=raw):
                self.assertIsNone(parse_price(raw))

    def test_counted_pack_is_preserved_and_never_compared_per_litre(self):
        size = parse_size("5 pack")
        self.assertEqual((size["unit"], size["total_base_quantity"]), ("count", "5"))
        self.assertIsNone(unit_price(parse_price("$2"), size))
        o = proposal()
        o["product"]["name"] = "Avocados"
        o["product"]["canonical_tokens"] = ["avocados"]
        o["product"]["size"] = size
        o["review"]["status"] = "validated"
        self.assertIsNotNone(
            match_offer(o, "avocados 5 pack", on="2026-10-18", province="ON")
        )
        self.assertIsNone(
            match_offer(o, "avocados 6 pack", on="2026-10-18", province="ON")
        )

    def test_leading_decimal_price_is_supported(self):
        self.assertEqual(parse_price("$.97/lb")["amount_cents"], 97)
        self.assertEqual(parse_price(".97")["amount_cents"], 97)

    def test_an_unconverted_requested_size_is_still_a_constraint(self):
        o = proposal()
        o["review"]["status"] = "validated"
        o["product"]["size"] = parse_size("8 fl oz")
        self.assertIsNotNone(
            match_offer(o, "strawberries 8 fl oz", on="2026-10-18", province="ON")
        )
        self.assertIsNone(
            match_offer(o, "strawberries 16 fl oz", on="2026-10-18", province="ON")
        )
        self.assertIsNotNone(
            match_offer(o, "strawberries 8floz", on="2026-10-18", province="ON")
        )

    def test_weight_priced_product_matches_requested_weight_without_inventing_a_package(
        self,
    ):
        o = proposal()
        o["review"]["status"] = "validated"
        o["price"] = parse_price("$2.99/lb")
        o["product"]["size"] = parse_size("")
        match = match_offer(o, "strawberries 1kg", on="2026-10-18", province="ON")
        self.assertIsNotNone(match)
        self.assertEqual(match["match"]["size_basis"], "weight_price")
        self.assertIsNone(
            match_offer(o, "strawberries 1L", on="2026-10-18", province="ON")
        )

    def test_unreviewed_regional_edition_cannot_be_assumed_province_wide(self):
        o = proposal()
        o["review"]["status"] = "validated"
        o["geography"] = geography("No Frills (West) Flyer")
        self.assertIsNone(
            match_offer(o, "strawberries", on="2026-10-18", province="AB")
        )
        self.assertIsNotNone(
            match_offer(
                o, "strawberries", on="2026-10-18", province="AB", region="West"
            )
        )

    def test_published_city_exclusions_are_respected(self):
        o = proposal()
        o["review"]["status"] = "validated"
        o["geography"]["excluded_cities"] = ["Dryden"]
        self.assertIsNone(
            match_offer(
                o, "strawberries", on="2026-10-18", province="ON", city="Dryden"
            )
        )

    def test_review_cannot_validate_a_tampered_image(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            o = proposal()
            seed_image(root, o)
            with database(root) as db:
                save_offer(db, o)
            (root / o["evidence"]["image_path"]).write_bytes(b"CHANGED")
            item = {
                **reviewed_fields(o),
                "offer_id": o["offer_id"],
                "image_sha256": o["evidence"]["image_sha256"],
                "status": "validated",
                "reviewer": "fixture",
                "product_name": "Strawberries",
                "amount_cents": 299,
            }
            path = root / "review.jsonl"
            path.write_text(json.dumps(item))
            with self.assertRaisesRegex(ValueError, "SHA256"):
                apply_reviews(root, path)
            self.assertEqual(load_offers(root)[0]["review"]["status"], "needs_review")

    def test_an_unchecked_field_prevents_catalog_export(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            o = proposal()
            seed_image(root, o)
            with database(root) as db:
                save_offer(db, o)
            item = {
                **reviewed_fields(o),
                "offer_id": o["offer_id"],
                "image_sha256": o["evidence"]["image_sha256"],
                "status": "validated",
                "reviewer": "fixture",
                "product_name": "Strawberries",
                "amount_cents": 299,
            }
            del item["requires_membership"]
            path = root / "review.jsonl"
            path.write_text(json.dumps(item))
            with self.assertRaisesRegex(ValueError, "requires_membership"):
                apply_reviews(root, path)

    def test_old_review_cannot_revalidate_changed_geography(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            o = proposal()
            seed_image(root, o)
            item = {
                **reviewed_fields(o),
                "offer_id": o["offer_id"],
                "image_sha256": o["evidence"]["image_sha256"],
                "status": "validated",
                "reviewer": "fixture",
                "product_name": "Strawberries",
                "amount_cents": 299,
            }
            o["geography"] = geography("Sobeys (QC) Flyer")
            with database(root) as db:
                save_offer(db, o)
            path = root / "old-review.jsonl"
            path.write_text(json.dumps(item))
            with self.assertRaisesRegex(ValueError, "geography changed"):
                apply_reviews(root, path)

    def test_review_html_does_not_execute_ocr_text(self):
        o = proposal()
        o["product"]["name"] = "</script><script>alert(1)</script>"
        html = render_review(Path("/tmp/example"), [o])
        self.assertNotIn(o["product"]["name"], html)
        self.assertIn("\\u003c/script", html)
        self.assertIn("Download decisions", html)


class SourceReviewAndRecoveryTests(unittest.TestCase):
    def dataset(self, root):
        f, p = flyer_page()
        o = proposal()
        seed_image(root, o)
        p["sha256"] = o["evidence"]["image_sha256"]
        f["pages"] = [p]
        f["expected_page_count"] = 1
        f["download_complete"] = True
        write_json((root / p["path"]).parent / "manifest.json", f)
        with database(root) as db:
            save_offer(db, o)
        return f, p, o

    def test_review_checks_current_manifest_and_requires_nonempty_dates(self):
        for case in ("manifest_changed", "empty_dates"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                f, p, o = self.dataset(root)
                item = {
                    **reviewed_fields(o),
                    "offer_id": o["offer_id"],
                    "image_sha256": p["sha256"],
                    "status": "validated",
                    "reviewer": "fixture",
                    "product_name": "Strawberries",
                    "amount_cents": 299,
                }
                if case == "manifest_changed":
                    f["geography"] = geography("Sobeys (QC) Flyer")
                    write_json((root / p["path"]).parent / "manifest.json", f)
                else:
                    item.update(offer_valid_from="", offer_valid_to="")
                path = root / "decisions.jsonl"
                path.write_text(json.dumps(item))
                with self.assertRaises(ValueError):
                    apply_reviews(root, path)
                self.assertEqual(
                    load_offers(root)[0]["review"]["status"], "needs_review"
                )

    def test_readiness_requires_complete_processing_and_current_validated_source(self):
        from flyerkit.audit import audit

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            f, p, o = self.dataset(root)
            self.assertFalse(audit(root)["ready_for_review"])
            write_json(
                root / "ocr" / "test.json",
                {
                    "image_sha256": p["sha256"],
                    "page": {"flyer_id": f["flyer_id"], "page_number": 1},
                },
            )
            write_json(
                root / "extraction-report.json", {"status": "running", "errors": []}
            )
            self.assertFalse(audit(root)["ready_for_review"])
            write_json(
                root / "extraction-report.json", {"status": "complete", "errors": []}
            )
            self.assertTrue(audit(root)["ready_for_review"])
            o["review"]["status"] = "validated"
            o["geography"] = geography("Sobeys (QC) Flyer")
            with database(root) as db:
                save_offer(db, o)
            report = audit(root)
            self.assertFalse(report["ready_for_review"])
            self.assertIn(
                "validated_offer_source_context_mismatch",
                [e.get("error") for e in report["errors"]],
            )

    def test_source_review_corrects_geography_and_invalidates_offer_review(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            f, p, o = self.dataset(root)
            o["review"]["status"] = "validated"
            with database(root) as db:
                save_offer(db, o)
            geography_qc = geography("Sobeys (QC) Flyer")
            item = {
                "flyer_id": f["flyer_id"],
                "image_sha256": p["sha256"],
                "reviewer": "fixture reviewer",
                "notes": "SYNTHETIC Quebec applicability printed on fixture",
                "valid_from": f["valid_from"],
                "valid_to": f["valid_to"],
                "geography": geography_qc,
            }
            path = root / "source-decisions.jsonl"
            path.write_text(json.dumps(item))
            result = apply_source_reviews(root, path)
            self.assertEqual(result["applied_sources"], 1)
            checked = load_offers(root)[0]
            self.assertEqual(checked["geography"]["provinces"], ["QC"])
            self.assertEqual(checked["review"]["status"], "needs_review")
            self.assertEqual(
                apply_source_override(root, f)["geography"]["provinces"], ["QC"]
            )
            f["pages"][0]["sha256"] = "different image"
            f["geography"] = geography("Sobeys (ON) Flyer")
            self.assertEqual(
                apply_source_override(root, f)["geography"]["provinces"], ["ON"]
            )

    def test_manual_missed_offer_survives_ocr_refresh_and_loses_validation_on_source_change(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            f, p, o = self.dataset(root)
            item = {
                **reviewed_fields(o),
                "entry_method": "manual",
                "flyer_id": f["flyer_id"],
                "page_number": 1,
                "price_bbox_px": [50, 70, 100, 80],
                "image_sha256": p["sha256"],
                "status": "validated",
                "reviewer": "fixture reviewer",
                "product_name": "Strawberries",
                "amount_cents": 299,
            }
            path = root / "manual.jsonl"
            path.write_text(json.dumps(item))
            apply_reviews(root, path)
            manual = [
                o
                for o in load_offers(root)
                if o["evidence"].get("entry_method") == "manual"
            ][0]
            merge_page(root, f, p, [])
            self.assertEqual(load_offers(root)[0]["offer_id"], manual["offer_id"])
            self.assertEqual(load_offers(root)[0]["review"]["status"], "validated")
            f["geography"] = geography("Sobeys (QC) Flyer")
            invalidated, _ = merge_page(root, f, p, [])
            self.assertEqual(invalidated, [manual["offer_id"]])
            self.assertEqual(load_offers(root)[0]["review"]["status"], "needs_review")

    def test_manual_entry_requires_a_box_inside_the_original_page(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            f, p, _ = self.dataset(root)
            item = {
                "flyer_id": f["flyer_id"],
                "page_number": 1,
                "image_sha256": p["sha256"],
                "price_bbox_px": [1190, 30, 30, 30],
            }
            with self.assertRaisesRegex(ValueError, "inside"):
                manual_proposal(root, item)

    def test_image_paths_cannot_escape_the_dataset(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, "outside"):
                checked_image(
                    Path(temp), {"path": "../outside.jpg", "sha256": "irrelevant"}
                )

    def test_reviewed_offer_is_preserved_when_ocr_anchors_change(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            f, p, o = self.dataset(root)
            o["review"].update(status="validated", reviewer="fixture")
            with database(root) as db:
                save_offer(db, o)
            invalidated, orphaned = merge_page(root, f, p, [])
            self.assertEqual((invalidated, orphaned), ([], []))
            self.assertEqual(load_offers(root)[0]["review"]["status"], "validated")


if __name__ == "__main__":
    unittest.main()
