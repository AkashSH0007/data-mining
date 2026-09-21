# Question 2 report

## A. Retrieval design

### (a) Similarity definition

A notice is represented as a set of word trigrams derived from its title and body.

The preprocessing steps are:

1. Convert text to lower case.
2. Remove common portal/procurement noise words.
3. Remove standalone numeric tokens, which suppresses reference numbers, dates and similar formatting noise.
4. Extract word trigrams from the remaining text.

Similarity is defined mechanically as Jaccard similarity:

`J(A,B) = |A ∩ B| / |A ∪ B|`

where `A` and `B` are the trigram sets of two notices.

This representation was selected using the supplied labelled pairs. On the full labelled set, the raw representation produced:

* Same-pair mean similarity: 0.6447
* Same-pair p10: 0.2935
* Different-pair mean similarity: 0.2538
* Different-pair p10: 0.1284

After cleaning:

* Same-pair mean similarity: 0.6330
* Same-pair p10: 0.2738
* Different-pair mean similarity: 0.3540
* Different-pair p10: 0.1552

Cleaning therefore removes useful as well as noisy tokens, so the adopted representation is a deliberate compromise rather than a claim of perfect separation. The measured labelled-pair values are used as the evidence for this choice.

Concrete labelled examples are recorded in `metrics.json` under `estimator_metrics.examples`; each includes the pair IDs, label, raw exact Jaccard score, and cleaned exact Jaccard score.

### (b) Reduced representation

Storing every trigram set for 12,000 notices is larger than the desired retrieval representation. Each notice is therefore compressed into a 64-component MinHash signature.

The adopted signature size is:

* MinHash components: 64
* LSH bands: 16
* Rows per band: 4

The usual independent MinHash standard-error approximation is:

`1 / sqrt(64) = 0.125`

The 64-component signature is therefore a fixed-size approximation to the Jaccard similarity. The actual behaviour is checked against the 900 supplied labelled pairs rather than relying only on the theoretical approximation.

The final run also records the absolute error between exact cleaned Jaccard and the 64-component MinHash estimate: mean absolute error, p95 absolute error, and maximum absolute error. These values are under `estimator_metrics` in `metrics.json` and are the released-estimator error measurement required by the brief.

### (c) Candidate retrieval and asymmetric cost

The 64-component signature is split into 16 bands of 4 rows. Two notices become retrieval candidates when at least one corresponding band hashes to the same bucket.

The full deterministic run over all 12,000 notices produced:

* Mean candidates per notice: 1,463.73
* Candidate p95: 2,936
* Candidate maximum: 4,379
* Raw labelled candidate recall: 37.44%

The measured survival probability rises sharply with true Jaccard similarity:

| True similarity bin | Candidate survival |
| ------------------- | -----------------: |
| 0.15                |              0.61% |
| 0.25                |              0.00% |
| 0.35                |             12.12% |
| 0.45                |             36.69% |
| 0.55                |             65.29% |
| 0.65                |             96.00% |
| 0.75                |            100.00% |
| 0.85                |            100.00% |
| 0.95                |            100.00% |

Thus highly similar pairs are much more likely to survive the candidate stage, while lower-similarity pairs are frequently missed.

For the product-risk decision, this report assigns a numerical operating-cost ratio of 10:1: missing a genuine duplicate is treated as ten times more costly than creating additional candidate work. This encodes the board's asymmetric failure requirement as a number rather than an adjective. The chosen 16×4 configuration was retained because it completes the full corpus comfortably within the 20-minute budget while avoiding the much larger candidate explosion observed during the more permissive 32×2 experiment.

The 32×2 configuration was therefore treated as an experimental alternative, not as the final operating point.

The numeric risk setting is `missed_duplicate_cost_ratio = 10`: one missed genuine duplicate is priced as ten units of harm, while one additional candidate unit is priced as one. This ratio is exposed in `metrics.json`; it is why recall is preferred over the more aggressive common-bucket suppression, whose measured recall loss is reported below.

## B. Database and operations

### (d) Persistent access path

The retrieval structure is stored in a persistent SQLite database:

`solution/results/retrieval.sqlite`

The main retrieval tables are:

* `notices`
* `lsh_buckets`

The lookup structure is indexed on:

`(band, bucket)`

The indexed lookup planner reports:

`SEARCH lsh_buckets USING INDEX idx_lsh_bucket (band=? AND bucket=?)`

The forced alternative reports:

`SCAN lsh_buckets`

Measured lookup time in the final run was:

* Indexed lookup: 0.0000759 seconds
* Forced full scan: 0.010845 seconds

For the same probe bucket, the indexed query returned the matching rows directly, while the forced alternative examined all rows in `lsh_buckets`. The exact returned/examined counts are recorded as `indexed_rows_returned` and `forced_scan_rows_examined` in `metrics.json`.

The indexed path therefore directly locates matching bucket rows, while the rejected alternative scans the entire bucket table.

### (e) Skew, cost and mitigation

Candidate work is strongly uneven because some portals contribute many notices and repeated boilerplate. The highest-frequency portal is P094 with 1,426 notices. Several other portals also contribute hundreds of notices.

Important hot portals in the final run include:

| Portal | Notices |
| ------ | ------: |
| P094   |   1,426 |
| P002   |     800 |
| P006   |     792 |
| P001   |     778 |
| P003   |     772 |
| P005   |     768 |
| P004   |     755 |
| P020   |     384 |
| P240   |     377 |
| P044   |     224 |

Repeated portal boilerplate creates common trigram patterns. Those patterns cause many notices to fall into the same LSH buckets, increasing the candidate list size for the affected notices.

The mitigation suppresses buckets containing more than 100 notices.

Before mitigation:

* Mean candidates: 1,463.73
* p95: 2,936
* Maximum: 4,379
* Candidate recall: 37.44%

After mitigation:

* Mean candidates: 178.86
* p95: 323
* Maximum: 572
* Candidate recall: 22.78%

Therefore the mitigation reduces average candidate work by approximately 87.8%, but costs 14.66 percentage points of labelled candidate recall.

Retrieval wall-clock measurements were 61.04 seconds before mitigation and 8.61 seconds after mitigation. These are separate from the 65.11-second index-build time and make the before/after cost visible.

Because the assignment gives a much higher cost to missing a true duplicate, the 100-row suppression rule is not used as the sole production retrieval mechanism. It is treated as a workload-control mechanism whose recall cost must be measured and exposed.

## Stable opportunity identifiers

Public card IDs are deliberately separated from notice IDs.

The final database contains:

* Stable opportunity cards: 5,776
* Notice aliases: 12,000

A notice may therefore be absorbed into an existing opportunity without changing the public card ID.

A restart verification reopened the generated SQLite database and returned:

`cards = 5776`

`aliases = 12000`

Sample persistent mappings included:

`N000001 -> CARD-OPP000001`

`N000002 -> CARD-OPP000002`

`N000003 -> CARD-OPP000003`

`N000004 -> CARD-OPP000004`

`N000005 -> CARD-OPP000004`

This demonstrates that the mappings survive process restart and that bookmark-safe card IDs are independent of later notice ingestion.

## Final full-corpus measurements

| Metric                      | Final result |
| --------------------------- | -----------: |
| Notices                     |       12,000 |
| Labelled pairs              |          900 |
| Build time                  |      65.11 s |
| MinHash signature           |           64 |
| LSH bands                   |           16 |
| Rows per band               |            4 |
| Mean candidates             |     1,463.73 |
| Candidate p95               |        2,936 |
| Candidate maximum           |        4,379 |
| Raw candidate recall        |       37.44% |
| Mitigated mean candidates   |       178.86 |
| Mitigated candidate p95     |          323 |
| Mitigated candidate maximum |          572 |
| Mitigated candidate recall  |       22.78% |
| Raw retrieval time          |      61.04 s |
| Mitigated retrieval time    |       8.61 s |
| Indexed lookup time         |  0.0000759 s |
| Forced scan time            |   0.010845 s |
| Indexed rows returned       |           10 |
| Forced rows examined        |      192,000 |
| Stable cards                |        5,776 |
| Stable aliases              |       12,000 |

## Reproduction

Run the full experiment with:

```powershell
py -3 solution\q2_solution.py
```

Outputs are written under:

`solution/results/`

including:

* `metrics.json`
* `candidate_tradeoff.png`
* `retrieval.sqlite`

The final run processes the complete 12,000-notice corpus and regenerates the persistent retrieval database, measurements and tradeoff plot.
