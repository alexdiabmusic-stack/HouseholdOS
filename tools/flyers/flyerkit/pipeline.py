"""OCR, review, SQLite storage and app-ready exports."""

from __future__ import annotations

import csv
import hashlib
import json
import logging
import os
import shutil
import sqlite3
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from datetime import date

from .download import now, write_json
from .offers import (
    extract_offers,
    parse_size,
    parse_tsv,
    product_tokens,
    unit_price,
    source_context_hash,
)
from .source import stable_id

LOG = logging.getLogger(__name__)
_OCR_LOCKS = {}
_OCR_LOCK_GUARD = threading.Lock()


def database(root: Path) -> sqlite3.Connection:
    root.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(root / "flyers.sqlite3")
    db.executescript("""
        CREATE TABLE IF NOT EXISTS flyers (
            flyer_id TEXT PRIMARY KEY, retailer_id TEXT NOT NULL, valid_from TEXT,
            valid_to TEXT, metadata_json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS offers (
            offer_id TEXT PRIMARY KEY, flyer_id TEXT NOT NULL, retailer_id TEXT NOT NULL,
            valid_from TEXT, valid_to TEXT, status TEXT NOT NULL, payload_json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS offers_store_dates ON offers(retailer_id, valid_from, valid_to);
        CREATE INDEX IF NOT EXISTS offers_review ON offers(status);
    """)
    return db


def load_offers(root: Path) -> list[dict]:
    with database(root) as db:
        offers = [
            json.loads(row[0])
            for row in db.execute(
                "SELECT payload_json FROM offers ORDER BY retailer_id, valid_from, offer_id"
            )
        ]
    for offer in offers:
        offer["source_context_hash"] = source_context_hash(offer)
    return offers


def manifest_paths(root: Path) -> list[Path]:
    """An edition has one active manifest even if its regional folder changed."""
    chosen = {}
    for path in (root / "regions").rglob("manifest.json"):
        flyer = json.loads(path.read_text())
        previous = chosen.get(flyer["flyer_id"])
        if previous is None or path.stat().st_mtime > previous.stat().st_mtime:
            chosen[flyer["flyer_id"]] = path
    report = root / "download-report.json"
    if report.exists():
        for entry in json.loads(report.read_text()).get("flyers", []):
            path = (root / entry["manifest"]).resolve()
            if not path.is_relative_to(root.resolve()):
                raise ValueError("Manifest path is outside the dataset")
            if path.exists():
                chosen[entry["flyer_id"]] = path
    return sorted(chosen.values())


def ocr_page(root: Path, flyer: dict, page: dict, **kwargs):
    # Regional editions can share an identical image. Protect shared raw cache
    # files while still applying the caption/source rules separately per page.
    key = (str(root.resolve()), page["sha256"])
    with _OCR_LOCK_GUARD:
        lock = _OCR_LOCKS.setdefault(key, threading.Lock())
    with lock:
        return _ocr_page(root, flyer, page, **kwargs)


def _ocr_page(
    root: Path,
    flyer: dict,
    page: dict,
    *,
    languages: str,
    tessdata_dir: str | None,
    version: str,
    engine="tesseract",
    model_info=None,
    previous_cache=None,
) -> tuple[list[dict], dict]:
    source = root / page["path"]
    if hashlib.sha256(source.read_bytes()).hexdigest() != page["sha256"]:
        raise ValueError("Source image hash no longer matches manifest: " + str(source))
    key = hashlib.sha256(
        (
            page["sha256"]
            + version
            + languages
            + engine
            + "green-psm11-v2"
            + json.dumps(model_info, sort_keys=True)
        ).encode()
    ).hexdigest()
    out = root / "ocr" / key
    tsv = out.with_suffix(".tsv")
    completed = out.with_suffix(".tess-ok.json")
    if previous_cache and previous_cache != out.with_suffix(".json"):
        previous = Path(previous_cache).with_suffix("")
        if not tsv.exists() and previous.with_suffix(".tsv").exists():
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(previous.with_suffix(".tsv"), tsv)
            if previous.with_suffix(".txt").exists():
                shutil.copyfile(previous.with_suffix(".txt"), out.with_suffix(".txt"))
            write_json(
                completed,
                {
                    "image_sha256": page["sha256"],
                    "tsv_sha256": hashlib.sha256(tsv.read_bytes()).hexdigest(),
                },
            )
        previous_raw = previous.with_suffix(".rapid.json")
        metadata = json.loads(Path(previous_cache).read_text())
        previous_models = metadata.get("page", {}).get("model_info") or {}
        if (
            engine == "hybrid"
            and not out.with_suffix(".rapid.json").exists()
            and previous_raw.exists()
            and previous_models.get("models") == model_info.get("models")
        ):
            shutil.copyfile(previous_raw, out.with_suffix(".rapid.json"))
    cache_hit = tsv.exists() and (
        completed.exists() or out.with_suffix(".json").exists()
    )
    if cache_hit and completed.exists():
        marker = json.loads(completed.read_text())
        cache_hit = (
            marker.get("image_sha256") == page["sha256"]
            and marker.get("tsv_sha256") == hashlib.sha256(tsv.read_bytes()).hexdigest()
        )
    if not cache_hit:
        out.parent.mkdir(parents=True, exist_ok=True)
        image_source = source
        if engine == "hybrid" or source.suffix.lower() in (".avif", ".webp"):
            from PIL import Image

            image_source = out.with_suffix(".png")
            pixels = Image.open(source).convert("RGB")
            if engine == "hybrid":
                pixels = pixels.getchannel("G")
            pixels.save(image_source)
        args = [
            "tesseract",
            str(image_source),
            str(out),
            "-l",
            languages,
            "--psm",
            "11",
            "--dpi",
            "300",
        ]
        if tessdata_dir:
            args += ["--tessdata-dir", tessdata_dir]
        args += ["-c", "tessedit_create_tsv=1", "-c", "tessedit_create_txt=1"]
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=180,
            env={**os.environ, "OMP_THREAD_LIMIT": "1"},
        )
        if image_source != source:
            image_source.unlink(missing_ok=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip()[:1200])
        write_json(
            completed,
            {
                "image_sha256": page["sha256"],
                "tsv_sha256": hashlib.sha256(tsv.read_bytes()).hexdigest(),
            },
        )
    words = parse_tsv(tsv.read_text(encoding="utf-8"))
    if engine == "hybrid":
        from .vision import recognize, caption_offers, VERSION

        raw_cache = out.with_suffix(".rapid.json")
        cached = json.loads(raw_cache.read_text()) if raw_cache.exists() else None
        if (
            isinstance(cached, dict)
            and cached.get("recognition_scope") == "connected_glyph_price_regions_v3"
        ):
            lines = cached["lines"]
        else:
            lines = recognize(source)
            write_json(
                raw_cache,
                {
                    "recognition_scope": "connected_glyph_price_regions_v3",
                    "lines": lines,
                },
            )
        records = caption_offers(
            words, lines, flyer, page, source, version + ";" + VERSION
        )
    else:
        records = extract_offers(
            words, flyer, page, version + ";lang=" + languages + ";psm=11"
        )
    evidence = {
        "flyer_id": flyer["flyer_id"],
        "page_number": page["page_number"],
        "image_path": page["path"],
        "image_sha256": page["sha256"],
        "ocr_tsv": str(tsv.relative_to(root)),
        "ocr_text": str(out.with_suffix(".txt").relative_to(root)),
        "words": len(words),
        "price_proposals": len(records),
        "cache_hit": cache_hit,
        "engine": engine,
        "model_info": model_info,
    }
    write_json(
        out.with_suffix(".json"),
        {
            "engine": version,
            "languages": languages,
            "image_sha256": page["sha256"],
            "words": words,
            "page": evidence,
        },
    )
    return records, evidence


def merge_page(root, flyer, page, proposals):
    """Commit each completed page, preserving reviews and manual additions."""
    invalidated = []
    with database(root) as db:
        rows = db.execute(
            "SELECT payload_json FROM offers WHERE flyer_id=?", (flyer["flyer_id"],)
        ).fetchall()
        existing = {
            o["offer_id"]: o
            for row in rows
            if (o := json.loads(row[0]))["evidence"]["page_number"]
            == page["page_number"]
        }
        new_ids = {p["offer_id"] for p in proposals}
        for old in existing.values():
            retained = old["evidence"].get("entry_method") == "manual" or (
                old["review"]["status"] in ("validated", "rejected")
                and old["offer_id"] not in new_ids
            )
            if not retained or old["evidence"]["image_sha256"] != page["sha256"]:
                continue
            manual = json.loads(json.dumps(old))
            if any(
                old.get(k) != v
                for k, v in [
                    ("geography", flyer["geography"]),
                    ("flyer_valid_from", flyer["valid_from"]),
                    ("flyer_valid_to", flyer["valid_to"]),
                ]
            ):
                manual.update(
                    geography=flyer["geography"],
                    valid_from=flyer["valid_from"],
                    valid_to=flyer["valid_to"],
                    flyer_valid_from=flyer["valid_from"],
                    flyer_valid_to=flyer["valid_to"],
                )
                manual["review"].update(status="needs_review", reviewer=None)
                manual["review"]["reasons"].append("source_metadata_changed")
            proposals.append(manual)
        db.execute(
            "INSERT OR REPLACE INTO flyers VALUES (?,?,?,?,?)",
            (
                flyer["flyer_id"],
                flyer["retailer_id"],
                flyer["valid_from"],
                flyer["valid_to"],
                json.dumps(flyer, ensure_ascii=False),
            ),
        )
        for old in existing.values():
            db.execute("DELETE FROM offers WHERE offer_id=?", (old["offer_id"],))
        for proposal in proposals:
            old = existing.get(proposal["offer_id"])
            same = (
                old
                and all(
                    old.get(k) == proposal.get(k)
                    for k in (
                        "retailer_id",
                        "geography",
                        "flyer_valid_from",
                        "flyer_valid_to",
                    )
                )
                and old["evidence"]["image_sha256"]
                == proposal["evidence"]["image_sha256"]
            )
            if old and old["review"]["status"] == "validated" and not same:
                invalidated.append(old["offer_id"])
            offer = (
                old
                if same and old["review"]["status"] in ("validated", "rejected")
                else proposal
            )
            save_offer(db, offer)
        ids = {p["offer_id"] for p in proposals}
        orphaned = [
            o["offer_id"]
            for o in existing.values()
            if o["review"]["status"] == "validated" and o["offer_id"] not in ids
        ]
    return invalidated, orphaned


def extract(
    root: Path,
    *,
    languages="eng+fra",
    tessdata_dir=None,
    workers=2,
    engine="tesseract",
    stores=None,
    max_pages=None,
) -> dict:
    report = {
        "started_at": now(),
        "status": "running",
        "pages": [],
        "errors": [],
        "offer_count": 0,
        "warning": "OCR proposals are unverified. Completeness and product-price associations are not guaranteed.",
    }
    manifests = manifest_paths(root)
    if not manifests:
        report.update(status="empty", finished_at=now())
        write_json(root / "extraction-report.json", report)
        return report
    if not shutil.which("tesseract"):
        raise RuntimeError(
            "Install Tesseract OCR with English and French language data first"
        )
    version = subprocess.run(
        ["tesseract", "--version"], capture_output=True, text=True, check=True
    ).stdout.splitlines()[0]
    model_info = None
    if engine == "hybrid":
        from .vision import engine_info

        model_info = engine_info()
    elif engine != "tesseract":
        raise ValueError("Unknown OCR engine: " + engine)
    report["engine"] = engine
    report["model_info"] = model_info
    lang_args = ["tesseract", "--list-langs"]
    if tessdata_dir:
        lang_args += ["--tessdata-dir", tessdata_dir]
    available = subprocess.run(
        lang_args, capture_output=True, text=True, check=True
    ).stdout.splitlines()[1:]
    missing = set(languages.split("+")) - set(available)
    if missing:
        raise RuntimeError(
            "Missing Tesseract language data: " + ", ".join(sorted(missing))
        )
    invalidated_reviews = []
    orphaned_reviews = []
    flyers = [json.loads(p.read_text(encoding="utf-8")) for p in manifests]
    if stores:
        flyers = [f for f in flyers if f["retailer_id"] in stores]
    selected = [(f, p) for f in flyers for p in f["pages"]]
    report["available_pages"] = len(selected)
    if max_pages is not None:
        if max_pages < 1:
            raise ValueError("max_pages must be positive")
        selected = selected[:max_pages]
    report["selected_pages"] = len(selected)
    cache_index = {}
    for metadata_path in (root / "ocr").glob("*.json"):
        if metadata_path.name.endswith(".rapid.json"):
            continue
        try:
            metadata = json.loads(metadata_path.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(metadata, dict) or "page" not in metadata:
            continue
        if metadata.get("engine") != version:
            continue
        key = (
            metadata.get("image_sha256"),
            metadata.get("languages"),
            metadata["page"].get("engine", "tesseract"),
        )
        if (
            key not in cache_index
            or metadata_path.stat().st_mtime > cache_index[key].stat().st_mtime
        ):
            cache_index[key] = metadata_path
    with ThreadPoolExecutor(max_workers=max(1, min(workers, 8))) as executor:
        futures = {
            executor.submit(
                ocr_page,
                root,
                flyer,
                page,
                languages=languages,
                tessdata_dir=tessdata_dir,
                version=version,
                engine=engine,
                model_info=model_info,
                previous_cache=cache_index.get((page["sha256"], languages, engine)),
            ): (flyer, page)
            for flyer, page in selected
        }
        try:
            for future in as_completed(futures):
                flyer, page = futures[future]
                try:
                    proposals, evidence = future.result()
                    invalidated, orphaned = merge_page(root, flyer, page, proposals)
                    invalidated_reviews.extend(invalidated)
                    orphaned_reviews.extend(orphaned)
                    report["offer_count"] += len(proposals)
                    report["pages"].append(evidence)
                    LOG.info(
                        "OCR %s page %s: %s proposals",
                        flyer["retailer_id"],
                        page["page_number"],
                        len(proposals),
                    )
                except (
                    OSError,
                    RuntimeError,
                    ValueError,
                    subprocess.SubprocessError,
                ) as error:
                    report["errors"].append(
                        {
                            "flyer_id": flyer["flyer_id"],
                            "image_path": page["path"],
                            "error": str(error),
                        }
                    )
                write_json(root / "extraction-report.json", report)
        except KeyboardInterrupt:
            for future in futures:
                future.cancel()
            report["errors"].append({"error": "interrupted"})
    report.update(
        finished_at=now(),
        status="partial"
        if report["errors"] or len(selected) < report["available_pages"]
        else "complete",
    )
    report["orphaned_reviewed_offers"] = orphaned_reviews
    report["invalidated_reviews_after_metadata_change"] = invalidated_reviews
    write_json(root / "extraction-report.json", report)
    export(root)
    return report


def save_offer(db: sqlite3.Connection, offer: dict) -> None:
    offer["source_context_hash"] = source_context_hash(offer)
    db.execute(
        "INSERT OR REPLACE INTO offers VALUES (?,?,?,?,?,?,?)",
        (
            offer["offer_id"],
            offer["flyer_id"],
            offer["retailer_id"],
            offer["valid_from"],
            offer["valid_to"],
            offer["review"]["status"],
            json.dumps(offer, ensure_ascii=False),
        ),
    )


def export(root: Path) -> dict:
    offers = load_offers(root)
    folder = root / "exports"
    folder.mkdir(parents=True, exist_ok=True)

    def jsonl(path, rows):
        tmp = path.with_suffix(".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        tmp.replace(path)

    jsonl(folder / "offers.jsonl", offers)
    eligible = [
        o
        for o in offers
        if o["review"]["status"] == "validated"
        and o["price"]["kind"] in ("sale", "multibuy")
    ]
    jsonl(folder / "validated-deals.jsonl", eligible)
    jsonl(
        folder / "review-queue.jsonl",
        [o for o in offers if o["review"]["status"] == "needs_review"],
    )
    fields = [
        "offer_id",
        "retailer",
        "provinces",
        "cities",
        "published_region",
        "valid_from",
        "valid_to",
        "product",
        "size",
        "amount_cents",
        "currency",
        "purchase_quantity",
        "basis",
        "kind",
        "requires_membership",
        "unit_price_cents_decimal",
        "unit_price_per",
        "conditions",
        "status",
        "review_reasons",
        "page_number",
        "source_url",
        "source_image_url",
        "image_path",
    ]
    with (folder / "offers.csv").open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for o in offers:
            p, geo, u = o["price"], o["geography"], o["unit_price"] or {}
            writer.writerow(
                {
                    "offer_id": o["offer_id"],
                    "retailer": o["retailer_name"],
                    "provinces": "|".join(geo["provinces"]),
                    "cities": "|".join(geo["cities"]),
                    "published_region": geo["published_region"],
                    "valid_from": o["valid_from"],
                    "valid_to": o["valid_to"],
                    "product": o["product"]["name"],
                    "size": o["product"]["size"]["raw"],
                    "amount_cents": p["amount_cents"],
                    "currency": p["currency"],
                    "purchase_quantity": p["purchase_quantity"],
                    "basis": p["basis"],
                    "kind": p["kind"],
                    "requires_membership": p["requires_membership"],
                    "unit_price_cents_decimal": u.get("amount_cents_decimal"),
                    "unit_price_per": u.get("per"),
                    "conditions": " | ".join(o["conditions"]),
                    "status": o["review"]["status"],
                    "review_reasons": "|".join(o["review"]["reasons"]),
                    **{
                        k: o["evidence"][k]
                        for k in (
                            "page_number",
                            "source_url",
                            "source_image_url",
                            "image_path",
                        )
                    },
                }
            )
    from .review_ui import render_review, render_pages

    flyers = [json.loads(path.read_text()) for path in manifest_paths(root)]
    (folder / "review.html").write_text(
        render_review(root, offers, flyers), encoding="utf-8"
    )
    counts_by_page = {}
    for offer in offers:
        key = (offer["flyer_id"], offer["evidence"]["page_number"])
        counts_by_page[key] = counts_by_page.get(key, 0) + 1
    (folder / "pages.html").write_text(
        render_pages(flyers, counts_by_page), encoding="utf-8"
    )
    from .source_ui import render_sources

    (folder / "sources.html").write_text(render_sources(flyers), encoding="utf-8")
    jsonl(
        folder / "source-review-queue.jsonl",
        [
            f
            for f in flyers
            if f["geography"]["scope"] == "unknown"
            or not f.get("valid_from")
            or not f.get("valid_to")
        ],
    )
    counts = {
        "offers": len(offers),
        "validated_deals": len(eligible),
        "needs_review": sum(o["review"]["status"] == "needs_review" for o in offers),
    }
    write_json(folder / "summary.json", {"generated_at": now(), **counts})
    return counts


def manual_proposal(root: Path, item: dict) -> dict:
    flyer = None
    for path in manifest_paths(root):
        candidate = json.loads(path.read_text())
        if candidate["flyer_id"] == item.get("flyer_id"):
            flyer = candidate
            break
    if not flyer:
        raise ValueError("Unknown flyer_id for manual entry")
    page = next(
        (
            p
            for p in flyer["pages"]
            if p["page_number"] == item.get("page_number")
            and p["sha256"] == item.get("image_sha256")
        ),
        None,
    )
    if not page:
        raise ValueError(
            "Manual entry must identify an exact downloaded page and image SHA256"
        )
    from .reviews import checked_image

    checked_image(root, page)
    box = item.get("price_bbox_px")
    if (
        not isinstance(box, list)
        or len(box) != 4
        or any(type(n) is not int or n < 0 for n in box)
        or box[2] < 1
        or box[3] < 1
        or box[0] + box[2] > page["width"]
        or box[1] + box[3] > page["height"]
    ):
        raise ValueError("Manual price box must be inside the original image")
    key = stable_id("manual", flyer["flyer_id"], page["sha256"], str(box))
    return {
        "schema_version": 1,
        "offer_id": key,
        "flyer_id": flyer["flyer_id"],
        "retailer_id": flyer["retailer_id"],
        "retailer_name": flyer["retailer_name"],
        "geography": flyer["geography"],
        "valid_from": flyer["valid_from"],
        "valid_to": flyer["valid_to"],
        "flyer_valid_from": flyer["valid_from"],
        "flyer_valid_to": flyer["valid_to"],
        "product": {
            "name": None,
            "brand": None,
            "canonical_tokens": [],
            "size": parse_size(""),
            "details_raw": "Manually entered from the original flyer image",
        },
        "price": {
            "currency": "CAD",
            "raw": "manual entry",
            "amount_cents": 1,
            "purchase_quantity": 1,
            "kind": "sale",
            "basis": "each",
            "requires_membership": False,
            "flags": [],
        },
        "unit_price": None,
        "conditions": [],
        "review": {
            "status": "needs_review",
            "reasons": ["manual_entry"],
            "reviewer": None,
        },
        "evidence": {
            "source_url": flyer["source_url"],
            "source_image_url": page["source_image_url"],
            "image_path": page["path"],
            "image_sha256": page["sha256"],
            "page_number": page["page_number"],
            "price_bbox_px": box,
            "price_bbox_normalized": [
                box[0] / page["width"],
                box[1] / page["height"],
                box[2] / page["width"],
                box[3] / page["height"],
            ],
            "ocr_engine": "manual review",
            "ocr_price_confidence": None,
            "retrieved_at": flyer["retrieved_at"],
            "entry_method": "manual",
        },
    }


def apply_reviews(root: Path, decisions: Path) -> dict:
    known = {o["offer_id"]: o for o in load_offers(root)}
    current_sources = {}
    for path in manifest_paths(root):
        flyer = json.loads(path.read_text())
        current_sources[flyer["flyer_id"]] = flyer
    pending = []
    seen = set()
    for line in decisions.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        if item.get("entry_method") == "manual":
            offer = manual_proposal(root, item)
            if item.get("offer_id") and item["offer_id"] != offer["offer_id"]:
                raise ValueError("Manual offer_id does not match the source box")
            item["offer_id"] = offer["offer_id"]
            known.setdefault(item["offer_id"], offer)
        if item["offer_id"] in seen:
            raise ValueError("Duplicate offer decision: " + item["offer_id"])
        seen.add(item["offer_id"])
        offer = known.get(item["offer_id"])
        if not offer:
            raise ValueError("Unknown offer_id: " + item["offer_id"])
        if (
            not isinstance(item.get("reviewer"), str)
            or not item["reviewer"].strip()
            or item.get("status") not in ("validated", "rejected")
        ):
            raise ValueError(
                "Every decision needs reviewer and status validated/rejected"
            )
        if item.get("image_sha256") != offer["evidence"]["image_sha256"]:
            raise ValueError("Review must name the exact source image SHA256")
        if item["status"] == "validated":
            from .reviews import checked_image

            current = current_sources.get(offer["flyer_id"])
            if (
                not current
                or any(
                    offer.get(key) != current.get(field)
                    for key, field in (
                        ("geography", "geography"),
                        ("flyer_valid_from", "valid_from"),
                        ("flyer_valid_to", "valid_to"),
                    )
                )
                or not any(
                    p["page_number"] == offer["evidence"]["page_number"]
                    and p["sha256"] == offer["evidence"]["image_sha256"]
                    for p in current["pages"]
                )
            ):
                raise ValueError(
                    "Source dates or geography changed, or the current source manifest is missing; re-extract before validation"
                )
            checked_image(
                root,
                {
                    "path": offer["evidence"]["image_path"],
                    "sha256": offer["evidence"]["image_sha256"],
                },
            )
            if item.get("source_context_hash") != source_context_hash(offer):
                raise ValueError(
                    "Source dates or geography changed, or source_context_hash was not checked; export a fresh review queue"
                )
            required = {
                "product_name",
                "size_text",
                "amount_cents",
                "purchase_quantity",
                "basis",
                "kind",
                "requires_membership",
                "conditions",
                "offer_valid_from",
                "offer_valid_to",
            }
            missing = required - set(item)
            if missing:
                raise ValueError(
                    "Explicitly check every offer field: " + ", ".join(sorted(missing))
                )
            if (
                not offer["valid_from"]
                or not offer["valid_to"]
                or offer["geography"]["scope"] == "unknown"
            ):
                raise ValueError(
                    "Resolve source validity dates and region in the manifest, then re-extract before validation"
                )
            if (
                not isinstance(item.get("product_name"), str)
                or not item["product_name"].strip()
                or len(item["product_name"]) > 200
                or type(item.get("amount_cents")) is not int
                or not 0 < item["amount_cents"] <= 500_000
            ):
                raise ValueError(
                    "Validation requires an explicitly checked product_name and integer amount_cents"
                )
            if not isinstance(item["size_text"], str):
                raise ValueError(
                    "size_text must be a string; use an empty string for unknown size"
                )
            if item.get("brand") is not None and not isinstance(item["brand"], str):
                raise ValueError("brand must be a string or null")
            if not (item.get("offer_valid_from") and item.get("offer_valid_to")):
                raise ValueError(
                    "Check this offer's dates and provide offer_valid_from/offer_valid_to"
                )
            if item.get("offer_valid_from") or item.get("offer_valid_to"):
                a, b = (
                    date.fromisoformat(item["offer_valid_from"]),
                    date.fromisoformat(item["offer_valid_to"]),
                )
                if (
                    not offer["flyer_valid_from"]
                    <= a.isoformat()
                    <= b.isoformat()
                    <= offer["flyer_valid_to"]
                ):
                    raise ValueError(
                        "Offer dates must be inside the source flyer validity period"
                    )
                offer["valid_from"], offer["valid_to"] = a.isoformat(), b.isoformat()
            offer["product"]["name"] = item["product_name"]
            offer["product"]["canonical_tokens"] = product_tokens(item["product_name"])
            offer["product"]["brand"] = item.get("brand")
            if "size_text" in item:
                offer["product"]["size"] = parse_size(item["size_text"])
            offer["price"]["amount_cents"] = item["amount_cents"]
            for key in ("purchase_quantity", "basis", "kind", "requires_membership"):
                if key in item:
                    offer["price"][key] = item[key]
            p = offer["price"]
            if (
                type(p["purchase_quantity"]) is not int
                or p["purchase_quantity"] < 1
                or p["basis"] not in ("each", "lb", "kg", "100g", "100ml", "L")
                or p["kind"] not in ("sale", "multibuy", "savings", "regular")
                or type(p["requires_membership"]) is not bool
            ):
                raise ValueError("Invalid reviewed price parameters")
            if (p["purchase_quantity"] > 1) != (p["kind"] == "multibuy"):
                raise ValueError(
                    "A multi-buy needs two or more units; a sale/regular/savings amount uses one unit"
                )
            if "conditions" in item:
                if not isinstance(item["conditions"], list) or not all(
                    isinstance(c, str) for c in item["conditions"]
                ):
                    raise ValueError("conditions must be an array of strings")
                offer["conditions"] = item["conditions"]
            offer["unit_price"] = unit_price(offer["price"], offer["product"]["size"])
        if item["status"] == "validated":
            offer["review"]["original_reasons"] = offer["review"]["reasons"]
            offer["review"]["reasons"] = []
            offer["price"]["flags"] = [
                flag
                for flag in offer["price"]["flags"]
                if flag != "weight_basis_unresolved"
            ]
        offer["review"].update(
            status=item["status"],
            reviewer=item["reviewer"].strip(),
            reviewed_at=now(),
            notes=item.get("notes"),
        )
        pending.append((offer, item))
    with database(root) as db:
        for offer, _ in pending:
            save_offer(db, offer)
    with (root / "review-audit.jsonl").open("a", encoding="utf-8") as f:
        for offer, item in pending:
            f.write(
                json.dumps(
                    {"at": offer["review"]["reviewed_at"], "decision": item},
                    ensure_ascii=False,
                )
                + "\n"
            )
    return {"applied": len(pending), **export(root)}
