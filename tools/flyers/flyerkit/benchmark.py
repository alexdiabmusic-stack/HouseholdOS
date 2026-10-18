"""Targeted, image-hash-bound evaluation against independently read labels."""

from __future__ import annotations

import json
from pathlib import Path

from .download import now, write_json
from .offers import product_tokens
from .pipeline import load_offers


def benchmark(root: Path, labels: Path, offers_path=None):
    offers = (
        [
            json.loads(line)
            for line in offers_path.read_text().splitlines()
            if line.strip()
        ]
        if offers_path
        else load_offers(root)
    )
    targets = [
        json.loads(line) for line in labels.read_text().splitlines() if line.strip()
    ]
    if not targets:
        raise ValueError("Benchmark labels are empty")
    results = []
    counts = {}
    known_images = {o["evidence"]["image_sha256"] for o in offers}
    for label in targets:
        x, y, w, h = label["price_region_normalized"]
        if min(x, y, w, h) < 0 or w <= 0 or h <= 0 or x + w > 1 or y + h > 1:
            raise ValueError("Invalid labelled price region")
        candidates = []
        for offer in offers:
            if offer["evidence"]["image_sha256"] != label["image_sha256"]:
                continue
            xx, yy, ww, hh = offer["evidence"]["price_bbox_normalized"]
            cx, cy = xx + ww / 2, yy + hh / 2
            if x <= cx <= x + w and y <= cy <= y + h:
                candidates.append(offer)
        expected = label["expected"]

        def fields(offer):
            matches = {
                k: offer["price"].get(k) == v
                for k, v in expected.items()
                if k != "product_tokens"
            }
            if "product_tokens" in expected:
                matches["product_tokens"] = set(
                    product_tokens(" ".join(expected["product_tokens"]))
                ).issubset(set(offer["product"]["canonical_tokens"]))
            return matches

        best = max(candidates, key=lambda o: sum(fields(o).values()), default=None)
        matched = fields(best) if best else {k: False for k in expected}
        for field, correct in matched.items():
            row = counts.setdefault(field, {"correct": 0, "total": 0})
            row["total"] += 1
            row["correct"] += int(correct)
        results.append(
            {
                "label_id": label["label_id"],
                "offer_id": best["offer_id"] if best else None,
                "matches": matched,
                "expected": expected,
                "observed": {
                    "price": best["price"],
                    "product": best["product"]["name"],
                    "review_status": best["review"]["status"],
                }
                if best
                else None,
            }
        )
    for row in counts.values():
        row["rate"] = round(row["correct"] / row["total"], 4)
    missing = sorted({l["image_sha256"] for l in targets} - known_images)
    report = {
        "generated_at": now(),
        "status": "partial" if missing else "complete",
        "labels": len(targets),
        "images": len({l["image_sha256"] for l in targets}),
        "all_fields_correct": sum(all(r["matches"].values()) for r in results),
        "fields": counts,
        "missing_images": missing,
        "reviewed_records_in_population": sum(
            o["review"]["status"] != "needs_review" for o in offers
        ),
        "results": results,
        "interpretation": "Targeted labelled regions measure detection and field correctness on these images only. Unlabelled regions are not negatives; this is not whole-catalog precision or recall. Run against a saved pre-review export to measure raw OCR.",
    }
    write_json(root / "benchmark-report.json", report)
    return report
