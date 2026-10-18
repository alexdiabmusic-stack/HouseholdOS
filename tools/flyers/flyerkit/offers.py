"""Conservative OCR price proposals. Heuristic association is never called verification."""
from __future__ import annotations

import csv
import io
import re
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP

from .source import normalized, stable_id

MONEY = r"\d{1,4}[.,]\d{2}"
STOP_WORDS = {"a", "an", "the", "of", "and", "or", "for", "to", "de", "des", "du", "et", "ou", "les", "le", "la", "un", "une"}
NON_PRODUCT = {"save", "savings", "regular", "reg", "was", "now", "only", "each", "ea", "lb", "kg", "g", "ml", "l", "for", "buy", "get", "off", "price", "member", "members", "points", "scene", "optimum", "limit", "selected", "varieties", "assorted", "sur", "prix", "ch", "rabais", "economisez", "page", "flyer"}
ALIASES = {
    "strawberry": "strawberries", "fraise": "strawberries", "fraises": "strawberries",
    "blueberry": "blueberries", "bleuet": "blueberries", "bleuets": "blueberries",
    "raspberry": "raspberries", "framboise": "raspberries", "framboises": "raspberries",
    "banana": "bananas", "banane": "bananas", "bananes": "bananas",
    "pomme": "apples", "pommes": "apples", "apple": "apples",
    "potato": "potatoes", "patate": "potatoes", "patates": "potatoes",
    "tomato": "tomatoes", "tomate": "tomatoes", "tomates": "tomatoes",
    "milk": "milk", "lait": "milk", "egg": "eggs", "oeuf": "eggs", "oeufs": "eggs",
    "butter": "butter", "beurre": "butter", "chicken": "chicken", "poulet": "chicken",
}


def cents(text: str) -> int:
    return int((Decimal(text.replace(",", ".")) * 100).to_integral_exact())


def parse_price(text: str) -> dict | None:
    """Preserve advertised basket amount, count and qualification; no float prices."""
    raw = re.sub(r"\s+", " ", text).strip()
    norm = raw.lower().replace("＄", "$")
    price = {"currency": "CAD", "raw": raw, "amount_cents": None, "purchase_quantity": 1,
             "kind": "sale", "basis": "each", "requires_membership": False, "flags": []}
    if re.search(r"\b(?:save|savings|off|economisez|rabais)\b", normalized(raw)):
        price["kind"] = "savings"
    elif re.search(r"\b(?:was|reg|regular|regulier)\b", normalized(raw)):
        price["kind"] = "regular"
    if re.search(r"\b(?:from|starting|a partir|up to|jusqu)\b", normalized(raw)):
        price["flags"].append("qualified_price")
    multi = re.search(rf"\b(\d{{1,2}})\s*(?:/|for|pour)\s*\$?\s*({MONEY}|\d{{1,3}})(?![\d.,])", norm)
    amount = re.search(rf"(?:\$\s*({MONEY}|\d{{1,4}})(?![\d.,])|(?<![\d.,])({MONEY})(?![\d.,])\s*\$?)", norm)
    cent_price = re.search(r"(?<!\d)(\d{1,3})\s*(?:¢|cents?|[cC]\b)", norm)
    if multi:
        count = int(multi[1])
        if count < 2:
            return None
        price.update(amount_cents=cents(multi[2]), purchase_quantity=count, kind="multibuy")
        price["flags"].append("multibuy_single_unit_price_unknown")
    elif cent_price:
        price["amount_cents"] = int(cent_price[1])
    elif amount:
        price["amount_cents"] = cents(amount[1] or amount[2])
    else:
        return None
    if price["amount_cents"] is None or not 0 < price["amount_cents"] <= 500_000:
        return None
    if re.search(r"(?:/|per\s+)\s*(?:lb|lbs|livre)\b", norm):
        price["basis"] = "lb"
    elif re.search(r"(?:/|per\s+)\s*kg\b", norm):
        price["basis"] = "kg"
    elif re.search(r"(?:/|per\s+)\s*100\s*g\b", norm):
        price["basis"] = "100g"
    elif re.search(r"(?:/|per\s+)\s*100\s*ml\b", norm):
        price["basis"] = "100ml"
    elif re.search(r"(?:/|per\s+)\s*l\b", norm):
        price["basis"] = "L"
    price["requires_membership"] = bool(re.search(r"\b(?:member|members|scene|optimum|carte|membre|membres)\b", normalized(raw)))
    if price["requires_membership"]: price["flags"].append("membership_condition")
    if re.search(r"\b(?:when you buy|must buy|minimum|a l achat)\b", normalized(raw)):
        price["flags"].append("minimum_purchase_condition")
    return price


def parse_size(text: str) -> dict:
    # Ounce and fluid-ounce conversions are intentionally not equated.
    out = {"raw": None, "quantity": None, "unit": None, "pack_count": 1, "total_base_quantity": None,
           "base_unit": None, "ambiguous": False}
    pattern = r"(?<![\d.,])(?:(\d{1,2})\s*[x×]\s*)?(\d+(?:[.,]\d+)?)\s*(kg|g|mg|ml|mL|litres?|liters?|l|lb|lbs|oz|fl\s*oz)\b"
    matches = list(re.finditer(pattern, text, re.I))
    # '/kg' is a price basis, not a package size. Multiple sizes are alternatives, not one pack.
    matches = [m for m in matches if not re.search(r"[/]\s*$", text[max(0, m.start()-4):m.start()])]
    if not matches:
        return out
    if len(matches) != 1:
        out.update(raw="; ".join(m[0] for m in matches), ambiguous=True)
        return out
    m = matches[0]
    count, value, unit = int(m[1] or 1), Decimal(m[2].replace(",", ".")), m[3].lower()
    if count <= 0 or value <= 0:
        return out
    # A range '350-400 g' is not an exact 400 g package.
    prefix = text[max(0, m.start()-15):m.start()]
    suffix = text[m.end():m.end()+20]
    if re.search(r"\d\s*(?:[-–/à]|or|ou|to|au)\s*$", prefix, re.I) or re.match(r"\s*(?:to|au|[-–])\s*\d", suffix, re.I):
        out.update(raw=m[0], ambiguous=True)
        return out
    conversion = {"kg": (1000, "g"), "g": (1, "g"), "mg": (Decimal("0.001"), "g"),
                  "ml": (1, "ml"), "l": (1000, "ml"), "litre": (1000, "ml"), "litres": (1000, "ml"),
                  "liter": (1000, "ml"), "liters": (1000, "ml"), "lb": (Decimal("453.59237"), "g"),
                  "lbs": (Decimal("453.59237"), "g"), "oz": (Decimal("28.349523125"), "g")}
    out.update(raw=m[0], quantity=str(value), unit=unit, pack_count=count)
    if unit in conversion:
        factor, base = conversion[unit]
        out.update(total_base_quantity=str(value * count * factor), base_unit=base)
    return out


def unit_price(price: dict, size: dict) -> dict | None:
    """Comparison amount per kg or L, preserving fractional cents as decimal strings."""
    amount = Decimal(price["amount_cents"]) / Decimal(price["purchase_quantity"])
    basis = price["basis"]
    factor = {"lb": (Decimal(1000) / Decimal("453.59237"), "kg"), "kg": (Decimal(1), "kg"),
              "100g": (Decimal(10), "kg"), "100ml": (Decimal(10), "L"), "L": (Decimal(1), "L")}
    if basis in factor:
        multiplier, unit = factor[basis]
    elif size.get("total_base_quantity") and not size.get("ambiguous"):
        multiplier = Decimal(1000) / Decimal(size["total_base_quantity"])
        unit = "kg" if size["base_unit"] == "g" else "L"
    else:
        return None
    return {"amount_cents_decimal": str((amount * multiplier).quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)), "per": unit}


def parse_tsv(text: str) -> list[dict]:
    words = []
    for row in csv.DictReader(io.StringIO(text), delimiter="\t"):
        if row.get("level") != "5" or not row.get("text", "").strip():
            continue
        try:
            words.append({"text": row["text"], "confidence": float(row["conf"]),
                          "x": int(row["left"]), "y": int(row["top"]), "w": int(row["width"]), "h": int(row["height"]),
                          "line_id": ":".join(row[k] for k in ("page_num", "block_num", "par_num", "line_num"))})
        except (ValueError, KeyError):
            continue
    return words


def bbox(words: list[dict]) -> list[int]:
    left, top = min(w["x"] for w in words), min(w["y"] for w in words)
    return [left, top, max(w["x"] + w["w"] for w in words)-left, max(w["y"] + w["h"] for w in words)-top]


def _price_anchors(words: list[dict]) -> list[dict]:
    """Use contiguous OCR word spans; do not join unrelated prices across a whole row."""
    anchors, consumed = [], set()
    # Reconstruct raised cents before standalone cents can consume that word.
    for dollar in words:
        if id(dollar) in consumed or not re.fullmatch(r"\$?\d{1,2}", dollar["text"]):
            continue
        for small in words:
            if id(small) in consumed or small is dollar or not re.fullmatch(r"\d{2}¢?", small["text"]):
                continue
            gap = small["x"] - dollar["x"] - dollar["w"]
            if 0 <= gap <= dollar["h"] * .6 and abs(small["y"]-dollar["y"]) < dollar["h"] * .6 and small["h"] < dollar["h"] * .8:
                p = parse_price(dollar["text"].lstrip("$") + "." + small["text"].rstrip("¢"))
                if p:
                    p["raw"] = dollar["text"] + " [raised cents] " + small["text"]
                    p["flags"].append("split_price_reconstructed")
                    anchors.append({"box": bbox([dollar, small]), "price": p, "words": [dollar, small]})
                    consumed.update([id(dollar), id(small)])
                    break
    lines = defaultdict(list)
    for w in words:
        if id(w) not in consumed: lines[w["line_id"]].append(w)
    for line in lines.values():
        line.sort(key=lambda w: w["x"])
        i = 0
        while i < len(line):
            best = None
            for count in range(1, min(7, len(line)-i) + 1):
                chunk = line[i:i+count]
                token = chunk[-1]["text"]
                if not re.fullmatch(r"(?:[$\d.,/¢]+|cents?|for|pour|per|each|ea\.?|ch\.?|kg|lbs?|g|ml|l|save|off|reg\.?|regular|was|from|only|member|members)", token, re.I):
                    break
                if best and normalized(token) in {"save", "was", "reg", "regular", "from", "only", "member", "members"}:
                    break
                if any(b["x"] - (a["x"]+a["w"]) > max(a["h"], b["h"]) * 2.5 for a, b in zip(chunk, chunk[1:])):
                    break
                raw = " ".join(w["text"] for w in chunk)
                # A candidate starts at a price-like word or a known price qualifier.
                if not re.match(r"^(?:[$\d]|save\b|was\b|reg\b|from\b|only\b|member\b)", raw, re.I):
                    continue
                p = parse_price(raw)
                if p:
                    if best and len(re.findall(MONEY, raw)) > 1:
                        break
                    best = (chunk, p)
            if best:
                chunk, p = best
                # Include price-basis/condition words but keep the anchor's source span for auditing.
                anchors.append({"box": bbox(chunk), "price": p, "words": chunk})
                consumed.update(id(w) for w in chunk)
                i += len(chunk)
            else:
                i += 1
    return anchors


def extract_offers(words: list[dict], flyer: dict, page: dict, ocr_engine: str) -> list[dict]:
    anchors = _price_anchors(words)
    width, height = page["width"], page["height"]
    price_word_ids = {id(w) for a in anchors for w in a["words"]}
    lines = defaultdict(list)
    for w in words:
        if id(w) not in price_word_ids: lines[w["line_id"]].append(w)
    associations = defaultdict(list)
    for line in lines.values():
        line.sort(key=lambda w: w["x"])
        box = bbox(line)
        # Split Tesseract lines when they span large gutters between product tiles.
        groups, current = [], []
        for w in line:
            if current and w["x"] - current[-1]["x"] - current[-1]["w"] > max(w["h"], current[-1]["h"]) * 3:
                groups.append(current); current = []
            current.append(w)
        if current: groups.append(current)
        for group in groups:
            box = bbox(group)
            cx, cy = (box[0]+box[2]/2)/width, (box[1]+box[3]/2)/height
            distances = []
            for i, anchor in enumerate(anchors):
                x, y, w, h = anchor["box"]
                dx, dy = cx-(x+w/2)/width, cy-(y+h/2)/height
                if abs(dx) < .22 and abs(dy) < .14:
                    distances.append((dx*dx + 2*dy*dy, i))
            if distances:
                distances.sort()
                ambiguous = len(distances) > 1 and distances[1][0] < distances[0][0] * 1.5 + .0002
                associations[distances[0][1]].append((group, ambiguous))
    result = []
    for i, anchor in enumerate(anchors):
        assigned = associations[i]
        assigned.sort(key=lambda x: (min(w["y"] for w in x[0]), min(w["x"] for w in x[0])))
        context = "\n".join(" ".join(w["text"] for w in group) for group, _ in assigned)
        name_lines = []
        for group, _ in assigned:
            text = " ".join(w["text"] for w in group)
            tokens = normalized(text).split()
            meaningful = [t for t in tokens if len(t) > 2 and t not in NON_PRODUCT and t not in STOP_WORDS and not t.isdigit()]
            if meaningful and not re.search(r"\b(?:www|copyright|conditions apply|terms apply|valid from|offer ends|points|pc optimum|scene)\b", normalized(text)):
                name_lines.append(text)
        name = " ".join(name_lines)[:500] or None
        reasons = ["ocr_product_price_association_unverified", *flyer.get("warnings", [])]
        if not name: reasons.append("product_unresolved")
        if any(ambiguous for _, ambiguous in assigned): reasons.append("nearby_competing_prices")
        price = anchor["price"]
        # Conditions near an amount are kept separately; don't turn savings into a checkout price.
        conditions = [line for line in context.splitlines() if re.search(r"\b(?:limit|member|scene|optimum|when you buy|selected|assorted|raincheck|while supplies|minimum|membre|limite|varietes)\b", normalized(line))]
        restricted = [line for line in context.splitlines() if re.search(r"\b(?:weekend|friday|saturday|sunday|monday|tuesday|wednesday|thursday|vendredi|samedi|dimanche|lundi|mardi|mercredi|jeudi|days only|jours seulement)\b", normalized(line))]
        if restricted:
            reasons.append("restricted_validity_unresolved")
            conditions.extend(restricted)
        if any(re.search(r"\b(?:member|scene|optimum|membre)\b", normalized(c)) for c in conditions):
            price["requires_membership"] = True
            reasons.append("membership_condition")
        size = parse_size(context)
        if size["ambiguous"]: reasons.append("package_size_ambiguous")
        if price["kind"] in ("regular", "savings"): reasons.append("not_a_sale_price")
        if price["flags"]: reasons.extend(price["flags"])
        confidence = min((w["confidence"] for w in anchor["words"]), default=0)
        if confidence < 80: reasons.append("low_price_ocr_confidence")
        box = anchor["box"]
        result.append({"schema_version": 1, "offer_id": stable_id(flyer["flyer_id"], page["sha256"], str(box), price["raw"]),
                       "flyer_id": flyer["flyer_id"], "retailer_id": flyer["retailer_id"], "retailer_name": flyer["retailer_name"],
                       "geography": flyer["geography"], "valid_from": flyer["valid_from"], "valid_to": flyer["valid_to"],
                       "flyer_valid_from": flyer["valid_from"], "flyer_valid_to": flyer["valid_to"],
                       "product": {"name": name, "canonical_tokens": product_tokens(name or ""), "brand": None,
                                   "size": size, "details_raw": context}, "price": price,
                       "unit_price": unit_price(price, size), "conditions": conditions,
                       "review": {"status": "needs_review", "reasons": sorted(set(reasons)), "reviewer": None},
                       "evidence": {"source_url": flyer["source_url"], "source_image_url": page["source_image_url"],
                                    "image_path": page["path"], "image_sha256": page["sha256"], "page_number": page["page_number"],
                                    "price_bbox_px": box, "price_bbox_normalized": [round(box[0]/width, 6), round(box[1]/height, 6), round(box[2]/width, 6), round(box[3]/height, 6)],
                                    "ocr_engine": ocr_engine, "ocr_price_confidence": confidence,
                                    "retrieved_at": flyer["retrieved_at"]}})
    return result


def product_tokens(text: str) -> list[str]:
    return sorted({ALIASES.get(t, t) for t in normalized(text).split()
                   if t not in STOP_WORDS and not t.isdigit() and len(t) > 1})


def match_offer(offer: dict, query: str, *, on: str, province: str, city: str | None = None,
                include_unreviewed=False) -> dict | None:
    if offer["review"]["status"] != "validated" and not include_unreviewed:
        return None
    if offer["review"]["status"] == "rejected" or offer["price"]["kind"] not in ("sale", "multibuy"):
        return None
    if not offer.get("valid_from") or not offer.get("valid_to") or not offer["valid_from"] <= on <= offer["valid_to"]:
        return None
    geo = offer["geography"]
    if province not in geo["provinces"] and geo["scope"] != "national":
        return None
    if geo["cities"] and (not city or normalized(city) not in {normalized(c) for c in geo["cities"]}):
        return None
    requested_size = parse_size(query)
    actual_size = offer["product"]["size"]
    query_without_size = query.replace(requested_size["raw"], "") if requested_size["raw"] else query
    query_tokens = set(product_tokens(query_without_size))
    offered_tokens = set(offer["product"]["canonical_tokens"])
    # A query's brand and modifiers must all match: organic, lactose-free, etc. are not discarded.
    if not query_tokens or not query_tokens.issubset(offered_tokens):
        return None
    if requested_size["total_base_quantity"] and (requested_size["base_unit"] != actual_size.get("base_unit") or
        not actual_size.get("total_base_quantity") or Decimal(requested_size["total_base_quantity"]) != Decimal(actual_size["total_base_quantity"])):
        return None
    return {"offer_id": offer["offer_id"], "retailer": offer["retailer_name"], "product": offer["product"]["name"],
            "price": offer["price"], "size": actual_size, "unit_price": offer["unit_price"],
            "valid_from": offer["valid_from"], "valid_to": offer["valid_to"], "geography": geo,
            "review": offer["review"], "evidence": offer["evidence"],
            "match": {"method": "explicit_token_aliases", "tokens": sorted(query_tokens),
                      "location_basis": "published_city" if geo["cities"] else "province_wide" if geo["provinces"] else "national"}}
