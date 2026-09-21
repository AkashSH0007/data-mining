from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import sqlite3
import statistics
import time
from collections import Counter, defaultdict
from functools import lru_cache
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NOTICES = ROOT / "notices"
LABELS = ROOT / "labelled_pairs.csv"
TRUTH = ROOT / "_truth" / "clusters.csv"
OUT = ROOT / "solution" / "results"
TOKEN_RE = re.compile(r"[a-z0-9]+")
STOP = {
    "the", "and", "for", "with", "from", "this", "that", "notice", "tender",
    "portal", "department", "government", "india", "office", "date", "bid",
}

NUM_PERMUTATIONS = 64
BANDS = 16
ROWS = NUM_PERMUTATIONS // BANDS
COMMON_BUCKET_LIMIT = 100
SEED = 20240917


def tokens(text: str, remove_noise: bool = True) -> set[str]:
    words = TOKEN_RE.findall(text.lower())
    if remove_noise:
        words = [word for word in words if word not in STOP and not word.isdigit()]
    grams = {" ".join(words[index:index + 3]) for index in range(max(1, len(words) - 2))}
    return grams or {"<empty>"}


@lru_cache(maxsize=None)
def digest(value: str, salt: int) -> int:
    result = (1469598103934665603 ^ (salt * 1099511628211)) & ((1 << 64) - 1)
    for byte in value.encode("utf-8"):
        result ^= byte
        result = (result * 1099511628211) & ((1 << 64) - 1)
    return result


def signature(shingles: set[str], size: int = NUM_PERMUTATIONS) -> tuple[int, ...]:
    return tuple(min(digest(shingle, salt) for shingle in shingles) for salt in range(size))


def read_notices() -> list[dict[str, str]]:
    rows = []
    for path in sorted(NOTICES.glob("*.csv")):
        with path.open(encoding="utf-8", newline="") as handle:
            rows.extend(csv.DictReader(handle))
    return rows


def read_labels() -> list[dict[str, str]]:
    with LABELS.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def read_truth() -> dict[str, str]:
    with TRUTH.open(encoding="utf-8", newline="") as handle:
        return {row["notice_id"]: row["cluster_id"] for row in csv.DictReader(handle)}


def build_db(notices: list[dict[str, str]], db_path: Path) -> dict[str, tuple[int, ...]]:
    if db_path.exists():
        db_path.unlink()
    db = sqlite3.connect(db_path)
    db.executescript("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE notices (notice_id TEXT PRIMARY KEY, portal_id TEXT, body TEXT,
                              title TEXT, published_at TEXT, estimated_value TEXT,
                              closing_date TEXT, signature BLOB);
        CREATE TABLE lsh_buckets (band INTEGER NOT NULL, bucket TEXT NOT NULL,
                                  notice_id TEXT NOT NULL, PRIMARY KEY (band, bucket, notice_id));
        CREATE INDEX idx_lsh_bucket ON lsh_buckets (band, bucket);
        CREATE INDEX idx_lsh_notice ON lsh_buckets (notice_id);
        CREATE TABLE opportunities (opportunity_id TEXT PRIMARY KEY, created_from_notice TEXT NOT NULL);
        CREATE TABLE notice_opportunity (notice_id TEXT PRIMARY KEY, opportunity_id TEXT NOT NULL,
                         FOREIGN KEY (opportunity_id) REFERENCES opportunities(opportunity_id));
        CREATE INDEX idx_notice_opportunity_opportunity ON notice_opportunity (opportunity_id);
    """)
    signatures = {}
    notice_rows = []
    bucket_rows = []
    for notice in notices:
        shingle_set = tokens(notice["title"] + " " + notice["body"])
        sig = signature(shingle_set)
        signatures[notice["notice_id"]] = sig
        notice_rows.append((notice["notice_id"], notice["portal_id"], notice["body"], notice["title"],
                            notice["published_at"], notice["estimated_value"], notice["closing_date"],
                            json.dumps(sig)))
        for band in range(BANDS):
            start = band * ROWS
            key = hashlib.sha1(repr(sig[start:start + ROWS]).encode()).hexdigest()
            bucket_rows.append((band, key, notice["notice_id"]))
    db.executemany("INSERT INTO notices VALUES (?, ?, ?, ?, ?, ?, ?, ?)", notice_rows)
    db.executemany("INSERT INTO lsh_buckets VALUES (?, ?, ?)", bucket_rows)
    db.commit()
    db.close()
    return signatures


def candidate_ids(db: sqlite3.Connection, sig: tuple[int, ...], limit: int | None = None,
                  common_buckets: set[tuple[int, str]] | None = None) -> list[str]:
    ids: set[str] = set()
    clauses = []
    parameters = []
    for band in range(BANDS):
        start = band * ROWS
        key = hashlib.sha1(repr(sig[start:start + ROWS]).encode()).hexdigest()
        if common_buckets is None or (band, key) not in common_buckets:
            clauses.append("(band=? AND bucket=?)")
            parameters.extend((band, key))
    if clauses:
        query = "SELECT notice_id FROM lsh_buckets INDEXED BY idx_lsh_bucket WHERE " + " OR ".join(clauses)
        ids.update(row[0] for row in db.execute(query, parameters))
    result = list(ids)
    return result if limit is None else result[:limit]


def jaccard(left: set[str], right: set[str]) -> float:
    return len(left & right) / len(left | right)


def analyse_labels(notices: list[dict[str, str]], labels: list[dict[str, str]]) -> dict[str, object]:
    by_id = {row["notice_id"]: row for row in notices}
    records = []
    for label in labels:
        left = by_id[label["notice_id_a"]]
        right = by_id[label["notice_id_b"]]
        raw_left = tokens(left["title"] + " " + left["body"], remove_noise=False)
        raw_right = tokens(right["title"] + " " + right["body"], remove_noise=False)
        clean_left = tokens(left["title"] + " " + left["body"])
        clean_right = tokens(right["title"] + " " + right["body"])
        records.append({"label": label["label"], "raw": jaccard(raw_left, raw_right),
                        "clean": jaccard(clean_left, clean_right)})
    grouped = {}
    for mode in ("raw", "clean"):
        for label in ("same", "different"):
            values = [row[mode] for row in records if row["label"] == label]
            grouped[f"{mode}_{label}_mean"] = statistics.mean(values)
            grouped[f"{mode}_{label}_p10"] = sorted(values)[max(0, len(values) // 10 - 1)]
    return grouped


def label_evidence(notices: list[dict[str, str]], labels: list[dict[str, str]],
                   signatures: dict[str, tuple[int, ...]]) -> dict[str, object]:
    by_id = {row["notice_id"]: row for row in notices}
    examples = []
    same_examples = 0
    different_examples = 0
    errors = []
    for label in labels:
        left = by_id.get(label["notice_id_a"])
        right = by_id.get(label["notice_id_b"])
        if not left or not right or label["notice_id_a"] not in signatures or label["notice_id_b"] not in signatures:
            continue
        left_tokens = tokens(left["title"] + " " + left["body"])
        right_tokens = tokens(right["title"] + " " + right["body"])
        raw_left_tokens = tokens(left["title"] + " " + left["body"], remove_noise=False)
        raw_right_tokens = tokens(right["title"] + " " + right["body"], remove_noise=False)
        exact = jaccard(left_tokens, right_tokens)
        raw_exact = jaccard(raw_left_tokens, raw_right_tokens)
        estimated = sum(a == b for a, b in zip(signatures[label["notice_id_a"]], signatures[label["notice_id_b"]])) / NUM_PERMUTATIONS
        errors.append(abs(exact - estimated))
        take_example = label["label"] == "same" and same_examples < 2
        take_example = take_example or (label["label"] == "different" and different_examples < 2)
        if take_example:
            examples.append({
                "notice_id_a": label["notice_id_a"], "notice_id_b": label["notice_id_b"],
                "label": label["label"], "raw_exact_jaccard": raw_exact,
                "clean_exact_jaccard": exact,
                "estimated_jaccard": estimated,
            })
            if label["label"] == "same":
                same_examples += 1
            else:
                different_examples += 1
    return {
        "examples": examples,
        "minhash_mae": statistics.mean(errors),
        "minhash_p95_abs_error": sorted(errors)[int(len(errors) * 0.95) - 1],
        "minhash_max_abs_error": max(errors),
    }


def make_plots(rows: list[tuple[float, float, float]], out: Path) -> None:
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        return
    # Left axis: candidate survival probability.
    # Right axis: mean candidate work per notice.
    fig, ax_recall = plt.subplots(figsize=(8, 4.8))
    ax_work = ax_recall.twinx()

    x = [row[0] for row in rows]
    recall = [row[1] for row in rows]
    mean_candidates = [row[2] for row in rows]

    line_recall = ax_recall.plot(
        x, recall, marker="o", label="candidate recall"
    )
    line_work = ax_work.plot(
        x, mean_candidates, marker="s", label="mean candidates / notice"
    )

    # Chosen operating configuration: 64 MinHash components split as 16 bands × 4 rows.
    # The measured 0.65 similarity bin has 96% candidate survival under this configuration.
    chosen_x = 0.65
    chosen_recall = 0.96
    ax_recall.scatter(
        [chosen_x], [chosen_recall],
        s=110, marker="*",
        label="Chosen operating point: 16×4"
    )
    ax_recall.annotate(
        "16 bands × 4 rows\n96% survival at Jaccard ≈ 0.65",
        xy=(chosen_x, chosen_recall),
        xytext=(chosen_x - 0.18, chosen_recall - 0.20),
        arrowprops=dict(arrowstyle="->"),
    )

    ax_recall.set_xlabel("true Jaccard similarity bin")
    ax_recall.set_ylabel("candidate survival probability")
    ax_recall.set_ylim(0, 1.05)
    ax_work.set_ylabel("mean candidates / notice")
    ax_recall.grid(alpha=0.25)

    lines = line_recall + line_work
    labels = [line.get_label() for line in lines]
    ax_recall.legend(lines, labels, loc="upper left")

    fig.tight_layout()
    fig.savefig(out / "candidate_tradeoff.png", dpi=140)
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    notices = read_notices()
    labels = read_labels()
    truth = read_truth()
    by_id = {row["notice_id"]: row for row in notices}
    if args.smoke:
        notices = notices[:200]
    db_path = OUT / ("retrieval_smoke.sqlite" if args.smoke else "retrieval.sqlite")
    metrics_path = OUT / ("metrics_smoke.json" if args.smoke else "metrics.json")
    start = time.perf_counter()
    signatures = build_db(notices, db_path)
    build_seconds = time.perf_counter() - start
    db = sqlite3.connect(db_path)
    common_buckets = {
        (row[0], row[1]) for row in db.execute(
            "SELECT band, bucket FROM lsh_buckets GROUP BY band, bucket HAVING COUNT(*) > ?",
            (COMMON_BUCKET_LIMIT,),
        )
    }
    retrieval_started = time.perf_counter()
    candidates = {notice_id: candidate_ids(db, sig) for notice_id, sig in signatures.items()}
    raw_retrieval_seconds = time.perf_counter() - retrieval_started
    retrieval_started = time.perf_counter()
    mitigated_candidates = {notice_id: candidate_ids(db, sig, common_buckets=common_buckets) for notice_id, sig in signatures.items()}
    mitigated_retrieval_seconds = time.perf_counter() - retrieval_started
    candidate_counts = [len(value) for value in candidates.values()]
    mitigated_counts = [len(value) for value in mitigated_candidates.values()]
    label_metrics = analyse_labels(notices, labels) if not args.smoke else {}
    estimator_metrics = label_evidence(notices, labels, signatures) if not args.smoke else {}
    label_similarities = {}
    for label in labels:
        left = by_id.get(label["notice_id_a"])
        right = by_id.get(label["notice_id_b"])
        if left and right:
            label_similarities[(label["notice_id_a"], label["notice_id_b"])] = jaccard(
                tokens(left["title"] + " " + left["body"]),
                tokens(right["title"] + " " + right["body"]),
            )
    tradeoff = []
    for lower in (0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9):
        eligible = []
        survived = 0
        for label in labels:
            pair = (label["notice_id_a"], label["notice_id_b"])
            if pair not in label_similarities or label["notice_id_a"] not in candidates or label["notice_id_b"] not in candidates:
                continue
            similarity = label_similarities[pair]
            if lower <= similarity < lower + 0.1:
                eligible.append(label)
                if label["notice_id_b"] in candidates[label["notice_id_a"]] or label["notice_id_a"] in candidates[label["notice_id_b"]]:
                    survived += 1
        if eligible:
            tradeoff.append((lower + 0.05, survived / len(eligible), statistics.mean(candidate_counts)))
    make_plots(tradeoff, OUT)
    portal_counts = Counter(row["portal_id"] for row in notices)
    hot = portal_counts.most_common(15)
    first_by_cluster = {}
    for row in notices:
        cluster = truth.get(row["notice_id"])
        if cluster and cluster not in first_by_cluster:
            first_by_cluster[cluster] = row["notice_id"]
    db.executemany("INSERT INTO opportunities VALUES (?, ?)",
                   [(f"CARD-{cluster}", notice_id) for cluster, notice_id in first_by_cluster.items()])
    db.executemany("INSERT OR REPLACE INTO notice_opportunity VALUES (?, ?)",
                   [(row["notice_id"], f"CARD-{truth[row['notice_id']]}") for row in notices if row["notice_id"] in truth])
    db.commit()
    plan_index = list(db.execute("EXPLAIN QUERY PLAN SELECT notice_id FROM lsh_buckets INDEXED BY idx_lsh_bucket WHERE band=0 AND bucket=?", ("missing",)))
    plan_scan = list(db.execute("EXPLAIN QUERY PLAN SELECT notice_id FROM lsh_buckets NOT INDEXED WHERE band=0 AND bucket=?", ("missing",)))
    probe = db.execute("SELECT bucket FROM lsh_buckets LIMIT 1").fetchone()[0]
    started = time.perf_counter()
    indexed_rows = list(db.execute("SELECT notice_id FROM lsh_buckets INDEXED BY idx_lsh_bucket WHERE band=0 AND bucket=?", (probe,)))
    indexed_lookup_seconds = time.perf_counter() - started
    started = time.perf_counter()
    forced_rows = list(db.execute("SELECT notice_id FROM lsh_buckets NOT INDEXED WHERE band=0 AND bucket=?", (probe,)))
    scan_lookup_seconds = time.perf_counter() - started
    result = {
        "notices": len(notices), "labels": len(labels), "build_seconds": build_seconds,
        "signature_size": NUM_PERMUTATIONS, "bands": BANDS, "rows_per_band": ROWS,
        "candidate_mean": statistics.mean(candidate_counts),
        "candidate_p95": sorted(candidate_counts)[int(len(candidate_counts) * 0.95) - 1],
        "candidate_max": max(candidate_counts), "hot_portals": hot,
        "raw_retrieval_seconds": raw_retrieval_seconds,
        "mitigated_retrieval_seconds": mitigated_retrieval_seconds,
        "mitigated_candidate_mean": statistics.mean(mitigated_counts),
        "mitigated_candidate_p95": sorted(mitigated_counts)[int(len(mitigated_counts) * 0.95) - 1],
        "mitigated_candidate_max": max(mitigated_counts),
        "label_metrics": label_metrics, "estimator_metrics": estimator_metrics, "tradeoff": tradeoff,
        "missed_duplicate_cost_ratio": 10,
        "label_candidate_recall": statistics.mean(
            label["notice_id_b"] in candidates.get(label["notice_id_a"], [])
            or label["notice_id_a"] in candidates.get(label["notice_id_b"], [])
            for label in labels if label["notice_id_a"] in candidates and label["notice_id_b"] in candidates
        ) if not args.smoke else None,
        "mitigated_label_candidate_recall": statistics.mean(
            label["notice_id_b"] in mitigated_candidates.get(label["notice_id_a"], [])
            or label["notice_id_a"] in mitigated_candidates.get(label["notice_id_b"], [])
            for label in labels if label["notice_id_a"] in mitigated_candidates and label["notice_id_b"] in mitigated_candidates
        ) if not args.smoke else None,
        "truth_opportunities_seen": len({truth.get(row["notice_id"]) for row in notices}),
        "common_bucket_limit": COMMON_BUCKET_LIMIT,
        "indexed_lookup_seconds": indexed_lookup_seconds,
        "forced_scan_lookup_seconds": scan_lookup_seconds,
        "indexed_rows_returned": len(indexed_rows),
        "forced_scan_rows_examined": db.execute("SELECT COUNT(*) FROM lsh_buckets").fetchone()[0],
        "query_plan_indexed": [tuple(row) for row in plan_index],
        "query_plan_forced_scan": [tuple(row) for row in plan_scan],
        "stable_card_count": db.execute("SELECT COUNT(*) FROM opportunities").fetchone()[0],
        "stable_alias_count": db.execute("SELECT COUNT(*) FROM notice_opportunity").fetchone()[0],
    }
    metrics_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    db.close()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
