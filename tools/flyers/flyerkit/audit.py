"""Dataset integrity and review readiness; never equate OCR completion with accuracy."""

from __future__ import annotations

import json
from pathlib import Path

from .download import now, write_json
from .pipeline import load_offers, manifest_paths
from .reviews import checked_image


def audit(root: Path) -> dict:
    errors = []
    warnings = []
    pages = {}
    flyers = {}
    hashes = set()
    for path in manifest_paths(root):
        flyer = json.loads(path.read_text())
        key = flyer["flyer_id"]
        if key in flyers:
            if flyer["retrieved_at"] <= flyers[key]["retrieved_at"]:
                continue
        flyers[key] = flyer
    for flyer in flyers.values():
        if not flyer.get("download_complete"):
            errors.append(
                {
                    "flyer_id": flyer["flyer_id"],
                    "error": "download_incomplete",
                    "expected": flyer.get("expected_page_count"),
                    "actual": len(flyer["pages"]),
                }
            )
        if flyer["geography"]["scope"] == "unknown":
            warnings.append(
                {"flyer_id": flyer["flyer_id"], "warning": "source_region_needs_review"}
            )
        if not flyer.get("valid_from") or not flyer.get("valid_to"):
            warnings.append(
                {"flyer_id": flyer["flyer_id"], "warning": "source_dates_need_review"}
            )
        for page in flyer["pages"]:
            key = (flyer["flyer_id"], page["page_number"])
            pages[key] = page
            try:
                if page["sha256"] not in hashes:
                    checked_image(root, page)
                    hashes.add(page["sha256"])
            except (OSError, ValueError) as error:
                errors.append({"image_path": page["path"], "error": str(error)})
    records = load_offers(root)
    extraction_pages = []
    for name in ("download-report.json", "extraction-report.json"):
        path = root / name
        if path.exists():
            stage = json.loads(path.read_text())
            if name == "extraction-report.json":
                extraction_pages = stage.get("pages", [])
            if (
                stage.get("status")
                in (
                    "running",
                    "interrupted",
                    "blocked",
                    "empty",
                )
                or stage.get("errors")
                or (
                    name == "extraction-report.json"
                    and stage.get("status") != "complete"
                )
                or stage.get("stores_without_downloads")
            ):
                errors.append(
                    {
                        "report": name,
                        "status": stage.get("status"),
                        "errors": stage.get("errors", []),
                    }
                )
    for offer in records:
        page = pages.get((offer["flyer_id"], offer["evidence"]["page_number"]))
        if not page or page["sha256"] != offer["evidence"]["image_sha256"]:
            errors.append(
                {"offer_id": offer["offer_id"], "error": "offer_source_page_mismatch"}
            )
        else:
            flyer = flyers[offer["flyer_id"]]
            if offer["review"]["status"] == "validated" and (
                offer["geography"] != flyer["geography"]
                or offer["flyer_valid_from"] != flyer["valid_from"]
                or offer["flyer_valid_to"] != flyer["valid_to"]
                or not offer["valid_from"]
                or not offer["valid_to"]
                or not flyer["valid_from"]
                <= offer["valid_from"]
                <= offer["valid_to"]
                <= flyer["valid_to"]
                or flyer["geography"]["scope"] == "unknown"
                or flyer.get("source_review", {}).get("status") == "needs_review"
                or flyer.get("source_review", {}).get("unresolved_fields")
            ):
                errors.append(
                    {
                        "offer_id": offer["offer_id"],
                        "error": "validated_offer_source_context_mismatch",
                    }
                )
            x, y, w, h = offer["evidence"]["price_bbox_px"]
            if (
                x < 0
                or y < 0
                or w <= 0
                or h <= 0
                or x + w > page["width"]
                or y + h > page["height"]
            ):
                errors.append(
                    {"offer_id": offer["offer_id"], "error": "price_box_outside_image"}
                )
    processed = set()
    for meta in (root / "ocr").glob("*.json"):
        if meta.name.endswith(".rapid.json"):
            continue
        try:
            data = json.loads(meta.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or "page" not in data:
            continue
        page = data["page"]
        key = (page["flyer_id"], page["page_number"])
        if key in pages and data.get("image_sha256") == pages[key]["sha256"]:
            processed.add(key)
    # Identical source images can appear in multiple regional editions. Raw OCR
    # is shared by hash, while the extraction report records each application.
    for entry in extraction_pages:
        key = (entry["flyer_id"], entry["page_number"])
        page = pages.get(key)
        if (
            page
            and entry.get("image_sha256") == page["sha256"]
            and entry.get("image_path") == page["path"]
        ):
            processed.add(key)
    missing = sorted(set(pages) - processed)
    if missing:
        errors.append({"error": "pages_not_processed", "count": len(missing)})
    coverage = {}
    for flyer in flyers.values():
        entry = coverage.setdefault(flyer["retailer_id"], {"flyers": 0, "pages": 0})
        entry["flyers"] += 1
        entry["pages"] += len(flyer["pages"])
    report = {
        "generated_at": now(),
        "status": "pass" if pages and records and not errors else "fail",
        "ready_for_review": bool(pages and records and not errors),
        "flyers": len(flyers),
        "pages": len(pages),
        "processed_pages": len(processed),
        "offer_proposals": len(records),
        "validated_deals": sum(
            o["review"]["status"] == "validated"
            and o["price"]["kind"] in ("sale", "multibuy")
            for o in records
        ),
        "needs_review": sum(o["review"]["status"] == "needs_review" for o in records),
        "coverage": coverage,
        "errors": errors,
        "warnings": warnings,
        "missing_ocr_pages": [{"flyer_id": f, "page_number": p} for f, p in missing],
        "interpretation": "Ready for review checks source integrity and processing coverage. A reviewer must check product, price, package, conditions and applicability before any deal is exported for matching.",
    }
    write_json(root / "readiness-report.json", report)
    return report
