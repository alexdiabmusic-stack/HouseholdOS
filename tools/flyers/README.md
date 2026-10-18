# Canadian grocery flyer pipeline

Downloads current and upcoming SmartCanucks editions for 30 grocery banners, runs OCR locally, and produces a review queue and a separate checked-deals catalog. No Firecrawl, hosted OCR, vision API, or API key is used.

The live adapter now reads the site's edition heading, explicit published years, listing pagination and complete `/all` viewer. The October 18, 2026 download found **87 editions and 1,351 images**. See [LIVE_VALIDATION.md](LIVE_VALIDATION.md) for final processing and validation results.

## Install and run

Python 3.11+, Tesseract 5, and English/French Tesseract data are required. On Debian/Ubuntu, install `tesseract-ocr tesseract-ocr-eng tesseract-ocr-fra fonts-dejavu-core` using the system package manager.

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/flyers/requirements-ocr.txt
.venv/bin/python tools/flyers/flyers.py --verbose run --workers 2
.venv/bin/python tools/flyers/flyers.py audit
.venv/bin/python tools/flyers/flyers.py serve
```

Open [the local review tool](http://127.0.0.1:8765/exports/review.html). The server binds only to loopback and serves the dataset directory. The HTML also works as local files; images use relative paths.

This cloud workspace has dependencies at `/tmp/householdos-flyer-deps` and language data at `/tmp/householdos-tessdata`. Its equivalent invocation is:

```sh
PYTHONPATH=/tmp/householdos-flyer-deps python3 tools/flyers/flyers.py --verbose run --tessdata-dir /tmp/householdos-tessdata --workers 2
```

The default `hybrid` engine combines native-resolution Tesseract captions with connected-glyph price regions and the bundled PP-OCRv4 recognizer. All inference runs on this machine. `--engine tesseract` uses the lighter, basic OCR path; it misses more large stylized prices.

Stages can run separately:

```sh
.venv/bin/python tools/flyers/flyers.py discover
.venv/bin/python tools/flyers/flyers.py download
.venv/bin/python tools/flyers/flyers.py extract --workers 2
.venv/bin/python tools/flyers/flyers.py export
```

Global `--root PATH` must precede the command. Repeated `--store` and `--province` select download scope. The default is all available Canadian editions for the configured banners, using the Toronto date. `--as-of YYYY-MM-DD` makes date selection repeatable; `--include-expired` explicitly includes archives. Explicit `--flyer-url` values must belong to SmartCanucks.

`--max-flyers`, `--max-pages-per-flyer` and OCR `--max-pages` are sample limits. Truncated runs report partial coverage and do not pass the full-dataset audit.

## Portable JSON test package

```sh
python tools/flyers/flyers.py package --as-of 2026-10-18 --expected-offers 13283 --output data/flyers/packages/smartcanucks-test-2026-10-18
```

This creates an edition-organized directory and a ZIP beside it. `package.json` contains counts, paths and SHA256 checksums. `retailers.json` lists banners, and `editions/index.json` locates each edition's manifest, offers and review history. The dated exports include **one standard JSON array containing all 13,283 offers**, plus separate checked-deals, offer-review and source-review JSONL files. All IDs, original fields and review states are retained. Import one view at a time using `offer_id` as the idempotent key.

The JSON-only package references original images by URL and hash. Local image paths refer to the original dataset. Images, raw OCR, the collector and SQLite are not required to load the JSON. Generated packages stay under the gitignored dataset directory.

After extracting the ZIP, install its small `requirements.txt` and run `python verify.py .` inside the extracted directory. The standalone verifier checks file hashes, all offer schemas, unique IDs, exact partition totals, source-image/context links, coordinates and correct review-state filtering. Packaging never promotes unreviewed proposals, and existing output paths are preserved.

## Review and publish checked deals

1. Open **Applicability** (`exports/sources.html`). Check dates, published region, participating cities and exclusions against the source. Unknown geography must be resolved before its offers can be validated. Do not turn “West” into an assumed list of participating provinces, or treat a retailer's geographic name as availability.
2. Download source decisions and apply them:
   `python tools/flyers/flyers.py review-source /path/to/flyer-source-decisions.jsonl`.
   Source corrections are saved against an inspected image hash, reapplied on subsequent downloads, and invalidate affected offer validations.
3. Open **Offer review** (`exports/review.html`). Inspect the original page and red price box; the blue box, when present, marks a proposed caption. Correct product/variant, brand, package size, price, quantity, weight basis, membership, dates and conditions. A price such as “member save $1” is a saving, not a checkout price.
4. Use **All pages** (`exports/pages.html`) to inspect pages with no proposals. **Add a missed offer** opens the page in the review tool. Draw a box around the price by clicking two opposite corners, then enter the missing details. Manual entries use the same source checks as OCR proposals.
5. Download offer decisions and apply them:
   `python tools/flyers/flyers.py review /path/to/flyer-review-decisions.jsonl`.
6. Import only `exports/validated-deals.jsonl` into the app's public deals catalog.

Browser decisions persist in local storage and remain drafts until downloaded and applied. JSONL application checks the exact original image, complete explicit price fields, date bounds, and `source_context_hash`. A stale decision cannot validate a record whose source dates or geography changed. Prices use integer CAD cents. Savings, regular prices, rejected entries and unreviewed proposals are excluded from the checked-deals export.

Reviewed entries and manually added offers survive subsequent OCR runs when the source is unchanged. Failed OCR pages keep earlier records; errors and missing processing coverage prevent the readiness audit from passing. Extraction commits each completed page and caches raw OCR so an interrupted batch can resume.

A human-readable count such as “5 pack” or “12 eggs” is preserved as a counted size. Counted packages are not compared per litre. Weight and volume comparisons retain fractional cents; a calculated comparison price does not promise that an individual item from a multi-buy can be purchased separately.

The review tool deliberately requires choosing a basis when a weight-priced source item code was detected but the printed `/lb` or `/kg` marker was unresolved.

## Output

Default directory: `data/flyers/` (gitignored).

| File | Purpose |
| --- | --- |
| `discovery-report.json` | Current/upcoming candidate editions and traversal coverage |
| `download-report.json` | Image counts, completeness, source warnings and request failures |
| `regions/PROVINCE_OR_REGION/STORE/DATE_ID/manifest.json` | Source title, dates, geography, every page URL and image hash |
| `source.html`, `detail.html`, `page-NNN.jpg` | Original downloaded evidence |
| `ocr/` | Cached words, text, neural recognition, model fingerprints and coordinates |
| `flyers.sqlite3` | Persistent flyer and offer records |
| `extraction-report.json` | Page coverage, proposals, failures and review invalidations |
| `readiness-report.json` | Image integrity and full processing coverage |
| `benchmark-report.json` | Field correctness on explicitly labelled sample regions |
| `exports/offers.jsonl`, `offers.csv` | All proposals, with review status |
| `exports/validated-deals.jsonl` | Checked sale and multi-buy offers |
| `exports/review-queue.jsonl` | Offers awaiting review |
| `exports/source-review-queue.jsonl` | Unresolved source metadata |
| `exports/review.html`, `sources.html`, `pages.html` | Offline review and missed-offer recovery |
| `source-reviews.json`, review audit JSONL files | Persistent decisions and provenance |

A review-ready audit means that downloaded evidence is intact and every current page was processed. It does not measure whether every printed offer was found or correctly read. An OCR-complete page can still require manual recovery. The checked catalog is ready to import only after the relevant records have been reviewed.

The registered banners include Loblaws, Real/Atlantic Superstore, Metro, Sobeys, No Frills, FreshCo, Food Basics, Foodland, Independent, Zehrs, Fortinos, Maxi, IGA, Super C, Provigo, Save-On-Foods, Safeway, Thrifty Foods, Co-op, Longo's, Farm Boy, T&T, Adonis, Quality Foods, Buy-Low Foods, Nesters, Country Grocer, Walmart and Giant Tiger. This is coverage of editions the site publishes, not a claim that each banner serves every province or branch.

## Requests and geography

The client preserves proxy settings and TLS verification, reads robots.txt, limits request rate, retries transient failures, and caches responses. It rejects unapproved image/redirect hosts. All images in the measured live run were served by `flyers.smartcanucks.ca`. Additional CDN hosts require explicit `--allow-image-host HOST` configuration.

Image format is detected from the content, including AVIF files served under `.jpg` URLs. Original bytes are preserved. AVIF/WebP are decoded locally for OCR, and pages up to 80 megapixels are supported; larger pages report an explicit processing-limit failure.

Viewer modes and page URLs are canonicalized to one edition. The downloader checks the advertised page count against the complete viewer. Archive discovery follows consecutive offsets and looks back through the supported 90-day validity horizon so an expired weekly flyer cannot hide a still-valid monthly edition.

Explicit province and city labels are retained. Named regional editions such as West remain distinct and require selecting that published region. Missing region evidence stays unresolved; it is never labelled Ottawa based on a sample query. Branch participation and stock are not established by a provincial flyer.

## Match a grocery item

```sh
.venv/bin/python tools/flyers/flyers.py match 'raspberries 6 oz' --province ON --city Ottawa --on 2026-10-18
.venv/bin/python tools/flyers/flyers.py match 'milk' --province AB --region West --on 2026-10-18
```

Matching requires checked sale/multi-buy records, matching dates, applicable geography, explicit product tokens and compatible requested size. It retains brands and modifiers such as organic or lactose-free. An edition with city exclusions requires a city; an excluded city does not match. A published “West” label is not inferred from a province alone. Small explicit English/French aliases support common products.

`--include-unreviewed` is a development inspection option and retains all review flags. It must not feed shopping decisions.

Use `offer_id` as an idempotent import key, retain source links and conditions, and query using household geography and date. App UI wiring, a hosted backend and scheduling are separate from this local pipeline.

## Validation and model behaviour

```sh
.venv/bin/python -m unittest discover -s tools/flyers/tests -v
.venv/bin/python tools/flyers/flyers.py benchmark tools/flyers/tests/fixtures/live-price-labels-2026-10-18.jsonl --offers /path/to/pre-review-offers.jsonl
```

The committed live labels identify 40 manually read regions on three image-hash-bound flyer pages. They are targeted regression/calibration examples, not a blind whole-catalog accuracy study. An unlabelled region is not a negative. Benchmark before review, or provide a saved pre-review export, to measure raw OCR rather than corrected catalog entries.

See [MODEL_CARD.md](MODEL_CARD.md) for model provenance and failure modes. Local OCR still misreads some fonts and product captions, and can miss member conditions or narrow offer periods. Review remains part of the selected workflow. No model confidence value is treated as a calibrated probability or automatic permission to publish.

Exit codes: `0` completed the selected stage, `2` partial/empty/blocked coverage, `1` invalid input or processing failure. Metadata that needs review can make a download report partial even when all page images downloaded successfully.
