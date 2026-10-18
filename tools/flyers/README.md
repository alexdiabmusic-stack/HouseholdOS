# Grocery flyer ingestion

Python downloader, local OCR, review queue, structured exports and grocery-item matching. No Firecrawl or paid OCR service is used. Tesseract runs locally; raw flyer images and generated data stay in the gitignored output folder.

## Current live-run status

The workspace's proxy rejected requests to `flyers.smartcanucks.ca` with `Tunnel connection failed: 403 Forbidden`, including after the first requested settings change. The running environment still reported no custom allowed hosts. **No real flyer images or real offers have been downloaded or extracted.** `data/flyers/download-report.json` records the attempted live run.

The HTML adapter is a provisional implementation, tested against explicitly synthetic fixtures. It must be checked against the live site's actual HTML, pagination, regional listings and full-resolution image locations once access works. JavaScript-only viewers and unrecognized page layouts require an adapter update; an empty discovery result is never proof that there are no flyers. Site-wide coverage and price-extraction accuracy have not been established.

Twenty-five local tests cover source/date parsing, geography, downloads/cache/resume, price types, package sizes, product associations, review, matching and real English/French Tesseract-to-SQLite/export runs on **synthetic** images. Those tests are not evidence of live-site accuracy.

## Install

Python 3.11+ and Tesseract 5 with English/French data:

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/flyers/requirements.txt
# Debian/Ubuntu, on a machine where system package installation is available:
sudo apt-get install tesseract-ocr tesseract-ocr-eng tesseract-ocr-fra fonts-dejavu-core
```

In the current workspace, dependencies are installed at `/tmp/householdos-flyer-deps`. An official `tessdata_fast` French model is at `/tmp/householdos-tessdata`, alongside links to the installed English data. This is temporary runtime setup, not a repository dependency. Use `PYTHONPATH=/tmp/householdos-flyer-deps` and `--tessdata-dir /tmp/householdos-tessdata` for the commands below in this workspace.

## Run

From the repository root, the default scope is **all available Canadian editions** for the 30 configured grocery banners, current and upcoming as of the Toronto date. It does not assume every banner has flyers in every province. Archived periods are excluded unless requested.

```sh
.venv/bin/python tools/flyers/flyers.py --verbose run --workers 2

# Download and extraction can also run separately; extraction is entirely offline.
.venv/bin/python tools/flyers/flyers.py --verbose download
.venv/bin/python tools/flyers/flyers.py --verbose extract --workers 2

# A smaller, explicit selection; repeated store/province options are supported.
.venv/bin/python tools/flyers/flyers.py download \
  --store sobeys --store no-frills --store metro --province ON

# Explicit detail URLs can bypass index discovery, but not robots/network restrictions.
.venv/bin/python tools/flyers/flyers.py download --store sobeys \
  --flyer-url 'https://flyers.smartcanucks.ca/REPLACE_WITH_ACTUAL_FLYER_DETAIL_PATH'
```

Allow `flyers.smartcanucks.ca` in the **running cloud environment's** network settings. If actual page images use a different CDN hostname, explicitly allow that hostname in both network settings and `--allow-image-host HOST`. The downloader reports the hostname rather than silently trusting arbitrary outbound hosts. It preserves the inherited proxy and TLS verification. A network-policy rejection stops the run; it does not attempt to bypass the policy.

The downloader reads `robots.txt`, honors disallow rules/crawl delays, waits at least one second between requests, retries transient errors, caches responses and writes manifests after each image. A maximum index count bounds discovery. Exhausting that budget, unresolved metadata, missing banners, or failed pages produces a partial/empty report and nonzero exit status. Content with an unknown year is not silently dated using today's year.

Exit codes: `0` completed the selected stage; `2` blocked, empty or partial; `1` invalid setup/input or unexpected processing error. An OCR stage marked complete means all selected pages were processed, **not** that every printed offer was detected or correctly associated.

## Output and geography

Default output: `data/flyers/` (override with global `--root PATH`, before the command).

```text
download-report.json              request errors, discovered/downloaded coverage per banner
extraction-report.json            page-level OCR coverage, failures and proposal counts
regions/ON/sobeys/DATE_ID/         province, banner, source period and stable flyer ID
  manifest.json                   original title/URL, dates/evidence, geography, image hashes
  source.html                     exact downloaded HTML
  page-001.jpg                    original image bytes
regions/AB-BC-MB-SK/.../           multi-province edition; no invented city applicability
regions/national/.../             only when source explicitly establishes national scope
regions/region-unresolved/.../    missing region evidence, excluded from normal matching
ocr/                             cached TSV words/boxes, plain text and OCR metadata
flyers.sqlite3                   indexed flyer/offer records, JSON payloads
exports/offers.jsonl              all OCR proposals, including savings/regular-price evidence
exports/offers.csv                spreadsheet-friendly flattened records
exports/review-queue.jsonl        unresolved proposals
exports/review.html               original pages with price boxes and review details
exports/validated-deals.jsonl     reviewed sale/multi-buy offers suitable for matching
review-audit.jsonl                applied human decisions and source image hashes
```

The metadata preserves the exact published regional label and any explicit province/city. A province-wide Ontario edition can be considered for an Ontario household; it is not relabeled an Ottawa store's offer. Known explicit cities are mapped to their province. Unrecognized labels remain preserved but unresolved. Confirm specific stores' participation separately; this is not branch-level inventory or a guarantee of availability.

The banner registry includes Loblaws, Real Canadian Superstore, Atlantic Superstore, Metro, Sobeys, No Frills, FreshCo, Food Basics, Foodland, Independent, Zehrs, Fortinos, Maxi, IGA, Super C, Provigo, Save-On-Foods, Safeway, Thrifty Foods, Co-op, Longo's, Farm Boy, T&T, Adonis, Quality Foods, Buy-Low Foods, Nesters, Country Grocer, Walmart and Giant Tiger. The report explicitly lists banners without downloads.

## Product, price and date contract

Every proposal includes retailer identity, geography, inclusive `valid_from`/`valid_to`, separate original flyer dates, product text, canonical matching tokens, brand (unknown until checked), package size, purchase quantity, conditions and review status. Evidence includes source detail/image URLs, original image hash, page number, retrieval time, price box coordinates and OCR engine/confidence. See [offer.schema.json](offer.schema.json).

Money uses integer CAD cents. `2 for $5` is 500 cents for **two** units; it does not promise a single unit costs $2.50. Weight prices retain `/lb`, `/kg` or `/100g`. Exact sizes support comparison per kg/L, with fractional cents represented as decimal strings. Alternative size ranges remain ambiguous. Savings amounts and regular prices are separate types and excluded from sale matching. Membership, restricted-day and other conditions remain attached.

Tesseract cannot reliably understand arbitrary flyer layouts. The initial extractor proposes nearby product/price associations and reconstructs some raised-cents prices; all proposals start as `needs_review`. OCR confidence is not a calibrated probability of a correct product match. Full-page OCR text and unmatched product text remain available for recovering missed offers. Human review is currently required before normal app matching; automatic publication should wait for measured accuracy on a representative set of actual regional flyers. There is no verified extraction model or measured recall yet.

## Review

Open `exports/review.html` locally. Check product, brand/variant, price, quantity/weight basis, package size, membership/limits and any narrower validity dates against the original image. Create a JSONL decision file. Example structure only — the values below are **synthetic**, not an actual Sobeys offer:

```json
{"offer_id":"COPY_ACTUAL_ID","image_sha256":"COPY_ACTUAL_IMAGE_HASH","status":"validated","reviewer":"YOUR_NAME","product_name":"Strawberries","size_text":"400g","amount_cents":299,"purchase_quantity":1,"basis":"each","kind":"sale","requires_membership":false,"conditions":[],"notes":"Checked original flyer image"}
```

```sh
.venv/bin/python tools/flyers/flyers.py review /path/to/decisions.jsonl
```

Use `status: "rejected"` for a bad association. Validation requires exact source hash, reviewer, explicitly checked product/price and resolved source dates/region. A restricted-day offer also needs `offer_valid_from` and `offer_valid_to` within its original flyer period. Source-level metadata errors must be corrected in the manifest and re-extracted before review. Reviews persist when the same source proposal is reprocessed; changed OCR anchors create new unreviewed proposals. Orphaned earlier reviews are reported, not silently treated as matching the new proposal.

## Match a grocery item

```sh
.venv/bin/python tools/flyers/flyers.py match 'strawberries 400g' \
  --province ON --city Ottawa --on 2026-10-18
```

The date above is an example query. Matching checks the actual offer dates, region, review status, explicit product tokens and requested size. Small explicit EN/FR aliases support e.g. `fraises` ↔ `strawberries`; brand/modifiers such as `organic` are not discarded. City-specific editions require that city. Normal matching excludes expired, future, unknown-region, unreviewed and savings-only records. `--include-unreviewed` is a development inspection option; it retains review flags and must not drive automatic shopping decisions.

For the household app, import `validated-deals.jsonl` into a backend catalog using `offer_id` as the idempotency key. Query with the household's region/date and grocery-item terms, show package/unit price and conditions, and link to evidence. Keep this public deals catalog separate from private household lists. No Supabase deployment, app UI wiring, background schedule or public image hosting is performed by this tool.

## Checks

```sh
.venv/bin/python -m unittest discover -s tools/flyers/tests -v
```

The OCR smoke test uses DejaVu fonts and Tesseract on an explicitly synthetic temporary image. Test output never enters `data/flyers/`. The source fixtures are synthetic too; live-site validation remains blocked until network access works.
