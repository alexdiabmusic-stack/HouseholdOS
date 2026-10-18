# Live SmartCanucks validation — October 18, 2026

The Python client successfully accessed SmartCanucks, discovered 87 current/upcoming editions across all 30 configured grocery banners, and saved all **1,351 advertised page images**. Every edition's saved page count matches the source viewer. Original image bytes, source HTML, URLs and SHA256 hashes remain in the gitignored local dataset. No Firecrawl or hosted OCR API was used.

The initial 1,322 saved-image count omitted 29 pages: 28 AVIF images served under `.jpg` URLs and one 45.9-megapixel IGA page. Content-based format detection, local AVIF decoding and an 80-megapixel processing limit recovered those pages. Download failures now also appear in the top-level error report.

## Processing and integrity

The final audit passed with **1,351 / 1,351 pages processed**, **13,283 proposals**, no processing/integrity errors and five separately reviewed example deals. The remaining **13,278 proposals** await review. All 13,283 raw records passed the offer JSON Schema. Machine-readable aggregate results are saved in [validation-2026-10-18.json](validation-2026-10-18.json).

The final extraction uses English/French Tesseract and the bundled local PP-OCRv4 recognizer. Raw OCR is cached by image and engine configuration; price and caption rules are reapplied to each edition. Shared images keep separate source applicability and offer records. Per-image locks protect concurrent cache writes.

`readiness-report.json` checks complete downloads, actual image hashes, processing coverage, price-box bounds, failures and the source applicability of validated records. Its pass means **ready for the local review workflow**. It does not certify unreviewed product-price associations or complete offer recall.

There are **21 editions with unresolved regional applicability**. They remain in `exports/source-review-queue.jsonl`; their offers cannot be validated until evidence-backed geography is supplied. Named regions such as West are preserved without inventing participating provinces. Printed exclusions can be recorded through the source review tool.

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

## Validation performed

- **54 tests passed**, including English/French Tesseract, actual bundled neural OCR on AVIF, concurrent shared-image caching, live-HTML regressions, quote-safe TSV parsing, ambiguous package sizes, stale source decisions, manual entry and matching restrictions.
- Chromium checks passed for rendering, editing, multiline conditions, validation/rejection, downloaded JSONL, saved drafts, manual price-box entry and source applicability review, with no browser script errors.
- Python compilation, Ruff undefined/unused-name checks and Git whitespace checks passed.

Five simple No Frills offers were also visually checked against the original page by Codex: raspberries, yellow onions, large eggs, evaporated milk and flour. Their reviewer is explicitly `Codex visual review`; this is an AI visual check, not a human approval. The source records Ontario-only availability and the printed exclusions for Dryden, Geraldton, Kenora and Thunder Bay. Matching checks include valid Ottawa queries and rejection of excluded cities, wrong provinces, expired dates and an incompatible package size. These corrected examples are separate from the raw benchmark.

## Reproduce and inspect

```sh
python tools/flyers/flyers.py download --as-of 2026-10-18
python tools/flyers/flyers.py extract --engine hybrid --workers 2
python tools/flyers/flyers.py audit
cp data/flyers/exports/offers.jsonl data/flyers/exports/raw-before-review.jsonl
python tools/flyers/flyers.py benchmark tools/flyers/tests/fixtures/live-price-labels-2026-10-18.jsonl --offers data/flyers/exports/raw-before-review.jsonl
python tools/flyers/flyers.py serve
```

Keep the pre-review snapshot before applying decisions. On later dates, replay the labelled editions through their source URLs in the label file; a changed image hash is a different sample. The generated extraction, readiness and benchmark reports contain the full local results. Images and generated catalogs are intentionally excluded from Git.

See [README.md](README.md) for installation and review commands and [MODEL_CARD.md](MODEL_CARD.md) for component provenance and known limits. App import, hosted publication and scheduled collection remain separate from this local ingestion/review workflow.
