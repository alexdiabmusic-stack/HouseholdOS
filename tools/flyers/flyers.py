#!/usr/bin/env python3
"""Download, OCR, review and match Canadian grocery flyers without Firecrawl."""
from __future__ import annotations

import argparse
import json
import logging
import sys
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from flyerkit.download import download_flyers
from flyerkit.offers import match_offer
from flyerkit.pipeline import apply_reviews, export, extract, load_offers
from flyerkit.source import PROVINCES, STORES


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("data/flyers"))
    parser.add_argument("--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("download", "run"):
        p = sub.add_parser(name)
        p.add_argument("--store", action="append", choices=sorted(STORES), help="Repeat to select stores; default is all configured grocery banners")
        p.add_argument("--province", action="append", choices=sorted(PROVINCES), help="Default: all Canadian editions, grouped by published region")
        p.add_argument("--as-of", type=date.fromisoformat, default=datetime.now(ZoneInfo("America/Toronto")).date())
        p.add_argument("--include-expired", action="store_true")
        p.add_argument("--flyer-url", action="append", default=[], help="Explicit detail URLs instead of site-index discovery")
        p.add_argument("--allow-image-host", action="append", default=[])
        p.add_argument("--delay", type=float, default=1.5)
        p.add_argument("--max-indexes", type=int, default=250)
    for p in (sub.choices["run"], sub.add_parser("extract")):
        p.add_argument("--languages", default="eng+fra")
        p.add_argument("--tessdata-dir")
        p.add_argument("--workers", type=int, default=2)
    sub.add_parser("export")
    p = sub.add_parser("review")
    p.add_argument("decisions", type=Path, help="JSONL human-reviewed decisions; see README")
    p = sub.add_parser("match")
    p.add_argument("query")
    p.add_argument("--province", choices=sorted(PROVINCES), required=True)
    p.add_argument("--city")
    p.add_argument("--on", type=date.fromisoformat, default=datetime.now(ZoneInfo("America/Toronto")).date())
    p.add_argument("--include-unreviewed", action="store_true", help="Development only: include explicitly labeled uncertain OCR proposals")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING, format="%(levelname)s %(message)s")
    try:
        status = 0
        if args.command in ("download", "run"):
            report = download_flyers(args.root, stores=set(args.store or STORES), as_of=args.as_of,
                provinces=set(args.province or []), include_expired=args.include_expired, flyer_urls=args.flyer_url,
                delay=args.delay, image_hosts=args.allow_image_host, max_indexes=args.max_indexes)
            print(json.dumps({k: report[k] for k in ("status", "flyer_count", "image_count", "stores_without_downloads", "errors")}, indent=2))
            status = 0 if report["status"] == "complete" else 2
            if report["status"] == "blocked": return 2
        if args.command in ("run", "extract"):
            report = extract(args.root, languages=args.languages, tessdata_dir=args.tessdata_dir, workers=args.workers)
            print(json.dumps({k: report[k] for k in ("status", "offer_count", "errors")}, indent=2))
            if report["status"] != "complete": status = 2
        elif args.command == "export":
            print(json.dumps(export(args.root), indent=2))
        elif args.command == "review":
            print(json.dumps(apply_reviews(args.root, args.decisions), indent=2))
        elif args.command == "match":
            matches = [m for o in load_offers(args.root) if (m := match_offer(o, args.query, on=args.on.isoformat(),
                       province=args.province, city=args.city, include_unreviewed=args.include_unreviewed))]
            print(json.dumps(matches, ensure_ascii=False, indent=2))
        return status
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(json.dumps({"status": "error", "error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
