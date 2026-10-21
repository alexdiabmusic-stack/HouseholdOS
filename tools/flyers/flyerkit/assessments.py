"""Image-bound visual assessments, including explicitly unresolved corrections."""

from __future__ import annotations

import copy
import json
from datetime import date
from pathlib import Path

from .download import now
from .offers import parse_size, product_tokens, source_context_hash, unit_price
from .pipeline import database, export, load_offers, manifest_paths, save_offer
from .reviews import checked_image
from .review_reports import refresh_assessment_report


FIELDS = {
    "product_name",
    "brand",
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
REQUIRED = FIELDS


def apply_fields(offer: dict, fields: dict) -> dict:
    """Apply checked semantics; preserve dates outside the edition as a conflict."""
    unsupported = set(fields) - FIELDS
    if unsupported:
        raise ValueError(
            "Unsupported checked fields: " + ", ".join(sorted(unsupported))
        )
    for key in ("product_name", "size_text"):
        if key in fields and not isinstance(fields[key], str):
            raise ValueError(key + " must be a string")
    if "product_name" in fields and not 0 < len(fields["product_name"].strip()) <= 200:
        raise ValueError("A checked product_name must contain 1–200 characters")
    if (
        "brand" in fields
        and fields["brand"] is not None
        and not isinstance(fields["brand"], str)
    ):
        raise ValueError("brand must be a string or null")
    if "amount_cents" in fields and (
        type(fields["amount_cents"]) is not int
        or not 0 < fields["amount_cents"] <= 500_000
    ):
        raise ValueError("amount_cents must be an integer from 1 to 500000")
    if "purchase_quantity" in fields and (
        type(fields["purchase_quantity"]) is not int or fields["purchase_quantity"] < 1
    ):
        raise ValueError("purchase_quantity must be a positive integer")
    if "basis" in fields and fields["basis"] not in (
        "each",
        "lb",
        "kg",
        "100g",
        "100ml",
        "L",
    ):
        raise ValueError("Unsupported price basis")
    if "kind" in fields and fields["kind"] not in (
        "sale",
        "multibuy",
        "regular",
        "savings",
    ):
        raise ValueError("Unsupported price kind")
    if (
        "requires_membership" in fields
        and type(fields["requires_membership"]) is not bool
    ):
        raise ValueError("requires_membership must be a boolean")
    if "conditions" in fields and (
        not isinstance(fields["conditions"], list)
        or any(not isinstance(c, str) for c in fields["conditions"])
    ):
        raise ValueError("conditions must be an array of strings")
    if "product_name" in fields:
        offer["product"]["name"] = fields["product_name"].strip()
        offer["product"]["canonical_tokens"] = product_tokens(fields["product_name"])
    if "brand" in fields:
        offer["product"]["brand"] = fields["brand"]
    if "product_name" in fields or "brand" in fields:
        offer["product"]["canonical_tokens"] = product_tokens(
            (offer["product"].get("brand") or "")
            + " "
            + (offer["product"].get("name") or "")
        )
    if "size_text" in fields:
        offer["product"]["size"] = parse_size(fields["size_text"])
    for key in (
        "amount_cents",
        "purchase_quantity",
        "basis",
        "kind",
        "requires_membership",
    ):
        if key in fields:
            offer["price"][key] = fields[key]
    if "purchase_quantity" in fields or "kind" in fields:
        p = offer["price"]
        if (p["kind"] == "multibuy" and p["purchase_quantity"] < 2) or (
            p["kind"] in ("sale", "regular") and p["purchase_quantity"] != 1
        ):
            raise ValueError("Multi-buy quantity and kind must agree")
    if "conditions" in fields:
        offer["conditions"] = fields["conditions"]
    unapplied = {}
    if "offer_valid_from" in fields or "offer_valid_to" in fields:
        a, b = fields.get("offer_valid_from"), fields.get("offer_valid_to")
        if not a or not b or date.fromisoformat(a) > date.fromisoformat(b):
            raise ValueError("Check both offer dates in chronological order")
        if not (
            offer.get("flyer_valid_from")
            and offer.get("flyer_valid_to")
            and offer["flyer_valid_from"] <= a <= b <= offer["flyer_valid_to"]
        ):
            unapplied = {"offer_valid_from": a, "offer_valid_to": b}
        else:
            offer["valid_from"], offer["valid_to"] = a, b
    if "basis" in fields:
        offer["price"]["flags"] = [
            flag
            for flag in offer["price"].get("flags", [])
            if flag != "weight_basis_unresolved"
        ]
    offer["unit_price"] = unit_price(offer["price"], offer["product"]["size"])
    return unapplied


def apply_assessments(root: Path, decisions: Path, *, expected_offers=None) -> dict:
    """Preflight the entire batch before changing any record; never promote uncertainty."""
    known = {o["offer_id"]: o for o in load_offers(root)}
    sources = {
        f["flyer_id"]: f
        for p in manifest_paths(root)
        for f in [json.loads(p.read_text(encoding="utf-8"))]
    }
    pending, seen, images = [], set(), set()
    timestamp = now()
    for line in decisions.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        oid = item["offer_id"]
        if oid in seen or oid not in known:
            raise ValueError("Duplicate or unknown offer_id: " + oid)
        seen.add(oid)
        original = known[oid]
        offer = copy.deepcopy(original)
        status = item.get("status")
        if (
            status not in ("validated", "rejected", "needs_review")
            or not isinstance(item.get("reviewer"), str)
            or not item["reviewer"].strip()
            or not isinstance(item.get("notes"), str)
            or not item["notes"].strip()
            or item.get("method") not in ("ai_visual", "human_visual")
            or item.get("source_image_inspected") is not True
        ):
            raise ValueError(
                "An assessment requires explicit visual provenance, status, reviewer and notes"
            )
        if item.get("image_sha256") != offer["evidence"]["image_sha256"]:
            raise ValueError("Assessment image SHA256 does not match the offer")
        if item.get("source_context_hash") != source_context_hash(offer):
            raise ValueError(
                "Stale source_context_hash; review the current source context"
            )
        source = sources.get(offer["flyer_id"])
        page = (
            next(
                (
                    p
                    for p in source["pages"]
                    if (
                        p["page_number"] == offer["evidence"]["page_number"]
                        and p["sha256"] == item["image_sha256"]
                    )
                ),
                None,
            )
            if source
            else None
        )
        if not page or any(
            offer[a] != source[b]
            for a, b in (
                ("geography", "geography"),
                ("flyer_valid_from", "valid_from"),
                ("flyer_valid_to", "valid_to"),
                ("retailer_name", "retailer_name"),
            )
        ):
            raise ValueError("Offer no longer agrees with the source manifest")
        identity = (page["path"], page["sha256"])
        if identity not in images:
            checked_image(root, page)
            images.add(identity)
        fields = item.get("checked_fields", {})
        unresolved = item.get("unresolved_fields", [])
        if (
            not isinstance(fields, dict)
            or not isinstance(unresolved, list)
            or any(not isinstance(f, str) or not f for f in unresolved)
        ):
            raise ValueError(
                "checked_fields must be an object and unresolved_fields a list of names"
            )
        if status == "needs_review" and not unresolved:
            raise ValueError(
                "A pending assessment must identify what remains unresolved"
            )
        unapplied = apply_fields(offer, fields)
        if status == "validated" and (
            REQUIRED - set(fields)
            or unresolved
            or unapplied
            or offer["geography"]["scope"] == "unknown"
            or source.get("source_review", {}).get("status") == "needs_review"
            or source.get("source_review", {}).get("unresolved_fields")
        ):
            raise ValueError(
                "Validation requires every checked field, resolved applicability and dates inside the edition"
            )
        if unapplied:
            if status != "needs_review" or "source_period_conflict" not in unresolved:
                raise ValueError(
                    "Conflicting offer dates must remain pending with source_period_conflict"
                )
        offer["review"].setdefault("original_reasons", original["review"]["reasons"])
        offer["review"].update(
            status=status,
            reviewer=item["reviewer"].strip(),
            reviewed_at=timestamp,
            notes=item["notes"],
            method=item["method"],
            reasons=["visual_review_unresolved", *unresolved]
            if status == "needs_review"
            else [],
            assessment={
                "source_image_inspected": True,
                "checked_fields": fields,
                "unresolved_fields": unresolved,
                "unapplied_fields": unapplied,
                "image_review": item.get("image_review"),
                "unrepresentable_source_basis": item.get(
                    "unrepresentable_source_basis"
                ),
            },
        )
        before = {
            key: original[key]
            for key in (
                "product",
                "price",
                "conditions",
                "valid_from",
                "valid_to",
                "review",
            )
            if original.get(key) != offer.get(key)
        }
        pending.append((offer, {"at": timestamp, "decision": item, "before": before}))
    if expected_offers is not None and (
        len(seen) != expected_offers or seen != set(known)
    ):
        raise ValueError("Complete review requires exactly every original offer ID")
    with database(root) as db:
        for offer, _ in pending:
            save_offer(db, offer)
    with (root / "review-audit.jsonl").open("a", encoding="utf-8") as stream:
        for _, event in pending:
            stream.write(json.dumps(event, ensure_ascii=False) + "\n")
    report = refresh_assessment_report(root, load_offers(root), batch_size=len(pending))
    return {**report, **export(root)}
