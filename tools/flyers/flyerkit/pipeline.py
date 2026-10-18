"""OCR, review, SQLite storage and app-ready exports."""
from __future__ import annotations

import csv
import hashlib
import html
import json
import logging
import shutil
import sqlite3
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from datetime import date

from .download import now, write_json
from .offers import extract_offers, parse_size, parse_tsv, product_tokens, unit_price

LOG = logging.getLogger(__name__)


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
        return [json.loads(row[0]) for row in db.execute("SELECT payload_json FROM offers ORDER BY retailer_id, valid_from, offer_id")]


def ocr_page(root: Path, flyer: dict, page: dict, *, languages: str, tessdata_dir: str | None, version: str) -> tuple[list[dict], dict]:
    source = root / page["path"]
    if hashlib.sha256(source.read_bytes()).hexdigest() != page["sha256"]:
        raise ValueError("Source image hash no longer matches manifest: " + str(source))
    key = hashlib.sha256((page["sha256"] + version + languages + "psm11-v1").encode()).hexdigest()
    out = root / "ocr" / key
    tsv = out.with_suffix(".tsv")
    cache_hit = tsv.exists()
    if not cache_hit:
        out.parent.mkdir(parents=True, exist_ok=True)
        args = ["tesseract", str(source), str(out), "-l", languages, "--psm", "11", "--dpi", "300"]
        if tessdata_dir: args += ["--tessdata-dir", tessdata_dir]
        args += ["-c", "tessedit_create_tsv=1", "-c", "tessedit_create_txt=1"]
        result = subprocess.run(args, capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise RuntimeError(result.stderr.strip()[:1200])
    words = parse_tsv(tsv.read_text(encoding="utf-8"))
    records = extract_offers(words, flyer, page, version + ";lang=" + languages + ";psm=11")
    evidence = {"flyer_id": flyer["flyer_id"], "page_number": page["page_number"], "image_path": page["path"],
                "ocr_tsv": str(tsv.relative_to(root)), "ocr_text": str(out.with_suffix(".txt").relative_to(root)),
                "words": len(words), "price_proposals": len(records), "cache_hit": cache_hit}
    write_json(out.with_suffix(".json"), {"engine": version, "languages": languages, "image_sha256": page["sha256"],
                                        "words": words, "page": evidence})
    return records, evidence


def extract(root: Path, *, languages="eng+fra", tessdata_dir=None, workers=2) -> dict:
    report = {"started_at": now(), "status": "running", "pages": [], "errors": [], "offer_count": 0,
              "warning": "OCR proposals are unverified. Completeness and product-price associations are not guaranteed."}
    manifests = sorted((root / "regions").rglob("manifest.json")) if (root / "regions").exists() else []
    if not manifests:
        report.update(status="empty", finished_at=now())
        write_json(root / "extraction-report.json", report)
        return report
    if not shutil.which("tesseract"):
        raise RuntimeError("Install Tesseract OCR with English and French language data first")
    version = subprocess.run(["tesseract", "--version"], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    lang_args = ["tesseract", "--list-langs"]
    if tessdata_dir: lang_args += ["--tessdata-dir", tessdata_dir]
    available = subprocess.run(lang_args, capture_output=True, text=True, check=True).stdout.splitlines()[1:]
    missing = set(languages.split("+")) - set(available)
    if missing:
        raise RuntimeError("Missing Tesseract language data: " + ", ".join(sorted(missing)))
    existing = {o["offer_id"]: o for o in load_offers(root)}
    all_offers = []
    invalidated_reviews = []
    flyers = [json.loads(p.read_text(encoding="utf-8")) for p in manifests]
    with ThreadPoolExecutor(max_workers=max(1, min(workers, 8))) as executor:
        futures = {executor.submit(ocr_page, root, flyer, page, languages=languages, tessdata_dir=tessdata_dir, version=version):
                   (flyer, page) for flyer in flyers for page in flyer["pages"]}
        for future in as_completed(futures):
            flyer, page = futures[future]
            try:
                proposals, evidence = future.result()
                all_offers.extend(proposals)
                report["pages"].append(evidence)
                LOG.info("OCR %s page %s: %s proposals", flyer["retailer_id"], page["page_number"], len(proposals))
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                report["errors"].append({"flyer_id": flyer["flyer_id"], "image_path": page["path"], "error": str(error)})
            write_json(root / "extraction-report.json", report)
    with database(root) as db:
        for flyer in flyers:
            db.execute("INSERT OR REPLACE INTO flyers VALUES (?,?,?,?,?)", (flyer["flyer_id"], flyer["retailer_id"], flyer["valid_from"], flyer["valid_to"], json.dumps(flyer, ensure_ascii=False)))
        # Keep earlier records for failed OCR pages rather than erasing reviewed evidence.
        refreshed_pages = {(p["flyer_id"], p["page_number"]) for p in report["pages"]}
        for old in existing.values():
            if (old["flyer_id"], old["evidence"]["page_number"]) in refreshed_pages:
                db.execute("DELETE FROM offers WHERE offer_id=?", (old["offer_id"],))
        for proposal in all_offers:
            old = existing.get(proposal["offer_id"])
            same_context = old and all(old.get(k) == proposal.get(k) for k in ("retailer_id", "geography", "flyer_valid_from", "flyer_valid_to"))
            keep_review = old and old["review"]["status"] in ("validated", "rejected") and same_context
            if old and old["review"]["status"] == "validated" and not same_context:
                invalidated_reviews.append(old["offer_id"])
            offer = old if keep_review else proposal
            save_offer(db, offer)
    report.update(offer_count=len(all_offers), finished_at=now(), status="partial" if report["errors"] else "complete")
    report["orphaned_reviewed_offers"] = [o["offer_id"] for o in existing.values() if o["review"]["status"] == "validated"
        and (o["flyer_id"], o["evidence"]["page_number"]) in refreshed_pages and o["offer_id"] not in {p["offer_id"] for p in all_offers}]
    report["invalidated_reviews_after_metadata_change"] = invalidated_reviews
    write_json(root / "extraction-report.json", report)
    export(root)
    return report


def save_offer(db: sqlite3.Connection, offer: dict) -> None:
    db.execute("INSERT OR REPLACE INTO offers VALUES (?,?,?,?,?,?,?)", (offer["offer_id"], offer["flyer_id"], offer["retailer_id"],
               offer["valid_from"], offer["valid_to"], offer["review"]["status"], json.dumps(offer, ensure_ascii=False)))


def export(root: Path) -> dict:
    offers = load_offers(root)
    folder = root / "exports"
    folder.mkdir(parents=True, exist_ok=True)
    def jsonl(path, rows):
        tmp = path.with_suffix(".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            for row in rows: f.write(json.dumps(row, ensure_ascii=False) + "\n")
        tmp.replace(path)
    jsonl(folder / "offers.jsonl", offers)
    eligible = [o for o in offers if o["review"]["status"] == "validated" and o["price"]["kind"] in ("sale", "multibuy")]
    jsonl(folder / "validated-deals.jsonl", eligible)
    jsonl(folder / "review-queue.jsonl", [o for o in offers if o["review"]["status"] == "needs_review"])
    fields = ["offer_id", "retailer", "provinces", "cities", "published_region", "valid_from", "valid_to", "product",
              "size", "amount_cents", "currency", "purchase_quantity", "basis", "kind", "requires_membership",
              "unit_price_cents_decimal", "unit_price_per", "conditions", "status", "review_reasons", "page_number",
              "source_url", "source_image_url", "image_path"]
    with (folder / "offers.csv").open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for o in offers:
            p, geo, u = o["price"], o["geography"], o["unit_price"] or {}
            writer.writerow({"offer_id": o["offer_id"], "retailer": o["retailer_name"], "provinces": "|".join(geo["provinces"]),
                "cities": "|".join(geo["cities"]), "published_region": geo["published_region"], "valid_from": o["valid_from"], "valid_to": o["valid_to"],
                "product": o["product"]["name"], "size": o["product"]["size"]["raw"], "amount_cents": p["amount_cents"],
                "currency": p["currency"], "purchase_quantity": p["purchase_quantity"], "basis": p["basis"], "kind": p["kind"],
                "requires_membership": p["requires_membership"], "unit_price_cents_decimal": u.get("amount_cents_decimal"), "unit_price_per": u.get("per"),
                "conditions": " | ".join(o["conditions"]), "status": o["review"]["status"], "review_reasons": "|".join(o["review"]["reasons"]),
                **{k: o["evidence"][k] for k in ("page_number", "source_url", "source_image_url", "image_path")}})
    # Review original pages with price boxes; this is not an image transformation.
    cards = []
    for o in offers:
        e = o["evidence"]
        image = (root / e["image_path"]).resolve().as_uri()
        x, y, w, h = [n * 100 for n in e["price_bbox_normalized"]]
        cards.append(f'<article><h2>{html.escape(o["retailer_name"])} — {html.escape(o["product"]["name"] or "Unresolved product")}</h2>'
                     f'<p>{html.escape(o["offer_id"])} · {html.escape(o["review"]["status"])}</p>'
                     f'<pre>{html.escape(json.dumps({"price": o["price"], "size": o["product"]["size"], "dates": [o["valid_from"], o["valid_to"]], "region": o["geography"], "reasons": o["review"]["reasons"]}, ensure_ascii=False, indent=2))}</pre>'
                     f'<div class="page"><img loading="lazy" src="{html.escape(image)}" alt="Original source flyer, page {e["page_number"]}">'
                     f'<span class="box" style="left:{x}%;top:{y}%;width:{w}%;height:{h}%"></span></div></article>')
    (folder / "review.html").write_text('<!doctype html><html lang="en"><meta charset="utf-8"><title>Flyer offer review</title>'
        '<style>body{font:16px system-ui;margin:24px;background:#f5f5f5}article{max-width:900px;margin:24px auto;padding:24px;background:white}pre{white-space:pre-wrap}.page{position:relative}.page img{width:100%;display:block}.box{position:absolute;border:3px solid red;box-sizing:border-box}</style>'
        '<h1>Unverified OCR proposals</h1><p>Check the original image, product, package size, conditions, dates and published region before validating.</p>' + "".join(cards) + '</html>', encoding="utf-8")
    counts = {"offers": len(offers), "validated_deals": len(eligible), "needs_review": sum(o["review"]["status"] == "needs_review" for o in offers)}
    write_json(folder / "summary.json", {"generated_at": now(), **counts})
    return counts


def apply_reviews(root: Path, decisions: Path) -> dict:
    known = {o["offer_id"]: o for o in load_offers(root)}
    pending = []
    for line in decisions.read_text(encoding="utf-8").splitlines():
        if not line.strip(): continue
        item = json.loads(line)
        offer = known.get(item["offer_id"])
        if not offer: raise ValueError("Unknown offer_id: " + item["offer_id"])
        if not item.get("reviewer") or item.get("status") not in ("validated", "rejected"):
            raise ValueError("Every decision needs reviewer and status validated/rejected")
        if item.get("image_sha256") != offer["evidence"]["image_sha256"]:
            raise ValueError("Review must name the exact source image SHA256")
        if item["status"] == "validated":
            if not offer["valid_from"] or not offer["valid_to"] or offer["geography"]["scope"] == "unknown":
                raise ValueError("Resolve source validity dates and region in the manifest, then re-extract before validation")
            if not item.get("product_name") or type(item.get("amount_cents")) is not int or not 0 < item["amount_cents"] <= 500_000:
                raise ValueError("Validation requires an explicitly checked product_name and integer amount_cents")
            if "restricted_validity_unresolved" in offer["review"]["reasons"] and not (item.get("offer_valid_from") and item.get("offer_valid_to")):
                raise ValueError("Check this offer's restricted days and provide offer_valid_from/offer_valid_to")
            if item.get("offer_valid_from") or item.get("offer_valid_to"):
                a, b = date.fromisoformat(item["offer_valid_from"]), date.fromisoformat(item["offer_valid_to"])
                if not offer["flyer_valid_from"] <= a.isoformat() <= b.isoformat() <= offer["flyer_valid_to"]:
                    raise ValueError("Offer dates must be inside the source flyer validity period")
                offer["valid_from"], offer["valid_to"] = a.isoformat(), b.isoformat()
            offer["product"]["name"] = item["product_name"]
            offer["product"]["canonical_tokens"] = product_tokens(item["product_name"])
            offer["product"]["brand"] = item.get("brand")
            if "size_text" in item: offer["product"]["size"] = parse_size(item["size_text"])
            offer["price"]["amount_cents"] = item["amount_cents"]
            for key in ("purchase_quantity", "basis", "kind", "requires_membership"):
                if key in item: offer["price"][key] = item[key]
            p = offer["price"]
            if type(p["purchase_quantity"]) is not int or p["purchase_quantity"] < 1 or p["basis"] not in ("each", "lb", "kg", "100g", "100ml", "L") or p["kind"] not in ("sale", "multibuy", "savings", "regular") or type(p["requires_membership"]) is not bool:
                raise ValueError("Invalid reviewed price parameters")
            if "conditions" in item:
                if not isinstance(item["conditions"], list) or not all(isinstance(c, str) for c in item["conditions"]):
                    raise ValueError("conditions must be an array of strings")
                offer["conditions"] = item["conditions"]
            offer["unit_price"] = unit_price(offer["price"], offer["product"]["size"])
        offer["review"].update(status=item["status"], reviewer=item["reviewer"], reviewed_at=now(), notes=item.get("notes"))
        pending.append((offer, item))
    with database(root) as db:
        for offer, _ in pending: save_offer(db, offer)
    with (root / "review-audit.jsonl").open("a", encoding="utf-8") as f:
        for offer, item in pending: f.write(json.dumps({"at": offer["review"]["reviewed_at"], "decision": item}, ensure_ascii=False) + "\n")
    return {"applied": len(pending), **export(root)}
