# Local grocery-flyer OCR and review

## Intended use

Turn published Canadian flyer images into **proposals for a reviewer** and export checked offers for grocery-item matching. The user selected local OCR with a review queue. No hosted model or paid OCR API is involved.

The system is a pretrained text recognizer plus parsing and layout rules. It has not been trained or fine-tuned on a proprietary grocery-product dataset. It does not establish branch inventory or promise that a proposed product-price association is correct.

## Components and provenance

- Tesseract 5 supplies English/French word text, coordinates and confidence from a green-channel rendering at native image resolution. The original image is retained unchanged.
- Connected-component glyph masks locate large red, white and dark price typography. Only bounded candidate crops are sent to the local neural recognizer.
- `rapidocr_onnxruntime==1.4.4` supplies the bundled PP-OCRv4 recognizer through ONNX Runtime on CPU. Package code is Apache-2.0; model files are bundled with the pinned distribution. Model filenames, SHA256 values and layout version are included in extraction metadata. No model is fetched during inference.
- Rules preserve money in integer CAD cents, basket quantity, price basis, package sizes, membership/conditions and the exact source period/edition.
- Caption association uses retailer item codes where available and geometric proximity. Less-grounded associations are labelled in the queue.
- Source/image hashes, page numbers, price boxes and raw OCR accompany each proposal. Review decisions bind to both the image and the source dates/geography.

The neural recognizer is not a language-model agent and does not browse or call an external service. ONNX Runtime telemetry is disabled. OCR confidence is an engine score, not a probability that a shopping deal is correct.

## Evaluation

Tests exercise live-HTML regressions, quote-safe Tesseract TSV parsing, price-versus-size separation, raised cents, counted packs, unit comparison, source and offer reviews, manual recovery, stale decisions, region exclusions, matching and real local OCR on synthetic fixtures.

The live regression labels contain 40 independently read price regions on three original No Frills, Metro and FreshCo images from October 2026. Images are identified by SHA256 and source URL. These are targeted calibration/regression examples, not a blind holdout. Their metrics do not establish national precision, recall, or complete extraction of every page. See `LIVE_VALIDATION.md` and the generated benchmark report for measured results.

Evaluate a pre-review export when assessing raw extraction. A corrected review record is useful catalog data, but it is not evidence that the OCR model predicted those fields correctly.

## Known failure modes and handling

| Failure | Handling |
| --- | --- |
| Raised cents, omitted leading zero or stylized digits | Preserve reconstruction evidence and require review |
| A package volume such as 3.45/3.85 L resembles a price | Reject it as a sale-price expression |
| A large savings badge or loyalty-points amount resembles a checkout price | Keep amount type/conditions explicit; reviewer must distinguish them |
| Member pricing, non-member comparison and short promotional period share a panel | Require explicit membership, price type and offer dates in each decision |
| Several products share a price or alternative sizes | Preserve ambiguity and raw text; reviewer specifies complete variant details |
| A price marker is missed or a caption is merged with packaging | Inspect all source pages and draw a manual offer in the review tool |
| A weight code is found but /lb or /kg is unresolved | Require a basis selection; printed comparison prices can provide reconstruction evidence |
| A regional title or retailer name does not establish applicability | Preserve the named region or unresolved scope; source review supplies evidence and exclusions |
| Chinese-only or other unsupported caption language | English/French caption OCR and matching require manual transcription into a supported product name; retain the original image and review conditions |
| Source image, dates or geography change after review | Reject stale decisions and invalidate affected validations |

Each validated record requires an explicitly checked product, size or acknowledged unknown size, price, quantity, basis, price type, membership, conditions and validity dates. Savings and regular-price evidence never enters the sale-deals export. The all-pages index includes pages where no offers were detected.

## Operational readiness

`audit` checks source-image integrity, page coverage, bounded evidence coordinates and processing failures. A pass means the dataset is ready for the selected **review workflow**. It does not certify the semantic accuracy of unreviewed proposals. Only checked sale/multi-buy records are eligible for the app catalog.

All images, SQLite data, OCR caches and review records stay in the local dataset directory. Browser review drafts stay in local storage until downloaded and applied. The optional review server binds to `127.0.0.1`. Hosted storage, scheduled execution and app import/deployment are separate operations.
