"""Local PP-OCRv4 price detection, with explicit typography evidence.

This is OCR, not a trained product association model. Inference is offline and
all resulting offers remain unreviewed. Model files ship in the pinned wheel.
"""

from __future__ import annotations

import hashlib
import importlib.metadata
import re
import threading
from pathlib import Path

from .offers import bbox, parse_price, extract_offers
from .source import normalized

LOCAL = threading.local()
VERSION = "hybrid-layout-v2"


def engine_info() -> dict:
    try:
        import rapidocr_onnxruntime
    except ImportError as error:
        raise RuntimeError(
            "Install tools/flyers/requirements-ocr.txt for the hybrid OCR engine"
        ) from error
    folder = Path(rapidocr_onnxruntime.__file__).parent / "models"
    return {
        "name": "RapidOCR / PP-OCRv4",
        "version": importlib.metadata.version("rapidocr_onnxruntime"),
        "models": {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(folder.glob("*.onnx"))
        },
        "region_detector": "connected-glyph-masks-v1",
        "maximum_regions": 400,
        "layout_version": VERSION,
    }


def recognize(source: Path) -> list[dict]:
    if not hasattr(LOCAL, "engine"):
        from rapidocr_onnxruntime import RapidOCR
        import onnxruntime

        onnxruntime.disable_telemetry_events()
        LOCAL.engine = RapidOCR(
            intra_op_num_threads=1,
            inter_op_num_threads=1,
            det_limit_side_len=960,
            max_side_len=4500,
            use_cls=False,
        )
    # Tesseract supplies captions and item codes. Connected glyphs locate large
    # price typography at original resolution; only those crops need the local
    # neural recognizer. This avoids a costly full-page neural detection pass.
    import cv2
    import numpy as np

    pixels = cv2.imread(str(source))
    if pixels is None:
        from PIL import Image

        pixels = np.asarray(Image.open(source).convert("RGB"))[:, :, ::-1].copy()
    selected = candidate_boxes(pixels)
    if not selected:
        return []
    crops = LOCAL.engine.get_crop_img_list(
        pixels, np.asarray(selected, dtype=np.float32)
    )
    recognized, _ = LOCAL.engine.text_rec(crops)
    rows = [
        (box, text, confidence)
        for box, (text, confidence) in zip(selected, recognized)
        if confidence >= 0.5
    ]
    lines = []
    for i, (points, text, confidence) in enumerate(rows or []):
        xs, ys = [p[0] for p in points], [p[1] for p in points]
        lines.append(
            {
                "text": text,
                "confidence": float(confidence) * 100,
                "x": round(min(xs)),
                "y": round(min(ys)),
                "w": round(max(xs) - min(xs)),
                "h": round(max(ys) - min(ys)),
                "line_id": "rapid:" + str(i),
            }
        )
    return lines


def candidate_boxes(bgr):
    import cv2

    cv2.setNumThreads(1)
    height, width = bgr.shape[:2]
    b, g, r = [bgr[:, :, i].astype("int16") for i in range(3)]
    masks = [
        (r > 120) & (r > g * 1.4) & (r > b * 1.4),
        (r > 210) & (g > 210) & (b > 210),
        (r < 90) & (g < 90) & (b < 90),
    ]
    boxes = []
    for mask in masks:
        _, _, stats, _ = cv2.connectedComponentsWithStats(
            mask.astype("uint8"), connectivity=8
        )
        glyphs = [
            s
            for s in stats[1:]
            if max(20, width * 0.012) <= s[3] <= width * 0.18
            and s[2] > 0.12 * s[3]
            and s[2] < 1.5 * s[3]
            and 0.12 <= s[4] / (s[2] * s[3]) <= 0.92
        ]
        parent = list(range(len(glyphs)))

        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        for i, a in enumerate(glyphs):
            for j in range(i + 1, len(glyphs)):
                other = glyphs[j]
                h = max(a[3], other[3])
                gap = max(0, a[0] - other[0] - other[2], other[0] - a[0] - a[2])
                if abs(a[1] - other[1]) < h * 0.35 and gap < min(a[3], other[3]) * 0.6:
                    parent[find(j)] = find(i)
        groups = {}
        for i, glyph in enumerate(glyphs):
            groups.setdefault(find(i), []).append(glyph)
        for group in groups.values():
            x, y = min(s[0] for s in group), min(s[1] for s in group)
            right, bottom = (
                max(s[0] + s[2] for s in group),
                max(s[1] + s[3] for s in group),
            )
            w, h = right - x, bottom - y
            if h < max(28, width * 0.02) or w / h > 6 or w < 10:
                continue
            x = max(0, int(x - h * 0.18))
            right = min(width, int(right + h * 0.1))
            y = max(0, int(y - 3))
            bottom = min(height, int(bottom + 3))
            box = [x, y, right - x, bottom - y]
            # Repeated masks can identify the same glyph group.
            if any(_overlap(box, old) > 0.75 for old in boxes):
                continue
            boxes.append(box)
    return [
        [[x, y], [x + w, y], [x + w, y + h], [x, y + h]] for x, y, w, h in boxes[:400]
    ]


def _overlap(a, b):
    x, y, w, h = a
    xx, yy, ww, hh = b
    area = max(0, min(x + w, xx + ww) - max(x, xx)) * max(
        0, min(y + h, yy + hh) - max(y, yy)
    )
    return area / max(1, min(w * h, ww * hh))


def raised_cents(source, box: list[int], digits: str) -> bool:
    """Require smaller, raised final two glyphs before inserting a decimal.

    This prevents a large '100' on a Halloween box from becoming a $1 offer.
    Recognition confidence alone says nothing about a missing decimal point.
    """
    import cv2

    x, y, w, h = box
    if len(digits) < 3 or h < 30:
        return False
    patch = source[max(0, y - 4) : y + h + 4, max(0, x - 4) : x + w + 4].astype("int16")
    if not patch.size:
        return False
    r, g, b = patch[:, :, 0], patch[:, :, 1], patch[:, :, 2]
    masks = [
        (r > 120) & (r > g * 1.4) & (r > b * 1.4),
        (r > 200) & (g > 200) & (b > 200),
        (r < 90) & (g < 90) & (b < 90),
    ]
    for mask in masks:
        _, _, stats, _ = cv2.connectedComponentsWithStats(
            mask.astype("uint8"), connectivity=8
        )
        components = [
            s
            for s in stats[1:]
            if s[4] > max(8, w * h * 0.006)
            and s[3] > h * 0.22
            and s[2] < w * 0.8
            and s[3] < h * 1.05
        ]
        components.sort(key=lambda s: s[0])
        if len(components) not in (len(digits), len(digits) + 1):
            continue
        # Currency signs may precede the dollar digits.
        components = components[-len(digits) :]
        dollars, cent_glyphs = components[:-2], components[-2:]
        height = max(s[3] for s in dollars)
        bottom = max(s[1] + s[3] for s in dollars)
        if all(
            0.3 * height <= s[3] <= 0.85 * height
            and s[1] + s[3] < bottom - 0.1 * height
            for s in cent_glyphs
        ):
            return True
    return False


def price_anchors(lines: list[dict], source: Path, width: int) -> list[dict]:
    from PIL import Image
    import numpy as np

    pixels = np.asarray(Image.open(source).convert("RGB"))
    anchors, used = [], set()
    # Some recognitions separate a large '2' from two raised '99' glyphs.
    for i, dollar in enumerate(lines):
        if (
            i in used
            or not re.fullmatch(r"\$?\d{1,2}", dollar["text"].strip())
            or dollar["h"] < width * 0.02
        ):
            continue
        options = []
        for j, cent in enumerate(lines):
            gap = cent["x"] - dollar["x"] - dollar["w"]
            if j in used or i == j or not re.fullmatch(r"\d{2}", cent["text"].strip()):
                continue
            if (
                -0.4 * dollar["w"] <= gap <= dollar["h"] * 0.5
                and abs(cent["y"] - dollar["y"]) < dollar["h"] * 0.45
                and cent["h"] < dollar["h"] * 0.85
            ):
                options.append((abs(gap), j, cent))
        if options:
            _, j, cent = min(options)
            raw = dollar["text"].strip().lstrip("$") + "." + cent["text"].strip()
            price = parse_price(raw)
            if price:
                price["flags"].append("split_price_reconstructed")
                anchors.append(
                    {
                        "box": bbox([dollar, cent]),
                        "price": price,
                        "words": [dollar, cent],
                    }
                )
                used.update((i, j))
    for i, line in enumerate(lines):
        if i in used:
            continue
        raw = line["text"].strip().replace("＄", "$")
        original_raw = raw
        raw = re.sub(r"^(\$?\s*)[.,](\d{2})(?!\d)", r"\g<1>0.\2", raw)
        price = None
        # Only a complete price expression, never a product line with numbers.
        explicit = re.fullmatch(
            r"(?:(?:save|reg\.?|was)\s*)?(?:\d{1,2}\s*(?:for|pour|/)\s*)?(?:\$\s*)?\d{1,4}(?:[.,]\d{2})?\s*(?:[$¢]|cents?)?(?:\s*(?:/|per)\s*(?:lb|kg|100g|100ml|l|ea|each))?",
            raw,
            re.I,
        )
        if not explicit or line["confidence"] < 65:
            continue
        digits = re.sub(r"[^0-9]", "", raw)
        integer = re.fullmatch(r"\$?\s*\d{3,4}", raw)
        if integer:
            if line["h"] < width * 0.02 or not raised_cents(
                pixels, [line[k] for k in ("x", "y", "w", "h")], digits
            ):
                continue
            price = parse_price(digits[:-2] + "." + digits[-2:])
            price["raw"] = raw
            price["flags"].append("decimal_reconstructed_from_glyph_geometry")
        elif re.fullmatch(r"\d{1,2}", raw):
            # A bare '97' could be cents, a percentage or a package count.
            continue
        else:
            price = parse_price(raw)
        if price and line["h"] >= max(16, width * 0.009):
            if original_raw != raw:
                price["raw"] = original_raw
                price["flags"].append("leading_decimal_normalized")
            anchors.append(
                {
                    "box": [line[k] for k in ("x", "y", "w", "h")],
                    "price": price,
                    "words": [line],
                }
            )
    return sorted(anchors, key=lambda a: (a["box"][1], a["box"][0]))


def _distance(a, b):
    x, y, w, h = a
    xx, yy, ww, hh = b
    return max(0, x - xx - ww, xx - x - w) ** 2 + max(0, y - yy - hh, yy - y - h) ** 2


def caption_offers(words, lines, flyer, page, source, version):
    """Retailer item codes ground captions; geometry alone stays unverified.

    The layout engine keeps the raw OCR transcript even when a clean caption
    cannot be established. It never silently promotes a proposal to a deal.
    """
    from collections import defaultdict

    word_lines = defaultdict(list)
    for word in words:
        word_lines[word["line_id"]].append(word)
    groups = []
    for group in word_lines.values():
        group.sort(key=lambda w: w["x"])
        current = []
        for word in group:
            if (
                current
                and word["x"] - current[-1]["x"] - current[-1]["w"]
                > max(word["h"], current[-1]["h"]) * 3
            ):
                groups.append(current)
                current = []
            current.append(word)
        if current:
            groups.append(current)
    # Preserve small labels, source item codes, and explicit decimal prices
    # without invoking the neural recognizer on every word in the page.
    combined = list(lines)
    for group in groups:
        box = bbox(group)
        x, y, w, h = box
        overlap = any(
            _distance(box, [line[k] for k in ("x", "y", "w", "h")]) == 0
            and x + w / 2 >= line["x"]
            and x + w / 2 <= line["x"] + line["w"]
            and y + h / 2 >= line["y"]
            and y + h / 2 <= line["y"] + line["h"]
            for line in lines
        )
        if not overlap:
            combined.append(
                {
                    "text": " ".join(word["text"] for word in group),
                    "confidence": sum(word["confidence"] for word in group)
                    / len(group),
                    "x": x,
                    "y": y,
                    "w": w,
                    "h": h,
                    "line_id": "tesseract:" + group[0]["line_id"],
                }
            )
    lines = combined
    anchors = price_anchors(lines, source, page["width"])
    blocks = []
    for sku in lines:
        if not re.search(r"\d{7,}(?:[_ /]|$)", sku["text"]):
            continue
        selected = []
        for group in groups:
            x, y, w, h = bbox(group)
            if (
                abs(x - sku["x"]) < page["width"] * 0.025
                and sku["y"] - max(100, page["width"] * 0.075) <= y < sku["y"]
                and h < page["width"] * 0.025
            ):
                selected.append(group)
        if not selected:
            continue
        selected.sort(key=lambda g: bbox(g)[1], reverse=True)
        contiguous = []
        previous = sku["y"]
        for group in selected:
            box = bbox(group)
            if previous - box[1] - box[3] > max(box[3] * 2, 20):
                break
            contiguous.append(group)
            previous = box[1]
        if contiguous:
            blocks.append(
                {
                    "words": [w for g in reversed(contiguous) for w in g],
                    "box": bbox([w for g in contiguous for w in g]),
                    "sku": sku["text"],
                }
            )
    # Price qualifiers are read independently from captions. In particular,
    # 'Member Save $1' is a saving, not the item's member checkout price.
    for anchor in anchors:
        x, y, w, h = anchor["box"]
        labels = [
            line["text"]
            for line in lines
            if _distance([x, y, w, h], [line[k] for k in ("x", "y", "w", "h")])
            < (max(30, h * 0.8)) ** 2
            and line["y"] < y + h * 0.4
            and not any(c.isdigit() for c in line["text"])
        ]
        joined = normalized(" ".join(labels)).replace(" ", "")
        if "membersave" in joined:
            anchor["price"]["kind"] = "savings"
        if "nonmember" not in joined and any(
            t in joined for t in ("memberprice", "app exclusive", "apexclusive")
        ):
            anchor["price"]["requires_membership"] = True
        # Short basis text is often inside the price detector's rotated box.
        nearby = [
            line
            for line in lines
            if _distance(anchor["box"], [line[k] for k in ("x", "y", "w", "h")])
            < max(15, h * 0.3) ** 2
        ]
        if any(normalized(line["text"]) in ("lb", "lbs") for line in nearby):
            anchor["price"]["basis"] = "lb"
        elif any(normalized(line["text"]) == "kg" for line in nearby):
            anchor["price"]["basis"] = "kg"
    # A matching printed /kg comparison and a weight-sold item code provide
    # evidence for a missing /lb marker. Keep that reconstruction visible.
    for comparison in anchors:
        if comparison["price"]["basis"] != "kg":
            continue
        weight_blocks = [
            b
            for b in blocks
            if "_KG" in b["sku"].upper()
            and _distance(comparison["box"], b["box"]) < (page["width"] * 0.1) ** 2
        ]
        for other in anchors:
            if other is comparison or other["price"]["basis"] != "each":
                continue
            if (
                abs(
                    other["price"]["amount_cents"] * 2.20462262
                    - comparison["price"]["amount_cents"]
                )
                > 2
            ):
                continue
            if any(
                _distance(other["box"], b["box"]) < (page["width"] * 0.23) ** 2
                for b in weight_blocks
            ):
                other["price"]["basis"] = "lb"
                other["price"]["flags"].append(
                    "weight_basis_reconstructed_from_printed_comparison"
                )
    # A printed comparison/kg belongs to the same item as its much larger
    # sale/lb anchor, and must not steal that item's caption.
    filtered = []
    for anchor in anchors:
        p = anchor["price"]
        equivalent = []
        if p["basis"] == "kg":
            equivalent = [
                other
                for other in anchors
                if other is not anchor
                and other["price"]["basis"] == "lb"
                and abs(other["price"]["amount_cents"] * 2.20462262 - p["amount_cents"])
                <= 2
                and _distance(anchor["box"], other["box"]) < (page["width"] * 0.25) ** 2
            ]
        if equivalent:
            equivalent[0].setdefault("comparison_prices", []).append(p)
        else:
            filtered.append(anchor)
    anchors = filtered
    proposals = []
    for anchor in anchors:
        x, y, w, h = anchor["box"]

        def association_cost(block):
            bx, by, bw, bh = block["box"]
            horizontal = (x + w / 2 - (bx + page["width"] * 0.08)) ** 2 * 0.3
            above = (page["width"] * 0.12) ** 2 if by + bh < y + h * 0.5 else 0
            return _distance(anchor["box"], block["box"]) + horizontal + above

        options = sorted(
            ((association_cost(block), i) for i, block in enumerate(blocks))
        )
        if options and options[0][0] < (page["width"] * 0.23) ** 2:
            block = blocks[options[0][1]]
            rows = extract_offers(
                block["words"], flyer, page, version, anchors=[anchor]
            )
            for row in rows:
                row["product"]["source_item_code"] = block["sku"]
                if "_KG" in block["sku"].upper() and row["price"]["basis"] == "each":
                    row["price"]["flags"].append("weight_basis_unresolved")
                    row["review"]["reasons"].append("weight_basis_unresolved")
                row["evidence"]["caption_bbox_px"] = block["box"]
                row["evidence"]["association_method"] = (
                    "source_item_code_caption_geometry"
                )
                if len(options) > 1 and options[1][0] < options[0][0] * 1.5 + 100:
                    row["review"]["reasons"].append("competing_source_captions")
                row["evidence"]["comparison_prices"] = anchor.get(
                    "comparison_prices", []
                )
                # Rebuild a caption from the contiguous SKU block, not distant
                # packaging, headers, price badges, or the neighbouring tile.
                names = []
                for group in groups:
                    if not all(word in block["words"] for word in group):
                        continue
                    text = " ".join(word["text"] for word in group)
                    letters = [c for c in text if c.isalpha()]
                    upper = sum(c.isupper() for c in letters) / max(1, len(letters))
                    if (
                        upper >= 0.7
                        and len(letters) > 3
                        and not re.search(
                            r"\b(?:selected|varieties|product of|ea|kg|lb|frozen|monday|tuesday|wednesday|thursday|friday|saturday|sunday|october)\b",
                            normalized(text),
                        )
                    ):
                        names.append((bbox(group)[1], text))
                if names:
                    from .offers import product_tokens

                    row["product"]["name"] = " ".join(text for _, text in sorted(names))
                    row["product"]["canonical_tokens"] = product_tokens(
                        row["product"]["name"]
                    )
                proposals.append(row)
        else:
            rows = extract_offers(words, flyer, page, version, anchors=[anchor])
            for row in rows:
                row["review"]["reasons"].append(
                    "caption_not_grounded_in_source_item_code"
                )
                row["evidence"]["association_method"] = "unverified_nearest_text"
                proposals.append(row)
    return proposals
