"""A completed visual pass must preserve its unresolved fields and provenance."""

import copy
import json
import tempfile
import unittest
from pathlib import Path

from test_pipeline import proposal, reviewed_fields, seed_image
from flyerkit.assessments import apply_assessments
from flyerkit.offers import match_offer, parse_size, source_context_hash
from flyerkit.pipeline import (
    database,
    load_offers,
    save_offer,
    manifest_paths,
    merge_page,
    apply_reviews,
)
from flyerkit.reviews import apply_source_reviews


class AssessmentTests(unittest.TestCase):
    def seed(self, root):
        offer = proposal()
        seed_image(root, offer)
        with database(root) as db:
            save_offer(db, offer)
        return offer

    def decision(self, offer):
        fields = reviewed_fields(offer)
        fields.pop("source_context_hash")
        fields.update(product_name="Strawberries", brand=None, amount_cents=199)
        return {
            "offer_id": offer["offer_id"],
            "image_sha256": offer["evidence"]["image_sha256"],
            "source_context_hash": source_context_hash(offer),
            "status": "needs_review",
            "reviewer": "Synthetic visual reviewer",
            "method": "ai_visual",
            "source_image_inspected": True,
            "notes": "Synthetic image checked; branch applicability unclear.",
            "checked_fields": fields,
            "unresolved_fields": ["store_applicability"],
        }

    def apply(self, root, rows, **kwargs):
        path = root / "decisions.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        return apply_assessments(root, path, **kwargs)

    def test_corrected_pending_record_is_audited_and_never_matches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            report = self.apply(root, [self.decision(original)], expected_offers=1)
            offer = load_offers(root)[0]
            self.assertTrue(report["complete_offer_coverage"])
            self.assertEqual(offer["price"]["amount_cents"], 199)
            self.assertEqual(offer["review"]["status"], "needs_review")
            self.assertEqual(offer["review"]["method"], "ai_visual")
            self.assertIsNone(
                match_offer(offer, "strawberries", province="ON", on="2026-10-18")
            )
            event = json.loads((root / "review-audit.jsonl").read_text())
            self.assertEqual(event["before"]["price"]["amount_cents"], 299)

    def test_invalid_later_decision_leaves_the_whole_batch_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            good = self.decision(original)
            bad = copy.deepcopy(good)
            bad["offer_id"] = "unknown"
            with self.assertRaises(ValueError):
                self.apply(root, [good, bad])
            self.assertEqual(load_offers(root)[0]["price"]["amount_cents"], 299)
            self.assertFalse((root / "review-audit.jsonl").exists())

    def test_claiming_complete_coverage_requires_every_original_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            with self.assertRaises(ValueError):
                self.apply(root, [self.decision(original)], expected_offers=2)
            self.assertEqual(load_offers(root)[0]["price"]["amount_cents"], 299)

    def test_dates_outside_the_edition_stay_explicit_and_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            decision = self.decision(original)
            decision["checked_fields"]["offer_valid_to"] = "2026-10-31"
            decision["unresolved_fields"] = ["source_period_conflict"]
            self.apply(root, [decision])
            offer = load_offers(root)[0]
            self.assertEqual(offer["valid_to"], "2026-10-18")
            self.assertEqual(
                offer["review"]["assessment"]["unapplied_fields"]["offer_valid_to"],
                "2026-10-31",
            )
            decision["status"] = "validated"
            decision["unresolved_fields"] = []
            with self.assertRaises(ValueError):
                self.apply(root, [decision])

    def test_stale_image_or_context_cannot_be_called_reviewed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            for key in ("image_sha256", "source_context_hash"):
                decision = self.decision(original)
                decision[key] = "stale"
                with self.assertRaises(ValueError):
                    self.apply(root, [decision])

    def test_store_specific_matching_requires_the_published_store_selection(self):
        offer = proposal()
        offer["review"]["status"] = "validated"
        offer["geography"]["included_stores"] = ["123 Synthetic Street"]
        args = {"province": "ON", "on": "2026-10-18"}
        self.assertIsNone(match_offer(offer, "strawberries", **args))
        self.assertIsNone(
            match_offer(offer, "strawberries", store_address="Other store", **args)
        )
        self.assertIsNotNone(
            match_offer(
                offer, "strawberries", store_address="123 Synthetic Street", **args
            )
        )
        offer["geography"].pop("included_stores")
        offer["geography"]["excluded_stores"] = ["123 Synthetic Street"]
        self.assertIsNone(match_offer(offer, "strawberries", **args))
        self.assertIsNone(
            match_offer(
                offer, "strawberries", store_address="123 Synthetic Street", **args
            )
        )
        self.assertIsNotNone(
            match_offer(offer, "strawberries", store_address="Other store", **args)
        )

    def test_source_assessment_can_preserve_unknown_region_and_correct_banner_name(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            geo = copy.deepcopy(original["geography"])
            geo.update(
                scope="unknown",
                provinces=[],
                cities=[],
                evidence="Synthetic footer has no location.",
            )
            decision = {
                "flyer_id": original["flyer_id"],
                "image_sha256": original["evidence"]["image_sha256"],
                "reviewer": "Synthetic source reviewer",
                "notes": "Original footer checked; no region published.",
                "status": "needs_review",
                "unresolved_fields": ["geography"],
                "valid_from": "2026-10-11",
                "valid_to": "2026-10-18",
                "geography": geo,
                "retailer_name": "Checked source banner",
            }
            path = root / "source-decisions.jsonl"
            path.write_text(json.dumps(decision) + "\n")
            apply_source_reviews(root, path)
            offer = load_offers(root)[0]
            self.assertEqual(offer["geography"]["scope"], "unknown")
            self.assertEqual(offer["retailer_name"], "Checked source banner")
            self.assertEqual(offer["review"]["status"], "needs_review")
            self.assertTrue(
                (root / "exports/source-review-queue.jsonl").read_text().strip()
            )

    def test_brand_is_explicit_and_participates_in_matching(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            decision = self.decision(original)
            decision.update(status="validated", unresolved_fields=[])
            decision["checked_fields"].pop("brand")
            with self.assertRaises(ValueError):
                self.apply(root, [decision])
            decision["checked_fields"].update(
                product_name="Single Serve Coffee Cups", brand="Tim Hortons"
            )
            self.apply(root, [decision])
            self.assertIsNotNone(
                match_offer(
                    load_offers(root)[0],
                    "Tim Hortons coffee cups",
                    province="ON",
                    on="2026-10-18",
                )
            )

    def test_savings_quantity_is_a_threshold_without_a_checkout_unit_price(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            decision = self.decision(original)
            decision.update(status="validated", unresolved_fields=[])
            decision["checked_fields"].update(
                kind="savings", purchase_quantity=5, amount_cents=1000
            )
            self.apply(root, [decision])
            offer = load_offers(root)[0]
            self.assertEqual(offer["price"]["purchase_quantity"], 5)
            self.assertIsNone(offer["unit_price"])
            self.assertIsNone(
                match_offer(offer, "strawberries", province="ON", on="2026-10-18")
            )

    def test_review_report_counts_cumulative_assessments(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = self.seed(root)
            second = copy.deepcopy(first)
            second["offer_id"] = "second-synthetic-offer"
            with database(root) as db:
                save_offer(db, second)
            report = self.apply(root, [self.decision(first)])
            self.assertEqual(report["assessed_offers"], 1)
            self.assertFalse(report["complete_offer_coverage"])
            report = self.apply(root, [self.decision(second)])
            self.assertEqual(report["assessed_offers"], 2)
            self.assertEqual(report["applied_in_batch"], 1)
            self.assertTrue(report["complete_offer_coverage"])

    def test_pending_checked_corrections_survive_ocr_refresh_and_anchor_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            self.apply(root, [self.decision(original)])
            flyer = json.loads(manifest_paths(root)[0].read_text())
            page = flyer["pages"][0]
            merge_page(root, flyer, page, [copy.deepcopy(original)])
            self.assertEqual(load_offers(root)[0]["price"]["amount_cents"], 199)
            merge_page(root, flyer, page, [])
            self.assertEqual(load_offers(root)[0]["price"]["amount_cents"], 199)
            self.assertEqual(load_offers(root)[0]["review"]["status"], "needs_review")

    def test_later_review_does_not_inherit_another_reviewers_visual_assertion(self):
        for method in (None, "human_visual"):
            with self.subTest(method=method), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                original = self.seed(root)
                self.apply(root, [self.decision(original)])
                decision = {
                    "offer_id": original["offer_id"],
                    "image_sha256": original["evidence"]["image_sha256"],
                    "reviewer": "Later synthetic reviewer",
                    "status": "rejected",
                    "notes": "Synthetic later review",
                }
                if method:
                    decision.update(method=method, source_image_inspected=True)
                path = root / "later-decisions.jsonl"
                path.write_text(json.dumps(decision) + "\n")
                apply_reviews(root, path)
                reviewed = load_offers(root)[0]["review"]
                self.assertEqual(reviewed.get("method"), method)
                report = json.loads((root / "visual-review-report.json").read_text())
                self.assertEqual(report["assessed_offers"], int(method is not None))
                self.assertEqual(report["outcomes"], {"rejected": 1} if method else {})
                event = json.loads(
                    (root / "review-audit.jsonl").read_text().splitlines()[-1]
                )
                self.assertEqual(event["before"]["review"]["method"], "ai_visual")

    def test_source_status_downgrade_invalidates_validation_without_changing_geography(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = self.seed(root)
            decision = self.decision(original)
            decision.update(status="validated", unresolved_fields=[])
            self.apply(root, [decision])
            source = {
                "flyer_id": original["flyer_id"],
                "image_sha256": original["evidence"]["image_sha256"],
                "reviewer": "Synthetic source reviewer",
                "notes": "Participation unresolved in synthetic footer.",
                "status": "needs_review",
                "unresolved_fields": ["store_applicability"],
                "valid_from": "2026-10-11",
                "valid_to": "2026-10-18",
                "geography": original["geography"],
            }
            path = root / "source-decisions.jsonl"
            path.write_text(json.dumps(source) + "\n")
            apply_source_reviews(root, path)
            self.assertEqual(load_offers(root)[0]["review"]["status"], "needs_review")
            report = json.loads((root / "visual-review-report.json").read_text())
            self.assertEqual(report["outcomes"], {"needs_review": 1})
            self.assertTrue(report["complete_offer_coverage"])
            with self.assertRaises(ValueError):
                self.apply(root, [decision])

    def test_store_exclusions_cover_common_address_aliases(self):
        offer = proposal()
        offer["review"]["status"] = "validated"
        offer["geography"]["excluded_stores"] = [
            "1085 Wellington Street, Ottawa, Ontario"
        ]
        for address in (
            "1085 Wellington St, Ottawa",
            "1085 Wellington Street",
            "Sobeys 1085 Wellington St.",
        ):
            with self.subTest(address=address):
                self.assertIsNone(
                    match_offer(
                        offer,
                        "strawberries",
                        province="ON",
                        on="2026-10-18",
                        store_address=address,
                    )
                )


class ReviewedSizeTests(unittest.TestCase):
    def test_mixed_sizes_and_count_ranges_are_not_exact_variants(self):
        for text in (
            "675 g or 8 count",
            "3 lb or 5 count",
            "38-120 count",
            "16 rolls or 6 rolls",
            "up to 420 g",
        ):
            with self.subTest(text=text):
                size = parse_size(text)
                self.assertTrue(size["ambiguous"])
                self.assertEqual(size["raw"], text)
                self.assertIsNone(size["total_base_quantity"])
        self.assertEqual(parse_size("12 count")["total_base_quantity"], "12")
        self.assertEqual(parse_size("12 x 90 g")["total_base_quantity"], "1080")
        self.assertEqual(
            parse_size("12 pack; 12 x 90 g")["total_base_quantity"], "1080"
        )
        self.assertEqual(parse_size("2 pack; 430 g")["total_base_quantity"], "430")


if __name__ == "__main__":
    unittest.main()
