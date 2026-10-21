"""Derive visual assessment coverage from the current persisted records."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

from .download import now, write_json


def refresh_assessment_report(root: Path, offers: list[dict], *, batch_size=None):
    path = root / "visual-review-report.json"
    assessed = [
        o
        for o in offers
        if o["review"].get("assessment", {}).get("source_image_inspected")
    ]
    if not assessed and not path.exists():
        return None
    report = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    report.update(
        generated_at=now(),
        method="ai_or_human_visual_assessments",
        assessed_offers=len(assessed),
        complete_offer_coverage=bool(offers) and len(assessed) == len(offers),
        unique_source_images=len({o["evidence"]["image_sha256"] for o in assessed}),
        outcomes=dict(Counter(o["review"]["status"] for o in assessed)),
        interpretation="Image review covers existing proposals, including rejected detections and unresolved fields. Outcomes reflect current review states. It does not measure extraction recall or train the OCR recognizer.",
    )
    if batch_size is not None:
        report["applied_in_batch"] = batch_size
    write_json(path, report)
    return report
