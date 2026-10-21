"""Offline source-date, edition and regional-exclusion review."""

from pathlib import Path
import json
import hashlib
from urllib.parse import quote


def render_sources(flyers):
    rows = []
    for flyer in flyers:
        rows.append(
            {
                k: flyer.get(k)
                for k in (
                    "flyer_id",
                    "source_title",
                    "source_url",
                    "valid_from",
                    "valid_to",
                    "geography",
                    "warnings",
                    "source_review",
                )
            }
        )
        rows[-1]["pages"] = [
            {
                "page_number": p["page_number"],
                "image_sha256": p["sha256"],
                "url": "../" + quote(p["path"]),
            }
            for p in flyer["pages"]
        ]
    data = (
        json.dumps(rows, ensure_ascii=False)
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
    )
    key = hashlib.sha256(
        json.dumps(
            [(f["flyer_id"], [p["image_sha256"] for p in f["pages"]]) for f in rows],
            sort_keys=True,
        ).encode()
    ).hexdigest()[:16]
    return TEMPLATE.replace("__STORAGE_KEY__", key).replace("__DATA__", data)


TEMPLATE = (Path(__file__).parent / "templates" / "sources.html").read_text(
    encoding="utf-8"
)
