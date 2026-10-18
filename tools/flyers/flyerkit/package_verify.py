"""Verify an extracted flyer JSON package without the collector or SQLite.

This file is also copied into generated packages as verify.py.
"""

from __future__ import annotations

import hashlib
import json
from collections import Counter
from datetime import date
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, ValidationError


def package_path(root: Path, relative: str) -> Path:
    path = Path(relative)
    target = (root / path).resolve()
    if (
        path.is_absolute()
        or not target.is_relative_to(root.resolve())
        or target == root.resolve()
    ):
        raise ValueError("Package path escapes its directory: " + relative)
    return target


def read_jsonl(path: Path) -> list[dict]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_package(root: Path) -> dict:
    root = root.resolve()
    manifest = json.loads((root / "package.json").read_text(encoding="utf-8"))
    _require(
        manifest["package_version"] == 1 and manifest["test_only"] is True,
        "Unsupported test package",
    )
    date.fromisoformat(manifest["as_of"])
    files = {}
    for entry in manifest["files"]:
        name = entry["path"]
        _require(
            name not in files and name != "package.json",
            "Duplicate/self-referencing file inventory",
        )
        path = package_path(root, name)
        data = path.read_bytes()
        _require(
            len(data) == entry["bytes"]
            and hashlib.sha256(data).hexdigest() == entry["sha256"],
            "File integrity mismatch: " + name,
        )
        files[name] = entry

    def member(name):
        _require(name in files, "Unlisted package member: " + name)
        return package_path(root, name)

    layout = manifest["layout"]
    schema = json.loads(member("schemas/offer.schema.json").read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    retailers = json.loads(member(layout["retailers"]).read_text(encoding="utf-8"))
    retailer_ids = {r["retailer_id"] for r in retailers}
    _require(len(retailer_ids) == len(retailers), "Duplicate retailer IDs")
    editions = json.loads(member(layout["editions"]).read_text(encoding="utf-8"))
    offers = json.loads(member(layout["offers"]).read_text(encoding="utf-8"))
    _require(
        isinstance(offers, list) and offers, "offers.json must contain a nonempty array"
    )
    by_id = {}
    for offer in offers:
        try:
            validator.validate(offer)
        except ValidationError as error:
            raise ValueError("Invalid offer schema: " + error.message) from error
        key = offer["offer_id"]
        _require(key not in by_id, "Duplicate offer ID: " + key)
        by_id[key] = offer
    seen = set()
    source_queue = []
    edition_ids = set()
    page_count = 0
    for entry in editions:
        flyer = json.loads(member(entry["manifest"]).read_text(encoding="utf-8"))
        fid = flyer["flyer_id"]
        _require(
            fid == entry["flyer_id"] and fid not in edition_ids,
            "Duplicate/mismatched edition ID",
        )
        edition_ids.add(fid)
        _require(flyer["retailer_id"] in retailer_ids, "Unknown retailer")
        pages = {p["page_number"]: p for p in flyer["pages"]}
        _require(len(pages) == len(flyer["pages"]), "Duplicate source page numbers")
        page_count += len(pages)
        rows = read_jsonl(member(entry["offers"]))
        _require(len(rows) == entry["offer_count"], "Edition offer count mismatch")
        if (
            flyer["geography"]["scope"] == "unknown"
            or not flyer.get("valid_from")
            or not flyer.get("valid_to")
        ):
            source_queue.append(flyer)
        for offer in rows:
            key = offer["offer_id"]
            _require(
                key not in seen and by_id.get(key) == offer,
                "Edition/aggregate offer mismatch: " + key,
            )
            seen.add(key)
            _require(
                offer["flyer_id"] == fid
                and offer["retailer_id"] == flyer["retailer_id"],
                "Offer edition/retailer mismatch",
            )
            evidence = offer["evidence"]
            page = pages.get(evidence["page_number"])
            _require(
                page is not None and page["sha256"] == evidence["image_sha256"],
                "Offer source image mismatch",
            )
            _require(
                page["source_image_url"] == evidence["source_image_url"],
                "Offer source URL mismatch",
            )
            _require(
                offer["geography"] == flyer["geography"]
                and offer["flyer_valid_from"] == flyer["valid_from"]
                and offer["flyer_valid_to"] == flyer["valid_to"],
                "Offer applicability differs from source",
            )
            context = [
                fid,
                evidence["image_sha256"],
                str(flyer["valid_from"]),
                str(flyer["valid_to"]),
                json.dumps(flyer["geography"], sort_keys=True, ensure_ascii=False),
            ]
            _require(
                offer["source_context_hash"]
                == hashlib.sha256("\x1f".join(context).encode()).hexdigest()[:24],
                "Stale source context",
            )
            x, y, w, h = evidence["price_bbox_px"]
            _require(
                w > 0 and h > 0 and x + w <= page["width"] and y + h <= page["height"],
                "Price box outside source image",
            )
            if offer["review"]["status"] == "validated":
                _require(
                    bool(offer["review"].get("reviewer"))
                    and flyer["geography"]["scope"] != "unknown",
                    "Validated offer lacks checked applicability/reviewer",
                )
                _require(
                    bool(flyer["valid_from"])
                    and bool(flyer["valid_to"])
                    and flyer["valid_from"]
                    <= offer["valid_from"]
                    <= offer["valid_to"]
                    <= flyer["valid_to"],
                    "Validated dates outside flyer",
                )
        for history in ("offer_reviews", "source_reviews"):
            read_jsonl(member(entry[history]))
    _require(seen == set(by_id), "Offers missing from edition partitions")
    expected_queues = {
        "review_queue": [o for o in offers if o["review"]["status"] == "needs_review"],
        "validated_deals": [
            o
            for o in offers
            if o["review"]["status"] == "validated"
            and o["price"]["kind"] in ("sale", "multibuy")
        ],
    }
    for name, expected in expected_queues.items():
        _require(
            read_jsonl(member(layout[name])) == expected,
            "Incorrect filtered export: " + name,
        )
    actual_sources = read_jsonl(member(layout["source_review_queue"]))
    _require(actual_sources == source_queue, "Incorrect source review queue")
    statuses = Counter(o["review"]["status"] for o in offers)
    counts = {
        "offers": len(offers),
        "editions": len(editions),
        "pages": page_count,
        "retailers": len(retailers),
        "needs_review": statuses["needs_review"],
        "validated_deals": len(expected_queues["validated_deals"]),
        "rejected": statuses["rejected"],
        "sources_needing_review": len(source_queue),
    }
    _require(manifest["counts"] == counts, "Package totals mismatch")
    _require(
        json.loads(member(layout["summary"]).read_text(encoding="utf-8"))["counts"]
        == counts,
        "Summary totals mismatch",
    )
    return {
        "status": "pass",
        "package_id": manifest["package_id"],
        **counts,
        "checked_files": len(files),
        "images_included": False,
    }


if __name__ == "__main__":
    import sys

    try:
        print(
            json.dumps(
                verify_package(
                    Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent
                ),
                indent=2,
            )
        )
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"status": "fail", "error": str(error)}), file=sys.stderr)
        raise SystemExit(1)
