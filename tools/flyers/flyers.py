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
    for name in ("discover", "download", "run"):
        p = sub.add_parser(name)
        p.add_argument(
            "--store",
            action="append",
            choices=sorted(STORES),
            help="Repeat to select stores; default is all configured grocery banners",
        )
        p.add_argument(
            "--province",
            action="append",
            choices=sorted(PROVINCES),
            help="Default: all Canadian editions, grouped by published region",
        )
        p.add_argument(
            "--as-of",
            type=date.fromisoformat,
            default=datetime.now(ZoneInfo("America/Toronto")).date(),
        )
        p.add_argument("--include-expired", action="store_true")
        p.add_argument(
            "--flyer-url",
            action="append",
            default=[],
            help="Explicit detail URLs instead of site-index discovery",
        )
        p.add_argument("--allow-image-host", action="append", default=[])
        p.add_argument("--delay", type=float, default=1.5)
        p.add_argument("--max-indexes", type=int, default=250)
        p.add_argument(
            "--max-flyers", type=int, help="Explicit partial sample; omitted by default"
        )
        p.add_argument(
            "--max-pages-per-flyer",
            type=int,
            help="Explicit partial sample; omitted by default",
        )
    for p in (sub.choices["run"], sub.add_parser("extract")):
        p.add_argument("--languages", default="eng+fra")
        p.add_argument("--tessdata-dir")
        p.add_argument("--workers", type=int, default=2)
        p.add_argument(
            "--engine",
            choices=["hybrid", "tesseract"],
            default="hybrid",
            help="Both engines run locally; hybrid adds PP-OCRv4 price recognition",
        )
        if p is not sub.choices["run"]:
            p.add_argument("--store", action="append", choices=sorted(STORES))
        p.add_argument(
            "--max-pages",
            type=int,
            help="Explicit OCR sample limit; status remains partial",
        )
    sub.add_parser("export")
    sub.add_parser("audit")
    p = sub.add_parser("benchmark")
    p.add_argument("labels", type=Path)
    p.add_argument(
        "--offers", type=Path, help="A saved pre-review offers.jsonl snapshot"
    )
    p = sub.add_parser("serve", help="Serve the offline review UI on this machine only")
    p.add_argument("--port", type=int, default=8765)
    p = sub.add_parser("review")
    p.add_argument(
        "decisions", type=Path, help="JSONL human-reviewed decisions; see README"
    )
    p = sub.add_parser("review-source")
    p.add_argument(
        "decisions",
        type=Path,
        help="JSONL source metadata decisions bound to a flyer image SHA256",
    )
    p = sub.add_parser("match")
    p.add_argument("query")
    p.add_argument("--province", choices=sorted(PROVINCES), required=True)
    p.add_argument("--city")
    p.add_argument(
        "--region",
        help="Explicit published regional edition, such as West; never inferred from a province",
    )
    p.add_argument(
        "--on",
        type=date.fromisoformat,
        default=datetime.now(ZoneInfo("America/Toronto")).date(),
    )
    p.add_argument(
        "--include-unreviewed",
        action="store_true",
        help="Development only: include explicitly labeled uncertain OCR proposals",
    )
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(levelname)s %(message)s",
    )
    try:
        status = 0
        if args.command in ("discover", "download", "run"):
            if (
                args.max_indexes < 1
                or (args.max_flyers is not None and args.max_flyers < 1)
                or (
                    args.max_pages_per_flyer is not None
                    and args.max_pages_per_flyer < 1
                )
            ):
                raise ValueError("Discovery and sample limits must be positive")
            report = download_flyers(
                args.root,
                stores=set(args.store or STORES),
                as_of=args.as_of,
                provinces=set(args.province or []),
                include_expired=args.include_expired,
                flyer_urls=args.flyer_url,
                delay=args.delay,
                image_hosts=args.allow_image_host,
                max_indexes=args.max_indexes,
                discover_only=args.command == "discover",
                max_flyers=args.max_flyers,
                max_pages_per_flyer=args.max_pages_per_flyer,
            )
            keys = (
                ("status", "candidate_count", "stores_without_listings", "errors")
                if args.command == "discover"
                else (
                    "status",
                    "flyer_count",
                    "image_count",
                    "stores_without_downloads",
                    "errors",
                )
            )
            print(json.dumps({k: report.get(k) for k in keys}, indent=2))
            status = 0 if report["status"] == "complete" else 2
            if report["status"] == "blocked":
                return 2
        if args.command in ("run", "extract"):
            report = extract(
                args.root,
                languages=args.languages,
                tessdata_dir=args.tessdata_dir,
                workers=args.workers,
                engine=args.engine,
                stores=set(args.store or []),
                max_pages=args.max_pages,
            )
            print(
                json.dumps(
                    {k: report[k] for k in ("status", "offer_count", "errors")},
                    indent=2,
                )
            )
            if report["status"] != "complete":
                status = 2
        elif args.command == "export":
            print(json.dumps(export(args.root), indent=2))
        elif args.command == "audit":
            from flyerkit.audit import audit

            report = audit(args.root)
            print(json.dumps(report, indent=2))
            if report["status"] != "pass":
                status = 2
        elif args.command == "benchmark":
            from flyerkit.benchmark import benchmark

            report = benchmark(args.root, args.labels, args.offers)
            print(
                json.dumps(
                    {k: v for k, v in report.items() if k != "results"}, indent=2
                )
            )
            if report["status"] != "complete":
                status = 2
        elif args.command == "serve":
            from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
            from functools import partial

            if not 1 <= args.port <= 65535:
                raise ValueError("Port must be between 1 and 65535")
            export(args.root)
            server = ThreadingHTTPServer(
                ("127.0.0.1", args.port),
                partial(SimpleHTTPRequestHandler, directory=str(args.root.resolve())),
            )
            print(
                f"Review: http://127.0.0.1:{args.port}/exports/review.html", flush=True
            )
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
            finally:
                server.server_close()
        elif args.command == "review":
            print(json.dumps(apply_reviews(args.root, args.decisions), indent=2))
        elif args.command == "review-source":
            from flyerkit.reviews import apply_source_reviews

            print(json.dumps(apply_source_reviews(args.root, args.decisions), indent=2))
        elif args.command == "match":
            matches = [
                m
                for o in load_offers(args.root)
                if (
                    m := match_offer(
                        o,
                        args.query,
                        on=args.on.isoformat(),
                        province=args.province,
                        city=args.city,
                        region=args.region,
                        include_unreviewed=args.include_unreviewed,
                    )
                )
            ]
            print(json.dumps(matches, ensure_ascii=False, indent=2))
        return status
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(json.dumps({"status": "error", "error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
