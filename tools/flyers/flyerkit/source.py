"""HTML adapter. Never infer a city or validity period from the retrieval date."""
from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from datetime import date
from urllib.parse import unquote, urljoin, urlparse, urlunparse

from bs4 import BeautifulSoup

BASE_URL = "https://flyers.smartcanucks.ca/"
HOST = "flyers.smartcanucks.ca"
STORES = {
    "loblaws": ["Loblaws"],
    "real-canadian-superstore": ["Real Canadian Superstore", "RCSS", "Superstore"],
    "atlantic-superstore": ["Atlantic Superstore"],
    "metro": ["Metro"],
    "sobeys": ["Sobeys", "Sobey's", "Sobey"],
    "no-frills": ["No Frills", "NoFrills"],
    "freshco": ["FreshCo", "Fresh Co"],
    "food-basics": ["Food Basics"],
    "foodland": ["Foodland"],
    "independent": ["Your Independent Grocer", "Independent Grocer", "Independent"],
    "zehrs": ["Zehrs"],
    "fortinos": ["Fortinos"],
    "maxi": ["Maxi"],
    "iga": ["IGA Extra", "IGA"],
    "super-c": ["Super C"],
    "provigo": ["Provigo"],
    "save-on-foods": ["Save On Foods", "Save-On-Foods"],
    "safeway": ["Safeway"],
    "thrifty-foods": ["Thrifty Foods"],
    "co-op": ["Calgary Co-op", "Co-op", "Coop"],
    "longos": ["Longo's", "Longos"],
    "farm-boy": ["Farm Boy"],
    "t-and-t": ["T&T Supermarket", "T&T", "T and T Supermarket"],
    "adonis": ["Adonis"],
    "quality-foods": ["Quality Foods"],
    "buy-low-foods": ["Buy Low Foods", "Buy-Low Foods"],
    "nesters-market": ["Nesters Market", "Nesters"],
    "country-grocer": ["Country Grocer"],
    "walmart": ["Walmart", "Wal Mart"],
    "giant-tiger": ["Giant Tiger"],
}
PROVINCES = {
    "AB": ["Alberta"], "BC": ["British Columbia", "Colombie Britannique"],
    "MB": ["Manitoba"], "NB": ["New Brunswick", "Nouveau Brunswick"],
    "NL": ["Newfoundland", "Newfoundland and Labrador", "Terre Neuve"],
    "NS": ["Nova Scotia", "Nouvelle Ecosse"], "NT": ["Northwest Territories"],
    "NU": ["Nunavut"], "ON": ["Ontario"], "PE": ["Prince Edward Island", "PEI"],
    "QC": ["Quebec", "Québec", "PQ"], "SK": ["Saskatchewan"], "YT": ["Yukon"],
}
MONTHS = {
    1: ["January", "Jan", "Janvier", "Janv"],
    2: ["February", "Feb", "Fevrier", "Fevr"],
    3: ["March", "Mar", "Mars"], 4: ["April", "Apr", "Avril", "Avr"],
    5: ["May", "Mai"], 6: ["June", "Jun", "Juin"],
    7: ["July", "Jul", "Juillet", "Juil"], 8: ["August", "Aug", "Aout"],
    9: ["September", "Sep", "Sept", "Septembre"],
    10: ["October", "Oct", "Octobre"],
    11: ["November", "Nov", "Novembre"],
    12: ["December", "Dec", "Decembre"],
}


def normalized(text: str) -> str:
    text = text.replace("œ", "oe").replace("Œ", "OE").replace("æ", "ae").replace("Æ", "AE")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def stable_id(*parts: str) -> str:
    return hashlib.sha256("\x1f".join(parts).encode()).hexdigest()[:24]


def canonical_url(url: str, base: str = BASE_URL) -> str:
    p = urlparse(urljoin(base, url))
    if p.scheme not in ("http", "https") or p.username or p.password:
        raise ValueError("Not a public HTTP(S) URL")
    return urlunparse(("https", p.netloc.lower(), p.path or "/", "", p.query, ""))


def retailer(text: str) -> str | None:
    norm = " " + normalized(unquote(text)) + " "
    matches = [(len(normalized(alias)), key) for key, aliases in STORES.items()
               for alias in aliases if " " + normalized(alias) + " " in norm]
    return max(matches)[1] if matches else None


def geography(title: str) -> dict:
    norm = " " + normalized(title) + " "
    codes = set()
    # Abbreviations must be uppercase in the original: the English word 'on' is not Ontario.
    for code, names in PROVINCES.items():
        if re.search(r"\b" + code + r"\b", title) or any(" " + normalized(n) + " " in norm for n in names):
            codes.add(code)
    if not codes and (" atlantic " in norm or " maritimes " in norm):
        codes.update(["NB", "NL", "NS", "PE"] if " atlantic " in norm else ["NB", "NS", "PE"])
    if " western canada " in norm:
        codes.update(["AB", "BC", "MB", "SK"])
    cities = [city for city in ["Ottawa", "Toronto", "Montreal", "Montréal", "Quebec City", "Vancouver",
              "Victoria", "Calgary", "Edmonton", "Winnipeg", "Regina", "Saskatoon", "Halifax",
              "Moncton", "Fredericton", "St. John's", "Charlottetown", "Whitehorse", "Yellowknife", "Iqaluit"]
              if re.search(r"\b" + re.escape(city) + r"\b", title, re.I)]
    city_provinces = {"Ottawa": "ON", "Toronto": "ON", "Montreal": "QC", "Montréal": "QC", "Quebec City": "QC",
                      "Vancouver": "BC", "Victoria": "BC", "Calgary": "AB", "Edmonton": "AB", "Winnipeg": "MB",
                      "Regina": "SK", "Saskatoon": "SK", "Halifax": "NS", "Moncton": "NB", "Fredericton": "NB",
                      "St. John's": "NL", "Charlottetown": "PE", "Whitehorse": "YT", "Yellowknife": "NT", "Iqaluit": "NU"}
    codes.update(city_provinces[city] for city in cities)
    labels = re.findall(r"\(([^)]+)\)", title)
    regional_labels = [s for s in labels if not re.fullmatch(r"\s*\d+\s*(?:pages?)?\s*", s, re.I)]
    national = bool(re.search(r"\b(?:national|canada wide|all canada)\b", norm))
    return {"country": "CA", "provinces": sorted(codes), "cities": cities,
            "published_region": "; ".join(regional_labels) or ("National" if national else None),
            "scope": "city" if cities else "province" if codes else "national" if national else "unknown",
            "evidence": title}


def parse_dates(text: str) -> tuple[str | None, str | None]:
    """Parse explicit EN/FR named-month ranges and ISO ranges, including year rollover."""
    raw = unicodedata.normalize("NFKD", unquote(text)).encode("ascii", "ignore").decode().lower()
    raw = re.sub(r"[–—_-]", " ", raw)
    iso = re.findall(r"\b(20\d{2})[ /](\d{2})[ /](\d{2})\b", raw)
    if len(iso) >= 2:
        try:
            a, b = [date(*map(int, parts)) for parts in iso[:2]]
            return (a.isoformat(), b.isoformat()) if 0 <= (b-a).days <= 90 else (None, None)
        except ValueError:
            return None, None
    lookup = {name.lower(): month for month, names in MONTHS.items() for name in names}
    names = "|".join(sorted(map(re.escape, lookup), key=len, reverse=True))
    # 'October 11-18, 2026', 'Dec 26, 2026 to Jan 1, 2027', and slug forms.
    pattern = rf"\b({names})\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?\b\s*,?\s*(20\d{{2}})?\s*(?:to|au|a|until|through|thru)?\s*(?:({names})\.?\s+)?(\d{{1,2}})(?:st|nd|rd|th)?\b\s*,?\s*(20\d{{2}})?\b"
    match = re.search(pattern, raw)
    if not match:
        # French day-first style: 'du 11 au 18 octobre 2026'.
        match_fr = re.search(rf"\b(\d{{1,2}})\s*(?:au|a|to)\s*(\d{{1,2}})\s+({names})\.?\s+(20\d{{2}})\b", raw)
        if match_fr:
            da, db, month, year = match_fr.groups()
            try:
                a, b = date(int(year), lookup[month], int(da)), date(int(year), lookup[month], int(db))
                return (a.isoformat(), b.isoformat()) if 0 <= (b-a).days <= 90 else (None, None)
            except ValueError:
                pass
        return None, None
    ma, da, ya, mb, db, yb = match.groups()
    if not (ya or yb):
        return None, None  # Retrieval year is not a substitute for a published year.
    month_a, month_b = lookup[ma], lookup[mb or ma]
    year_a = int(ya or yb) - (not ya and month_a > month_b)
    year_b = int(yb or ya) + (not yb and month_b < month_a)
    try:
        a, b = date(year_a, month_a, int(da)), date(year_b, month_b, int(db))
        return (a.isoformat(), b.isoformat()) if 0 <= (b-a).days <= 90 else (None, None)
    except ValueError:
        return None, None


def discover_links(html: str, url: str, stores: set[str]) -> list[dict]:
    soup = BeautifulSoup(html, "html.parser")
    found = {}
    for a in soup.find_all("a", href=True):
        try:
            link = canonical_url(a["href"], url)
        except ValueError:
            continue
        p = urlparse(link)
        if p.hostname != HOST or re.search(r"\.(?:jpg|png|webp|pdf)$", p.path, re.I):
            continue
        label = a.get_text(" ", strip=True) or a.get("title", "")
        key = retailer(label + " " + unquote(p.path))
        if key not in stores:
            continue
        start, end = parse_dates(label + " " + unquote(p.path))
        if start or re.search(r"\bflyer\b", normalized(label + " " + p.path)):
            found[link] = {"url": link, "store": key, "label": label,
                           "kind": "flyer" if start else "index", "valid_from": start, "valid_to": end}
    return list(found.values())


def _json_objects(value):
    if isinstance(value, dict):
        yield value
        for item in value.values(): yield from _json_objects(item)
    elif isinstance(value, list):
        for item in value: yield from _json_objects(item)


def parse_flyer(html: str, url: str, hint: str = "") -> dict:
    soup = BeautifulSoup(html, "html.parser")
    heading = soup.find("h1")
    title = heading.get_text(" ", strip=True) if heading else ""
    if not title:
        og = soup.find("meta", property="og:title")
        title = og.get("content", "") if og else soup.title.get_text(" ", strip=True) if soup.title else hint
    store = retailer(title) or retailer(url)
    start, end = parse_dates(title)
    date_evidence = title
    if not start:
        start, end = parse_dates(url)
        date_evidence = url
    # Prefer explicit structured validity dates when supplied together.
    for script in soup.find_all("script", type="application/ld+json"):
        if start and end: break
        try:
            for obj in _json_objects(json.loads(script.string or script.get_text())):
                if obj.get("url") != url and obj.get("name") != title:
                    continue
                pairs = {k: obj[k] for k in ("startDate", "endDate") if isinstance(obj.get(k), str)}
                if not (pairs.get("startDate") and pairs.get("endDate")): continue
                a, b = date.fromisoformat(pairs["startDate"][:10]), date.fromisoformat(pairs["endDate"][:10])
                if 0 <= (b-a).days <= 90:
                    start, end = a.isoformat(), b.isoformat()
                    date_evidence = json.dumps(pairs)
                    break
        except (ValueError, TypeError):
            pass
    images = []
    scope = soup.select_one("#flyer-pages, .flyer-pages, #flyer-images, .flyer-images, #flyer-viewer, .flyer-viewer") or soup.find("main") or soup
    for tag in scope.find_all(["img", "a", "source"]):
        parents = " ".join(" ".join(p.get("class", [])) + " " + (p.get("id") or "") for p in [tag, *list(tag.parents)[:5]] if getattr(p, "attrs", None))
        if re.search(r"(?:related|recommend|advert|sidebar|logo|thumbnail)", parents, re.I):
            continue
        attrs = [tag.get(key) for key in ("data-original", "data-src", "data-lazy-src", "href", "src")]
        srcset = tag.get("srcset") or tag.get("data-srcset")
        if srcset:
            attrs.insert(0, srcset.split(",")[-1].strip().split()[0])
        for value in attrs:
            if not isinstance(value, str):
                continue
            try:
                img_url = canonical_url(value, url)
            except ValueError:
                continue
            path = urlparse(img_url).path
            if not re.search(r"\.(?:jpe?g|png|webp)(?:$)", path, re.I):
                continue
            if re.search(r"(?:logo|icon|avatar|thumb|banner|button|pixel|\.gif)", path, re.I):
                continue
            if not (re.search(r"(?:flyer|pages?|uploads)", path, re.I) or scope is not soup):
                continue
            try:
                width = int(str(tag.get("width", "0")).rstrip("px"))
                if 0 < width < 400:
                    continue
            except ValueError:
                pass
            if img_url not in images:
                images.append(img_url)
                break  # Pick the highest-resolution attribute for this element.
    warnings = []
    if not store: warnings.append("store_unresolved")
    if not start or not end: warnings.append("validity_dates_unresolved")
    region = geography(title)
    if region["scope"] == "unknown": warnings.append("region_unresolved")
    if not images: warnings.append("no_page_images_discovered")
    return {"flyer_id": stable_id(url), "source_url": url, "source_title": title, "retailer_id": store,
            "retailer_name": STORES[store][0] if store else None, "geography": region,
            "valid_from": start, "valid_to": end, "date_evidence": date_evidence,
            "image_urls": images, "warnings": warnings}
