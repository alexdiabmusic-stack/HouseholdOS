"""Polite, cached, resumable downloads with explicit coverage/error reports."""

from __future__ import annotations

import hashlib
import io
import json
import logging
import time
import urllib.error
import urllib.request
import urllib.robotparser
from collections import deque
from datetime import date, datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import urlparse

from PIL import Image

from .source import (
    BASE_URL,
    HOST,
    canonical_url,
    discover_links,
    parse_flyer,
    flyer_url,
    next_index_url,
    normalized,
)

LOG = logging.getLogger(__name__)
USER_AGENT = "HouseholdOSFlyerBot/0.1 (+public grocery flyer research; conservative rate limiting)"


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    tmp.replace(path)


class DownloadError(RuntimeError):
    pass


class NetworkPolicyBlocked(DownloadError):
    pass


class RestrictedRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, allowed_hosts):
        self.allowed_hosts = allowed_hosts

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = canonical_url(newurl, req.full_url)
        if urlparse(target).hostname not in self.allowed_hosts:
            raise DownloadError(
                "Redirect host needs explicit --allow-image-host: "
                + str(urlparse(target).hostname)
            )
        return super().redirect_request(req, fp, code, msg, headers, target)


class Client:
    def __init__(self, root: Path, delay: float = 1.5, image_hosts=()):
        self.root = root
        self.delay = max(1.0, delay)
        self.allowed_hosts = {HOST, *image_hosts}
        self.opener = urllib.request.build_opener(
            RestrictedRedirect(self.allowed_hosts)
        )
        self.last_request = 0.0
        self.robots = {}
        self.new_requests = 0
        self.cache_hits = 0

    def _request(self, url: str, limit: int) -> tuple[bytes, dict]:
        wait = self.delay - (time.monotonic() - self.last_request)
        if wait > 0:
            time.sleep(wait)
        self.last_request = time.monotonic()
        self.new_requests += 1
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": USER_AGENT,
                "Accept": "text/html,image/*,text/plain;q=0.8",
            },
        )
        try:
            with self.opener.open(req, timeout=30) as response:
                if (
                    response.headers.get("Content-Length", "").isdigit()
                    and int(response.headers["Content-Length"]) > limit
                ):
                    raise DownloadError("Response exceeds byte limit: " + url)
                data = response.read(limit + 1)
                if len(data) > limit:
                    raise DownloadError("Response exceeds byte limit: " + url)
                return data, {
                    "content_type": response.headers.get("Content-Type", ""),
                    "etag": response.headers.get("ETag"),
                    "last_modified": response.headers.get("Last-Modified"),
                    "retrieved_at": now(),
                    "response_url": response.url,
                }
        except urllib.error.URLError as error:
            message = str(error)
            if "Tunnel connection failed: 403" in message:
                raise NetworkPolicyBlocked(
                    "Workspace network allowlist blocks " + str(urlparse(url).hostname)
                ) from error
            raise DownloadError(f"HTTP/network error for {url}: {error}") from error

    def check_robots(self, url: str) -> None:
        origin = f"https://{urlparse(url).netloc}"
        if origin not in self.robots:
            robots_url = origin + "/robots.txt"
            try:
                data, meta = self._request(robots_url, 512_000)
                text = data.decode("utf-8", errors="replace")
                if "<html" in text.lower():
                    raise DownloadError(
                        "robots.txt returned HTML; refusing to assume crawling is permitted"
                    )
                robot = urllib.robotparser.RobotFileParser(robots_url)
                robot.parse(text.splitlines())
                crawl_delay = robot.crawl_delay(USER_AGENT) or robot.crawl_delay("*")
                if crawl_delay:
                    self.delay = max(self.delay, float(crawl_delay))
                self.robots[origin] = robot
                key = hashlib.sha256(origin.encode()).hexdigest()[:16]
                write_json(
                    self.root / "robots" / (key + ".json"),
                    {"url": robots_url, "text": text, **meta},
                )
            except DownloadError as error:
                # A genuine 404 means there is no robots file. Other failures are not permission.
                cause = error.__cause__
                if isinstance(cause, urllib.error.HTTPError) and cause.code == 404:
                    robot = urllib.robotparser.RobotFileParser(robots_url)
                    robot.parse([])
                    self.robots[origin] = robot
                else:
                    raise
        if not self.robots[origin].can_fetch(USER_AGENT, url):
            raise DownloadError(
                "robots.txt disallows this URL for the downloader: " + url
            )

    def get(
        self, url: str, *, image: bool = False, refresh: bool = False
    ) -> tuple[bytes, dict]:
        url = canonical_url(url)
        host = urlparse(url).hostname
        if host not in self.allowed_hosts:
            raise DownloadError(
                f"Image host needs both network access and --allow-image-host: {host}"
            )
        self.check_robots(url)
        key = hashlib.sha256(url.encode()).hexdigest()
        cache = self.root / "http-cache" / key
        metadata = cache.with_suffix(".json")
        ttl = 7 * 86400 if image else 3600
        if (
            not refresh
            and cache.exists()
            and metadata.exists()
            and time.time() - metadata.stat().st_mtime < ttl
        ):
            self.cache_hits += 1
            return cache.read_bytes(), json.loads(metadata.read_text())
        for attempt in range(3):
            try:
                data, meta = self._request(url, 30_000_000 if image else 5_000_000)
                break
            except NetworkPolicyBlocked:
                raise
            except DownloadError as error:
                cause = error.__cause__
                retryable = not isinstance(
                    cause, urllib.error.HTTPError
                ) or cause.code in (429, 500, 502, 503, 504)
                if not retryable or attempt == 2:
                    raise
                retry_after = (
                    cause.headers.get("Retry-After", "")
                    if isinstance(cause, urllib.error.HTTPError)
                    else ""
                )
                pause = min(
                    60,
                    max(
                        2 ** (attempt + 1),
                        int(retry_after) if retry_after.isdigit() else 0,
                    ),
                )
                time.sleep(pause)
        meta["sha256"] = hashlib.sha256(data).hexdigest()
        meta["source_url"] = url
        cache.parent.mkdir(parents=True, exist_ok=True)
        temp = cache.with_suffix(".tmp")
        temp.write_bytes(data)
        temp.replace(cache)
        write_json(metadata, meta)
        return data, meta


def region_key(flyer: dict) -> str:
    geo = flyer["geography"]
    return "-".join(geo["provinces"]) or (
        "national"
        if geo["scope"] == "national"
        else "published-" + normalized(geo["published_region"]).replace(" ", "-")
        if geo.get("published_region")
        else "region-unresolved"
    )


def download_flyers(
    root: Path,
    *,
    stores: set[str],
    as_of: date,
    provinces: set[str],
    include_expired=False,
    flyer_urls=(),
    delay=1.5,
    image_hosts=(),
    max_indexes=250,
    discover_only=False,
    max_flyers=None,
    max_pages_per_flyer=None,
) -> dict:
    client = Client(root, delay, image_hosts)
    report = {
        "started_at": now(),
        "source": BASE_URL,
        "as_of": as_of.isoformat(),
        "scope": {
            "stores": sorted(stores),
            "provinces": sorted(provinces) or "all",
            "include_expired": include_expired,
        },
        "status": "running",
        "index_urls": [],
        "flyers": [],
        "errors": [],
        "skipped": [],
        "discovery_boundaries": [],
        "candidates": [],
        "limits": {
            "max_flyers": max_flyers,
            "max_pages_per_flyer": max_pages_per_flyer,
        },
        "coverage": {
            store: {"discovered": 0, "downloaded": 0, "complete": 0}
            for store in sorted(stores)
        },
    }
    root.mkdir(parents=True, exist_ok=True)
    report_path = root / (
        "discovery-report.json" if discover_only else "download-report.json"
    )
    write_json(report_path, report)
    candidates = {flyer_url(u): {"url": flyer_url(u), "label": ""} for u in flyer_urls}
    if any(urlparse(u).hostname != HOST for u in candidates):
        raise ValueError("Explicit flyer URLs must belong to " + HOST)
    queue, seen = deque([BASE_URL] if not flyer_urls else []), set()
    try:
        while queue:
            if len(seen) >= max_indexes:
                report["errors"].append(
                    {
                        "stage": "discovery",
                        "error": "index_budget_exhausted",
                        "remaining": list(queue),
                    }
                )
                break
            url = queue.popleft()
            if url in seen:
                continue
            seen.add(url)
            try:
                data, _ = client.get(url)
                html = data.decode("utf-8", errors="replace")
                report["index_urls"].append(url)
                links = discover_links(html, url, stores)
                for link in links:
                    if link["kind"] == "flyer":
                        previous = candidates.get(link["url"])
                        if not previous or (
                            not previous.get("valid_to") and link.get("valid_to")
                        ):
                            candidates[link["url"]] = link
                    elif link["url"] not in seen:
                        if "/page/" in link["url"]:
                            continue
                        if not include_expired and any(
                            word in (link["url"] + " " + link["label"]).lower()
                            for word in ("archive", "previous", "past-flyers")
                        ):
                            continue
                        queue.append(link["url"])
                next_url = next_index_url(html, url)
                dates = [
                    l["valid_from"]
                    for l in links
                    if l["kind"] == "flyer" and l.get("valid_from")
                ]
                # Published periods are at most 90 days. Traverse archives far
                # enough to include overlapping monthly/seasonal editions; a
                # single expired weekly card is not a safe stopping boundary.
                cutoff = (as_of - timedelta(days=90)).isoformat()
                if next_url and (include_expired or not dates or min(dates) >= cutoff):
                    if next_url not in seen:
                        queue.append(next_url)
                elif next_url:
                    report["discovery_boundaries"].append(
                        {"url": url, "oldest_start": min(dates), "cutoff": cutoff}
                    )
            except NetworkPolicyBlocked:
                raise
            except DownloadError as error:
                report["errors"].append(
                    {"stage": "discovery", "url": url, "error": str(error)}
                )
            write_json(report_path, report)
        active = []
        for candidate in candidates.values():
            if (
                not include_expired
                and candidate.get("valid_to")
                and candidate["valid_to"] < as_of.isoformat()
            ):
                report["skipped"].append({"url": candidate["url"], "reason": "expired"})
            else:
                active.append(candidate)
        report["candidates"] = active
        if discover_only:
            for candidate in active:
                if candidate.get("store") in report["coverage"]:
                    report["coverage"][candidate["store"]]["discovered"] += 1
            report["stores_without_listings"] = [
                s for s, c in report["coverage"].items() if not c["discovered"]
            ]
            report["status"] = (
                "empty"
                if not active
                else "partial"
                if report["errors"] or report["stores_without_listings"]
                else "complete"
            )
            return report
        if max_flyers is not None and len(active) > max_flyers:
            report["errors"].append(
                {
                    "stage": "limits",
                    "error": "flyer_limit_reached",
                    "available": len(active),
                    "selected": max_flyers,
                }
            )
            active = active[:max_flyers]
        for candidate in active:
            url = candidate["url"]
            if (
                not include_expired
                and candidate.get("valid_to")
                and candidate["valid_to"] < as_of.isoformat()
            ):
                report["skipped"].append({"url": url, "reason": "expired"})
                continue
            LOG.info("Flyer %s", url)
            try:
                data, meta = client.get(url)
                flyer = parse_flyer(
                    data.decode("utf-8", errors="replace"),
                    url,
                    candidate.get("label", ""),
                )
                expected_pages = flyer["expected_page_count"]
                viewer = flyer.get("all_pages_url")
                detail_data = data
                if viewer:
                    data, meta = client.get(viewer)
                    complete_view = parse_flyer(
                        data.decode("utf-8", errors="replace"),
                        url,
                        candidate.get("label", ""),
                    )
                    flyer = complete_view
                    flyer["viewer_url"] = viewer
                if expected_pages is not None:
                    flyer["expected_page_count"] = expected_pages
                    if len(flyer["image_urls"]) != expected_pages:
                        flyer["warnings"].append("page_count_mismatch")
                store = flyer["retailer_id"]
                if store not in stores:
                    report["skipped"].append(
                        {"url": url, "reason": "store_unresolved_or_not_selected"}
                    )
                    continue
                report["coverage"][store]["discovered"] += 1
                if (
                    not include_expired
                    and flyer["valid_to"]
                    and flyer["valid_to"] < as_of.isoformat()
                ):
                    report["skipped"].append({"url": url, "reason": "expired"})
                    continue
                if provinces and not provinces.intersection(
                    flyer["geography"]["provinces"]
                ):
                    report["skipped"].append(
                        {"url": url, "reason": "region_not_selected_or_unresolved"}
                    )
                    continue
                directory = (
                    Path("regions")
                    / region_key(flyer)
                    / store
                    / (
                        (flyer["valid_from"] or "dates-unresolved")
                        + "_"
                        + flyer["flyer_id"]
                    )
                )
                folder = root / directory
                folder.mkdir(parents=True, exist_ok=True)
                (folder / "source.html").write_bytes(data)
                (folder / "detail.html").write_bytes(detail_data)
                flyer["html_sha256"] = meta["sha256"]
                flyer["retrieved_at"] = meta["retrieved_at"]
                flyer["directory"] = str(directory)
                flyer["pages"] = []
                flyer["page_errors"] = []
                flyer["download_complete"] = False
                entry = {
                    "flyer_id": flyer["flyer_id"],
                    "retailer_id": store,
                    "manifest": str(directory / "manifest.json"),
                    "pages": 0,
                    "complete": False,
                    "warnings": flyer["warnings"],
                }
                report["flyers"].append(entry)
                write_json(folder / "manifest.json", flyer)
                selected_images = flyer["image_urls"]
                if (
                    max_pages_per_flyer is not None
                    and len(selected_images) > max_pages_per_flyer
                ):
                    selected_images = selected_images[:max_pages_per_flyer]
                    flyer["warnings"].append("page_limit_reached")
                for number, image_url in enumerate(selected_images, 1):
                    try:
                        image_data, image_meta = client.get(image_url, image=True)
                        with Image.open(io.BytesIO(image_data)) as image:
                            width, height, fmt = image.width, image.height, image.format
                            if width * height > 80_000_000:
                                raise DownloadError(
                                    "Flyer image exceeds the 80 megapixel processing limit"
                                )
                            image.verify()
                        if min(width, height) < 400:
                            raise DownloadError(
                                f"Image is too small for a flyer page: {width}x{height}"
                            )
                        extension = {
                            "JPEG": ".jpg",
                            "PNG": ".png",
                            "WEBP": ".webp",
                            "AVIF": ".avif",
                        }.get(fmt)
                        if not extension:
                            raise DownloadError(
                                "Unsupported flyer image format: " + str(fmt)
                            )
                        relative = directory / f"page-{number:03d}{extension}"
                        tmp = (root / relative).with_suffix(".tmp")
                        tmp.write_bytes(image_data)
                        tmp.replace(root / relative)
                        flyer["pages"].append(
                            {
                                "page_number": number,
                                "path": str(relative),
                                "source_image_url": image_url,
                                "width": width,
                                "height": height,
                                **image_meta,
                            }
                        )
                        entry["pages"] = len(flyer["pages"])
                    except NetworkPolicyBlocked:
                        raise
                    except (
                        DownloadError,
                        OSError,
                        ValueError,
                        Image.DecompressionBombError,
                    ) as error:
                        flyer["page_errors"].append(
                            {
                                "page_number": number,
                                "url": image_url,
                                "error": str(error),
                            }
                        )
                    write_json(folder / "manifest.json", flyer)
                report["errors"].extend(
                    {"stage": "image", "flyer_id": flyer["flyer_id"], **error}
                    for error in flyer["page_errors"]
                )
                flyer["download_complete"] = (
                    bool(flyer["pages"])
                    and not flyer["page_errors"]
                    and len(flyer["pages"]) == flyer["expected_page_count"]
                )
                from .reviews import apply_source_override

                flyer = apply_source_override(root, flyer)
                write_json(folder / "manifest.json", flyer)
                entry["complete"] = flyer["download_complete"]
                if flyer["pages"]:
                    report["coverage"][store]["downloaded"] += 1
                if flyer["download_complete"]:
                    report["coverage"][store]["complete"] += 1
            except NetworkPolicyBlocked:
                raise
            except (DownloadError, ValueError) as error:
                report["errors"].append(
                    {"stage": "flyer", "url": url, "error": str(error)}
                )
            write_json(report_path, report)
        missing_stores = any(not c["complete"] for c in report["coverage"].values())
        report["status"] = (
            "empty"
            if not report["flyers"]
            else "partial"
            if report["errors"]
            or missing_stores
            or any(not f["complete"] or f["warnings"] for f in report["flyers"])
            else "complete"
        )
    except NetworkPolicyBlocked as error:
        report["status"] = "blocked"
        report["errors"].append({"stage": "network_policy", "error": str(error)})
    except KeyboardInterrupt:
        report["status"] = "interrupted"
        report["errors"].append({"stage": "run", "error": "interrupted"})
    finally:
        report["finished_at"] = now()
        report["requests"] = client.new_requests
        report["cache_hits"] = client.cache_hits
        report["flyer_count"] = len(report["flyers"])
        report["image_count"] = sum(f["pages"] for f in report["flyers"])
        report["candidate_count"] = len(report.get("candidates", []))
        report["stores_without_downloads"] = [
            s for s, c in report["coverage"].items() if not c["downloaded"]
        ]
        write_json(report_path, report)
    return report
