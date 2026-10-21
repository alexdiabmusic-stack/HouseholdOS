# Live SmartCanucks validation — October 18, 2026

The Python client successfully accessed SmartCanucks, discovered 87 current/upcoming editions across all 30 configured grocery banners, and saved all **1,351 advertised page images**. Every edition's saved page count matches the source viewer. Original image bytes, source HTML, URLs and SHA256 hashes remain in the gitignored local dataset. No Firecrawl or hosted OCR API was used.

The initial 1,322 saved-image count omitted 29 pages: 28 AVIF images served under `.jpg` URLs and one 45.9-megapixel IGA page. Content-based format detection, local AVIF decoding and an 80-megapixel processing limit recovered those pages. Download failures now also appear in the top-level error report.

## Processing and integrity

The integrity audit passed with **1,351 / 1,351 pages processed**, **13,283 original proposals** and no processing/integrity errors. All original offer IDs are preserved. The initial extraction measurements remain in [validation-2026-10-18.json](validation-2026-10-18.json); the completed visual review has its own [aggregate results](visual-review-2026-10-18.json).

The final extraction uses English/French Tesseract and the bundled local PP-OCRv4 recognizer. Raw OCR is cached by image and engine configuration; price and caption rules are reapplied to each edition. Shared images keep separate source applicability and offer records. Per-image locks protect concurrent cache writes.

`readiness-report.json` checks complete downloads, actual image hashes, processing coverage, price-box bounds, failures and the source applicability of validated records. Its pass means **ready for the local review workflow**. It does not certify unreviewed product-price associations or complete offer recall.

All **87 editions** received source-date and geography assessments. **63 are validated and 24 remain pending**, including 11 whose scope is unknown. The pending editions remain in `exports/source-review-queue.jsonl`; their offers cannot be validated until applicability is resolved. Named regions such as West are preserved without inventing participating provinces. Printed participating-store and excluded-store addresses are retained and require an explicit store selection when matching.

## Raw extraction measurement

Forty manually read price regions on three original No Frills, Metro and FreshCo pages form the committed regression labels. The benchmark uses a saved **pre-review** export, identifies images by SHA256 and chooses the best candidate within each labelled price region.

| Labelled field | Correct |
| --- | ---: |
| CAD amount | 35 / 40 |
| Each/weight price basis | 32 / 40 |
| Purchase quantity | 35 / 40 |
| Sale, multi-buy, regular or saving | 34 / 40 |
| Membership requirement | 31 / 40 |
| Expected product tokens present | 23 / 40 |
| All six labelled checks together | 20 / 40 |

These are calibration/regression examples, not a blind holdout. The product check tests token presence, not complete variant identification. Package size, full conditions and restricted offer dates are not scored by this sample. Unlabelled regions are not negatives, so these numbers do not measure whole-catalog precision or recall. They support the selected **mandatory review queue**, not automatic publication.

The most consequential remaining errors involve product captions, savings badges, membership conditions, missing price markers and weight bases. Reviewers can inspect every original page, correct all offer fields, reject a proposal, or draw a missed price box and enter an offer manually. Only explicitly validated sale/multi-buy records reach `validated-deals.jsonl`.

## Complete visual review

The AI visual review finished on October 21, 2026 (UTC), using the October 18 snapshot. Parallel reviewers inspected every indexed proposal group against its original page image. The review covers **13,283 / 13,283 offer IDs** across **998 unique image SHA256 hashes**. Shared images retain separate edition applicability. AI provenance is explicit in every offer; these decisions are not human approvals.

| Current outcome | Records |
| --- | ---: |
| Validated, including regular prices and savings | 9,106 |
| Needs clarification | 3,527 |
| Rejected detections | 650 |
| Sale/multi-buy records eligible for checked-deals export | 8,332 |

The 3,527 pending records have been inspected. They retain known corrections and explicit unresolved fields, chiefly geographic/store participation, product/starting-price ambiguity and conflicting offer periods. **217 records** retain checked dates outside the edition in `review.assessment.unapplied_fields`; their primary dates are not silently extended. Pending and rejected records cannot enter deal matching. Export eligibility still requires a matching query date, location, package and conditions.

Corrections include merged product captions, missing weight bases, isolated cents interpreted as whole dollars, quantity-triggered savings and member/non-member prices. Loyalty cash equivalents, package counts and historical flyer thumbnails were rejected as price detections. Four-day promotions retain their shorter dates. Source corrections include Walmart Fall's printed October 7 expiry, Country Grocer's separate Salt Spring Island period, participating Metro Kosher stores and store-address exclusions. Co-op edition display names are preserved under their stable shared retailer ID.

This pass assesses existing proposals. It does not measure missed-offer recall, certify a production catalog or train the OCR recognizer. The raw benchmark above remains separate from the corrected dataset.

## Validation performed

- **73 tests passed**, including English/French Tesseract, bundled neural OCR on AVIF, concurrent image caching, stale image/source decisions, whole-batch assessment preflight, exact original-ID coverage, pending correction retention, savings thresholds, store restrictions and portable package verification.
- The final standalone JSON package passed file-hash, JSON Schema, unique-ID, edition-partition, image-reference, source-context, coordinate, filtering and count checks. All 13,283 original IDs are preserved.
- DOM execution checks passed for source-restriction preservation, savings-quantity editing and visual provenance in the review forms. Earlier Chromium checks cover drafts, downloaded decisions, manual price-box entry and source applicability review.
- Python compilation, Ruff undefined/unused-name checks and Git whitespace checks passed.

The reviewed package is `smartcanucks-reviewed-2026-10-18.zip`. It preserves all offers, review histories, the 3,527-record review queue, the 24-edition source queue and the cumulative visual-review report. The original `smartcanucks-test-2026-10-18.zip` and pre-review export remain unchanged. Images and OCR caches remain in the local source dataset; the portable package references their URLs and SHA256 hashes.

## Reproduce and inspect

```sh
python tools/flyers/flyers.py download --as-of 2026-10-18
python tools/flyers/flyers.py extract --engine hybrid --workers 2
python tools/flyers/flyers.py audit
cp -n data/flyers/exports/offers.jsonl data/flyers/exports/raw-before-review.jsonl
python tools/flyers/flyers.py benchmark tools/flyers/tests/fixtures/live-price-labels-2026-10-18.jsonl --offers data/flyers/exports/raw-before-review.jsonl
python tools/flyers/flyers.py serve
```

Keep the pre-review snapshot before applying decisions. To replay a saved review batch, use `review-source` followed by `assess --expected-offers 13283`; generate a fresh `source_context_hash` after source corrections. The `package` command writes to a new output path and includes a standalone verifier. On later dates, replay the labelled editions through their source URLs in the label file; a changed image hash is a different sample. The generated extraction, readiness and benchmark reports contain the full local results. Images and generated catalogs are intentionally excluded from Git.

See [README.md](README.md) for installation and review commands and [MODEL_CARD.md](MODEL_CARD.md) for component provenance and known limits. App import, hosted publication and scheduled collection remain separate from this local ingestion/review workflow.
