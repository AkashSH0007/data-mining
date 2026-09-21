# Question 2 Status

## Completed

- Read and interpreted all Question 2 requirements.
- Loaded the supplied corpus: 12,000 notices, 260 portals, 5,776 opportunities, and 900 labelled pairs.
- Implemented lower-casing, noise-word removal, numeric-token removal, and word-trigram extraction.
- Implemented Jaccard similarity over notice trigram sets.
- Implemented 64-component MinHash signatures.
- Implemented persistent SQLite storage.
- Implemented LSH candidate retrieval with 16 bands and 4 rows per band.
- Added indexed lookup on `(band, bucket)`.
- Added forced table-scan comparison and `EXPLAIN QUERY PLAN` output.
- Added portal-frequency and candidate-list skew measurements.
- Added common-bucket mitigation with a configurable limit of 100 rows.
- Added stable `opportunities` and `notice_opportunity` tables for bookmark-safe card IDs.
- Added labelled-pair similarity measurements.
- Added candidate tradeoff plot generation.
- Added implementation documentation in `README.md` and `report.md`.
- Smoke test passes on 200 notices.
- Python diagnostics report no errors.
- Added concrete labelled-pair examples to the metrics.
- Added measured MinHash absolute-error statistics.
- Added indexed-row and forced-scan-row counts.
- Added raw and mitigated retrieval wall-clock timings.
- Added an explicit 10:1 missed-duplicate versus candidate-work cost ratio.

## Verified Measurements

The current complete deterministic full-corpus run produced:

- Notices: 12,000
- Labels: 900
- Opportunities: 5,776
- Build time: approximately 65.11 seconds
- Signature size: 64 components
- LSH configuration: 16 bands x 4 rows
- Mean candidates before mitigation: 1,463.73
- Candidate p95 before mitigation: 2,936
- Maximum candidates before mitigation: 4,379
- Candidate recall before mitigation: 37.44%
- Mean candidates after mitigation: 178.86
- Candidate p95 after mitigation: 323
- Maximum candidates after mitigation: 572
- Candidate recall after mitigation: 22.78%
- Raw retrieval time: 61.04 seconds
- Mitigated retrieval time: 8.61 seconds
- MinHash mean absolute error: 0.05039
- MinHash p95 absolute error: 0.12645
- Indexed rows returned: 10
- Forced rows examined: 192,000
- Indexed lookup plan: uses `idx_lsh_bucket`
- Forced lookup plan: full scan of `lsh_buckets`
- Stable cards: 5,776
- Stable aliases: 12,000

## Remaining judgement/risk

- The selected retrieval configuration has imperfect labelled candidate recall. A production design should add a second high-recall retrieval path or tune the LSH operating point before treating candidate absence as proof of non-duplication.
- Smoke output is isolated in `metrics_smoke.json`; it no longer overwrites the full-run `metrics.json`.
- The 10:1 ratio is explicit and measured in the configuration, but the final product policy should confirm that this ratio is acceptable to the board.

## How To Run

Smoke test:

```powershell
py -3 solution\q2_solution.py --smoke
```

Full run:

```powershell
taskkill.exe /F /IM py.exe /T
taskkill.exe /F /IM python.exe /T
Remove-Item solution\results\retrieval.sqlite* -Force -ErrorAction SilentlyContinue
py -3 solution\q2_solution.py
```

Do not run the smoke test after the full run unless the output is saved separately, because the script currently overwrites `results\metrics.json`.