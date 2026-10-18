"""Offline review UI. Decisions are downloaded as JSONL, never sent to a service."""

from __future__ import annotations

import json
import html
import hashlib
import re
from pathlib import Path
from urllib.parse import quote
from .offers import source_context_hash


def render_review(root: Path, offers: list[dict], flyers=None) -> str:
    rows = []
    for offer in offers:
        relative = Path(offer["evidence"]["image_path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Review image path must stay inside the dataset")
        rows.append(
            {
                **offer,
                "source_context_hash": source_context_hash(offer),
                "local_image": "../" + quote(relative.as_posix()),
            }
        )
    payload = (
        json.dumps(rows, ensure_ascii=False)
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
    )
    dataset = hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:16]
    pages = []
    for flyer in flyers or []:
        for page in flyer["pages"]:
            base = {
                "flyer_id": flyer["flyer_id"],
                "retailer_id": flyer["retailer_id"],
                "retailer_name": flyer["retailer_name"],
                "geography": flyer["geography"],
                "valid_from": flyer["valid_from"],
                "valid_to": flyer["valid_to"],
                "flyer_valid_from": flyer["valid_from"],
                "flyer_valid_to": flyer["valid_to"],
                "evidence": {
                    "source_url": flyer["source_url"],
                    "source_image_url": page["source_image_url"],
                    "image_path": page["path"],
                    "image_sha256": page["sha256"],
                    "page_number": page["page_number"],
                },
                "local_image": "../" + quote(page["path"]),
                "label": flyer["source_title"] + " · page " + str(page["page_number"]),
            }
            base["source_context_hash"] = source_context_hash(base)
            pages.append(base)
    page_data = (
        json.dumps(pages, ensure_ascii=False)
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
    )
    values = {"__PAGES__": page_data, "__DATASET_KEY__": dataset, "__DATA__": payload}
    return re.sub(r"__(?:PAGES|DATASET_KEY|DATA)__", lambda m: values[m[0]], TEMPLATE)


def render_pages(flyers, counts):
    cards = []
    for flyer in sorted(flyers, key=lambda f: (f["retailer_id"], f["source_title"])):
        for page in flyer["pages"]:
            count = counts.get((flyer["flyer_id"], page["page_number"]), 0)
            url = "../" + quote(page["path"])
            cards.append(
                f'<article><h2>{html.escape(flyer["source_title"])}</h2><p>Page {page["page_number"]} · {count} proposals</p><a href="{url}"><img loading="lazy" src="{url}" alt="Original flyer page"></a><p><a href="review.html?manual={quote(flyer["flyer_id"] + ":" + str(page["page_number"]))}">Add a missed offer</a></p><details><summary>Manual-entry evidence</summary><pre>{html.escape(json.dumps({"flyer_id": flyer["flyer_id"], "page_number": page["page_number"], "image_sha256": page["sha256"], "valid_from": flyer["valid_from"], "valid_to": flyer["valid_to"], "geography": flyer["geography"]}, ensure_ascii=False, indent=2))}</pre></details></article>'
            )
    return (
        '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>All flyer pages</title><style>body{font:15px system-ui;margin:24px;background:#f4f5f3}main{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:16px}article{padding:16px;background:white}h2{font-size:16px}img{width:100%;height:300px;object-fit:contain}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style><h1>All source pages</h1><p>Inspect every page, including pages where OCR proposed no offers. Use the manual-entry evidence to add missed offers through the review command.</p><p><a href="review.html">Open offer review</a></p><main>'
        + "".join(cards)
        + "</main></html>"
    )


TEMPLATE = (Path(__file__).parent / "templates" / "review.html").read_text(
    encoding="utf-8"
)
