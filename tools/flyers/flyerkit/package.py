"""Portable, test-only JSON snapshots of the current flyer catalog."""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import tempfile
import zipfile
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

from .download import now, write_json
from .pipeline import load_offers, manifest_paths
from .package_verify import read_jsonl, verify_package
from .source import STORES


def _jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n")


def build_package(
    root: Path, output: Path, *, as_of: str, expected_offers=None
) -> dict:
    date.fromisoformat(as_of)
    root, output = root.resolve(), output.resolve()
    archive = output.with_name(output.name + ".zip")
    if output.exists() or archive.exists():
        raise ValueError(
            "Choose a new package path; an output or archive already exists"
        )
    offers = load_offers(root)
    if not offers or expected_offers is not None and len(offers) != expected_offers:
        raise ValueError(
            f"Expected {expected_offers or 'nonempty'} offers; found {len(offers)}"
        )
    flyers = sorted(
        (json.loads(p.read_text(encoding="utf-8")) for p in manifest_paths(root)),
        key=lambda f: f["flyer_id"],
    )
    by_flyer = defaultdict(list)
    by_id = {o["offer_id"]: o for o in offers}
    for offer in offers:
        by_flyer[offer["flyer_id"]].append(offer)
    offer_reviews, source_reviews = defaultdict(list), defaultdict(list)
    path = root / "review-audit.jsonl"
    if path.exists():
        for event in read_jsonl(path):
            offer = by_id.get(event["decision"]["offer_id"])
            if offer:
                offer_reviews[offer["flyer_id"]].append(event)
    path = root / "source-review-audit.jsonl"
    if path.exists():
        for event in read_jsonl(path):
            source_reviews[event["flyer_id"]].append(event)
    pending = [o for o in offers if o["review"]["status"] == "needs_review"]
    validated = [
        o
        for o in offers
        if o["review"]["status"] == "validated"
        and o["price"]["kind"] in ("sale", "multibuy")
    ]
    unresolved = [
        f
        for f in flyers
        if f["geography"]["scope"] == "unknown"
        or f.get("source_review", {}).get("status") == "needs_review"
        or not f.get("valid_from")
        or not f.get("valid_to")
    ]
    retailer_names = defaultdict(set)
    for flyer in flyers:
        retailer_names[flyer["retailer_id"]].add(flyer["retailer_name"])
    retailers = {
        key: next(iter(names))
        if len(names) == 1
        else "Co-op"
        if key == "co-op"
        else STORES.get(key, [key])[0]
        for key, names in retailer_names.items()
    }
    statuses = Counter(o["review"]["status"] for o in offers)
    counts = {
        "offers": len(offers),
        "editions": len(flyers),
        "pages": sum(len(f["pages"]) for f in flyers),
        "retailers": len(retailers),
        "needs_review": len(pending),
        "validated_deals": len(validated),
        "rejected": statuses["rejected"],
        "sources_needing_review": len(unresolved),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".flyer-package-", dir=output.parent
    ) as temp:
        staged = Path(temp) / output.name
        staged.mkdir()
        layout = {
            "retailers": "retailers.json",
            "editions": "editions/index.json",
            "offers": f"exports/{as_of}/offers.json",
            "validated_deals": f"exports/{as_of}/validated-deals.jsonl",
            "review_queue": f"exports/{as_of}/review-queue.jsonl",
            "source_review_queue": f"exports/{as_of}/source-review-queue.jsonl",
            "summary": f"exports/{as_of}/summary.json",
        }
        write_json(
            staged / layout["retailers"],
            [
                {
                    "retailer_id": key,
                    "name": retailers[key],
                    "edition_names": sorted(retailer_names[key]),
                }
                for key in sorted(retailers)
            ],
        )
        index = []
        for flyer in flyers:
            fid = flyer["flyer_id"]
            if not re.fullmatch(r"[0-9a-f]{24}", fid):
                raise ValueError("Invalid edition ID: " + fid)
            directory = f"editions/{fid}"
            entry = {
                "flyer_id": fid,
                "retailer_id": flyer["retailer_id"],
                "offer_count": len(by_flyer[fid]),
                "manifest": directory + "/manifest.json",
                "offers": directory + "/offers.jsonl",
                "offer_reviews": directory + "/reviews/offer-decisions.jsonl",
                "source_reviews": directory + "/reviews/source-decisions.jsonl",
            }
            write_json(staged / entry["manifest"], flyer)
            _jsonl(staged / entry["offers"], by_flyer[fid])
            _jsonl(staged / entry["offer_reviews"], offer_reviews[fid])
            _jsonl(staged / entry["source_reviews"], source_reviews[fid])
            index.append(entry)
        write_json(staged / layout["editions"], index)
        # Aggregate JSON is a convenience test import; edition files are the
        # canonical partitions. IDs and record contents are identical in both.
        write_json(staged / layout["offers"], offers)
        _jsonl(staged / layout["review_queue"], pending)
        _jsonl(staged / layout["validated_deals"], validated)
        _jsonl(staged / layout["source_review_queue"], unresolved)
        write_json(
            staged / layout["summary"],
            {"test_only": True, "as_of": as_of, "counts": counts},
        )
        review_report = root / "visual-review-report.json"
        if review_report.exists():
            layout["visual_review_report"] = "reviews/visual-review-report.json"
            write_json(
                staged / layout["visual_review_report"],
                json.loads(review_report.read_text(encoding="utf-8")),
            )
        schema = Path(__file__).resolve().parents[1] / "offer.schema.json"
        (staged / "schemas").mkdir()
        shutil.copyfile(schema, staged / "schemas" / "offer.schema.json")
        shutil.copyfile(
            Path(__file__).with_name("package_verify.py"), staged / "verify.py"
        )
        (staged / "requirements.txt").write_text(
            "jsonschema>=4.23,<5\n", encoding="utf-8"
        )
        (staged / "README.md").write_text(
            f"""# SmartCanucks JSON test package

Snapshot date: {as_of}. Contains {len(offers):,} original offer records across {len(flyers)} editions.
This package is for integration testing. Review states and reviewer identities are preserved.
Only {len(validated)} records qualify for the checked-deals export; {len(pending):,} remain in review.
AI visual reviews are explicitly labelled in each record. Pending records can contain checked
corrections alongside explicit unresolved fields. This is a test snapshot with review decisions,
not a certification of public-catalog accuracy or extraction completeness.

## Load all offers

```python
import json
from pathlib import Path
root = Path(".")  # extracted package directory
package = json.loads((root / "package.json").read_text(encoding="utf-8"))
offers = json.loads((root / package["layout"]["offers"]).read_text(encoding="utf-8"))
assert len(offers) == package["counts"]["offers"]
```

`retailers.json` lists banners. `editions/index.json` locates one stable-ID folder per edition,
containing the source manifest, complete offers in JSONL, and append-only review histories.
`exports/{as_of}/` contains the aggregate JSON array and filtered JSONL exports.
The aggregate and filtered exports are generated views of the same records; import one view
at a time and use `offer_id` as the idempotent key. Prices use integer CAD cents.

## Verify independently

```sh
python -m pip install -r requirements.txt
python verify.py .
```

Verification checks file hashes, JSON Schema, unique offer IDs, edition partitions, image
references, source contexts, coordinates, review-state filtering and counts. It requires no
collector checkout, SQLite database, OCR models or network requests after installation.

Original images, HTML and raw OCR caches stay in the source dataset. Images are referenced
by original URL and SHA256. `image_path`, page `path` and `directory` fields refer to that
original dataset, not to files included in this JSON-only package. Do not automatically
download media while loading test records. The included metadata fully identifies each
source page, including pages with no proposed offers.
""",
            encoding="utf-8",
        )
        files = []
        for path in sorted(staged.rglob("*")):
            if path.is_file():
                data = path.read_bytes()
                files.append(
                    {
                        "path": path.relative_to(staged).as_posix(),
                        "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                    }
                )
        write_json(
            staged / "package.json",
            {
                "package_version": 1,
                "package_id": output.name,
                "test_only": True,
                "as_of": as_of,
                "generated_at": now(),
                "counts": counts,
                "layout": layout,
                "media": {
                    "included": False,
                    "local_paths_relative_to": "original_dataset",
                    "references": ["source_image_url", "image_sha256"],
                },
                "files": files,
            },
        )
        validation = verify_package(staged)
        archive_temp = Path(temp) / (output.name + ".zip")
        with zipfile.ZipFile(
            archive_temp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
        ) as bundle:
            for path in sorted(staged.rglob("*")):
                if path.is_file():
                    bundle.write(
                        path, output.name + "/" + path.relative_to(staged).as_posix()
                    )
        staged.rename(output)
        archive_temp.rename(archive)
    return {
        "status": "complete",
        "package": str(output),
        "archive": str(archive),
        "archive_bytes": archive.stat().st_size,
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "validation": validation,
    }
