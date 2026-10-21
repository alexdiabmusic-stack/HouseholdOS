"""Source metadata decisions bound to the actual image a reviewer inspected."""

from __future__ import annotations

import hashlib
import json
from datetime import date
from pathlib import Path

from .download import now, write_json
from .source import PROVINCES


def checked_image(root: Path, page: dict) -> Path:
    path = (root / page["path"]).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError("Image path is outside the dataset")
    if (
        not path.is_file()
        or hashlib.sha256(path.read_bytes()).hexdigest() != page["sha256"]
    ):
        raise ValueError(
            "The original image is missing or its SHA256 changed: " + page["path"]
        )
    return path


def apply_source_override(root: Path, flyer: dict) -> dict:
    path = root / "source-reviews.json"
    if not path.exists():
        return flyer
    item = json.loads(path.read_text()).get(flyer["flyer_id"])
    if not item:
        return flyer
    page = next(
        (p for p in flyer["pages"] if p["sha256"] == item["image_sha256"]), None
    )
    if not page:
        return flyer
    checked_image(root, page)
    flyer["geography"] = item["geography"]
    flyer["valid_from"], flyer["valid_to"] = item["valid_from"], item["valid_to"]
    if item.get("retailer_name"):
        flyer["retailer_name"] = item["retailer_name"]
    flyer["source_review"] = {
        k: item[k] for k in ("reviewer", "reviewed_at", "image_sha256", "notes")
    }
    flyer["source_review"]["status"] = item.get("status", "validated")
    flyer["source_review"]["unresolved_fields"] = item.get("unresolved_fields", [])
    flyer["warnings"] = [
        w
        for w in flyer["warnings"]
        if w != "validity_dates_unresolved"
        and not (w == "region_unresolved" and item["geography"]["scope"] != "unknown")
    ]
    return flyer


def apply_source_reviews(root: Path, decisions: Path) -> dict:
    from .pipeline import manifest_paths

    manifests = {}
    for path in manifest_paths(root):
        flyer = json.loads(path.read_text())
        manifests[flyer["flyer_id"]] = (path, flyer)
    review_path = root / "source-reviews.json"
    known = json.loads(review_path.read_text()) if review_path.exists() else {}
    pending = []
    seen = set()
    for line in decisions.read_text().splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        key = item["flyer_id"]
        if key in seen:
            raise ValueError("Duplicate source decision: " + key)
        seen.add(key)
        if key not in manifests:
            raise ValueError("Unknown flyer_id: " + key)
        path, flyer = manifests[key]
        if not item.get("reviewer") or not item.get("notes"):
            raise ValueError(
                "Source reviews require reviewer and notes quoting the regional/date evidence"
            )
        if item.get("status", "validated") not in ("validated", "needs_review"):
            raise ValueError("Source review status must be validated or needs_review")
        if item.get("status", "validated") == "validated" and item.get(
            "unresolved_fields"
        ):
            raise ValueError("A validated source cannot have unresolved fields")
        page = next(
            (p for p in flyer["pages"] if p["sha256"] == item.get("image_sha256")), None
        )
        if not page:
            raise ValueError("Source review must name an exact source image SHA256")
        checked_image(root, page)
        a, b = (
            date.fromisoformat(item["valid_from"]),
            date.fromisoformat(item["valid_to"]),
        )
        if not 0 <= (b - a).days <= 90:
            raise ValueError("Invalid source validity period")
        geo = item["geography"]
        provinces, cities = geo.get("provinces"), geo.get("cities")
        if (
            geo.get("country") != "CA"
            or not isinstance(provinces, list)
            or any(p not in PROVINCES for p in provinces)
            or not isinstance(cities, list)
            or any(not isinstance(c, str) or not c.strip() for c in cities)
        ):
            raise ValueError(
                "Source geography must contain CA, valid province codes and explicit city names"
            )
        scope = geo.get("scope")
        if (
            scope not in ("city", "province", "national", "regional", "unknown")
            or (scope == "unknown" and item.get("status") != "needs_review")
            or (scope == "city" and (not cities or not provinces))
            or (scope == "province" and not provinces)
            or (scope == "regional" and not geo.get("published_region"))
            or not geo.get("evidence")
        ):
            raise ValueError(
                "Source scope must be supported by explicit geography evidence"
            )
        if not isinstance(geo.get("excluded_cities", []), list) or any(
            not isinstance(c, str) for c in geo.get("excluded_cities", [])
        ):
            raise ValueError("excluded_cities must be a list of names")
        for field in ("included_stores", "excluded_stores"):
            if not isinstance(geo.get(field, []), list) or any(
                not isinstance(s, str) or not s.strip() for s in geo.get(field, [])
            ):
                raise ValueError(field + " must be a list of published store addresses")
        if "retailer_name" in item and (
            not isinstance(item["retailer_name"], str)
            or not item["retailer_name"].strip()
            or len(item["retailer_name"]) > 200
        ):
            raise ValueError("retailer_name must be an explicitly checked display name")
        item = {**item, "reviewed_at": now()}
        pending.append((key, path, flyer, item))
    for key, path, flyer, item in pending:
        known[key] = item
    write_json(review_path, known)
    for key, path, flyer, item in pending:
        write_json(path, apply_source_override(root, flyer))
    # Changing a source's dates/region invalidates earlier offer validation.
    from .pipeline import database, load_offers, save_offer, export

    by_id = {key: json.loads(path.read_text()) for key, path, _, _ in pending}
    with database(root) as db:
        for offer in load_offers(root):
            if offer["flyer_id"] not in by_id:
                continue
            flyer = by_id[offer["flyer_id"]]
            same = (
                offer["geography"] == flyer["geography"]
                and offer["flyer_valid_from"] == flyer["valid_from"]
                and offer["flyer_valid_to"] == flyer["valid_to"]
                and offer["retailer_name"] == flyer["retailer_name"]
                and flyer.get("source_review", {}).get("status") != "needs_review"
            )
            if not same:
                offer.update(
                    geography=flyer["geography"],
                    valid_from=flyer["valid_from"],
                    valid_to=flyer["valid_to"],
                    flyer_valid_from=flyer["valid_from"],
                    flyer_valid_to=flyer["valid_to"],
                    retailer_name=flyer["retailer_name"],
                )
                offer["review"].update(status="needs_review", reviewer=None)
                offer["review"]["reasons"].append("source_metadata_changed")
                save_offer(db, offer)
    with (root / "source-review-audit.jsonl").open("a") as f:
        for _, _, _, item in pending:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")
    return {"applied_sources": len(pending), **export(root)}
