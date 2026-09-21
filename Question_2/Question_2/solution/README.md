# Question 2 solution

Run the reproducible analysis with:

```powershell
py -3 solution\q2_solution.py
```

The script reads all notice CSV files, builds a persistent SQLite retrieval index, evaluates the supplied labelled pairs, writes `solution/results/metrics.json`, and writes `solution/results/candidate_tradeoff.png`.

## Design decisions

- A notice is represented by lower-cased word trigrams from title plus body. Portal boilerplate, common procurement words, and standalone numeric tokens are excluded. Reference numbers, dates, and money are therefore not treated as primary identity signals; the parsed monetary value and dates remain available in the relational notice row for later verification.
- Similarity is Jaccard similarity of the trigram sets. The estimator is a 64-component MinHash signature, selected as a compact representation whose expected Jaccard standard error is approximately `1 / sqrt(64) = 0.125` per pair. The labels and the generated metrics are the evidence for whether that accuracy is adequate.
- Candidate retrieval is banded locality-sensitive hashing. The measured operating point uses 16 bands of 4 rows. A candidate survives when at least one band is identical. The tradeoff plot records survival by measured similarity bin.
- The lookup data is relational and restart-safe: `notices` stores source data and signatures; `lsh_buckets` stores one row per band bucket and notice. The lookup uses the composite primary key/index on `(band, bucket, notice_id)`, rather than scanning all signatures in Python.
- Opportunity/card identity must be assigned once and retained in an `opportunities` table, with a `notice_opportunity` alias table. New copies attach to the existing opportunity; they never replace its immutable card identifier. The current retrieval database is the candidate-stage store and leaves final adjudication separate because false merges are more costly than duplicate cards.

The report should be read together with `results/metrics.json`: it contains the measured corpus size, label separation, candidate-list distribution, operating point, and hot-portal skew. The first correlated-hash implementation is intentionally retained in the development history as a rejected baseline because its measured labelled recall was only 18%.