#!/usr/bin/env python3
"""
K8s pod stress test — measures CPU & RAM during progressively heavy workloads.
Jupyter-mode: all allocations kept alive across scenarios (no GC between "cells").

Scenarios (in order):
  1. DB aggregate queries (join depth 4-5)
  2. pandas load + groupby + correlation
  3. NumPy matmul / FFT / SVD
  4. matplotlib multi-panel plot
  5. extreme memory stress (OOM target)

Output: /tmp/stress_results.json + /tmp/stress_plot.png + /tmp/checkpoint_*.png

Run inside Jupyter:
  %run /home/jovyan/scripts/stress_test.py

Or kubectl exec:
  kubectl exec -n jupyter-experiment deploy/jupyter -- python /home/jovyan/scripts/stress_test.py

Watch cluster utilization alongside:
  kubectl top pods -n jupyter-experiment
  kubectl top nodes
"""

import json
import os
import time
import urllib.parse
from typing import Any

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import psutil
import psycopg2

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://courseuser:coursepass123@postgres-service:5432/coursedb",
)

RESULTS: list[dict] = []

# Jupyter-style kernel namespace: nothing is ever freed between "cells".
# Append every allocation here so GC cannot reclaim it.
_LIVE_REFS: list = []


# ── helpers ──────────────────────────────────────────────────────────────────

def _conn():
    p = urllib.parse.urlparse(DATABASE_URL)
    return psycopg2.connect(
        host=p.hostname, port=p.port or 5432,
        dbname=p.path.lstrip("/"), user=p.username, password=p.password,
    )


def measure(label: str):
    """Context manager: records elapsed time, RSS delta, and avg CPU% per phase."""
    class _Ctx:
        def __enter__(self):
            self._proc = psutil.Process()
            self._t0   = time.perf_counter()
            self._mem0 = self._proc.memory_info().rss / 1024 / 1024
            self._proc.cpu_percent(interval=None)
            return self

        def __exit__(self, *_):
            elapsed  = time.perf_counter() - self._t0
            mem1     = self._proc.memory_info().rss / 1024 / 1024
            cpu_pct  = self._proc.cpu_percent(interval=None)
            rec = {
                "label":        label,
                "elapsed_s":    round(elapsed, 3),
                "mem_start_mb": round(self._mem0, 1),
                "mem_end_mb":   round(mem1, 1),
                "mem_delta_mb": round(mem1 - self._mem0, 1),
                "cpu_pct":      round(cpu_pct, 1),
            }
            RESULTS.append(rec)
            print(
                f"  [{label}]  {elapsed:.3f}s  |  "
                f"RAM {self._mem0:.0f}→{mem1:.0f} MB  (Δ{mem1-self._mem0:+.1f})  |  "
                f"CPU {cpu_pct:.1f}%"
            )
            return False
    return _Ctx()


def _save_utilization_chart(suffix: str = ""):
    labels   = [r["label"] for r in RESULTS]
    cpu_vals = [r.get("cpu_pct", 0) for r in RESULTS]
    mem_vals = [r["mem_end_mb"] for r in RESULTS]
    x = range(len(labels))

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)

    ax1.bar(x, cpu_vals, color="steelblue")
    ax1.set_ylabel("CPU %")
    ax1.set_title("CPU Usage per Phase")
    for i, v in enumerate(cpu_vals):
        ax1.text(i, v + 0.5, f"{v:.1f}%", ha="center", fontsize=7)

    ax2.bar(x, mem_vals, color="darkorange")
    ax2.set_ylabel("RSS (MB)")
    ax2.set_title("Memory (RSS) per Phase — cumulative (Jupyter-style, no GC between cells)")
    ax2.set_xticks(list(x))
    ax2.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)
    for i, v in enumerate(mem_vals):
        ax2.text(i, v + 1, f"{v:.0f}", ha="center", fontsize=7)

    plt.tight_layout()
    path = f"/tmp/utilization_chart{suffix}.png"
    plt.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Utilization chart → {path}")


def _save_checkpoint(scenario: str):
    """Save updated utilization chart before starting a new scenario."""
    if not RESULTS:
        return
    _save_utilization_chart(suffix=f"_before_{scenario}")
    # Always overwrite the latest snapshot so the user has one stable path to watch.
    _save_utilization_chart(suffix="_latest")
    rss = psutil.Process().memory_info().rss / 1024 / 1024
    print(f"[checkpoint] before={scenario}  live_refs={len(_LIVE_REFS)}  RSS={rss:.0f} MB")


# ── scenario 1: database queries ─────────────────────────────────────────────

def run_db_scenarios(conn):
    print("\n=== DB QUERIES ===")

    with measure("db_avg_score_by_dept"):
        cur = conn.cursor()
        cur.execute("""
            SELECT d.name,
                   AVG(s.score / NULLIF(s.max_score_snapshot, 0) * 100) AS avg_pct,
                   COUNT(*) AS n_submissions
            FROM   submissions s
            JOIN   enrollments e  ON s.enrollment_id  = e.enrollment_id
            JOIN   students    st ON e.student_id      = st.student_id
            JOIN   departments d  ON st.department_id  = d.department_id
            GROUP  BY d.name
            ORDER  BY avg_pct DESC
        """)
        _LIVE_REFS.append(cur.fetchall())

    with measure("db_course_stats_join5"):
        cur = conn.cursor()
        cur.execute("""
            SELECT c.course_name, d.name AS dept,
                   AVG(e.final_score)         AS avg_final,
                   COUNT(DISTINCT e.student_id) AS students,
                   COUNT(s.submission_id)      AS submissions,
                   SUM(s.is_late::int)         AS late_subs,
                   AVG(s.score / NULLIF(s.max_score_snapshot,0)*100) AS avg_sub_pct
            FROM   courses     c
            JOIN   departments d  ON c.department_id   = d.department_id
            JOIN   enrollments e  ON c.course_id       = e.course_id
            JOIN   submissions s  ON e.enrollment_id   = s.enrollment_id
            JOIN   assignments a  ON s.assignment_id   = a.assignment_id
            GROUP  BY c.course_name, d.name
            ORDER  BY avg_final DESC NULLS LAST
        """)
        _LIVE_REFS.append(cur.fetchall())

    with measure("db_top_students_cte"):
        cur = conn.cursor()
        cur.execute("""
            WITH ranked AS (
                SELECT st.student_id,
                       st.first_name || ' ' || st.last_name AS full_name,
                       d.name AS dept,
                       COUNT(DISTINCT e.course_id)    AS courses_taken,
                       AVG(s.score / NULLIF(s.max_score_snapshot,0)*100) AS avg_score,
                       SUM(s.is_late::int)            AS late_count,
                       COUNT(s.submission_id)         AS total_subs
                FROM   students    st
                JOIN   departments d  ON st.department_id = d.department_id
                JOIN   enrollments e  ON st.student_id    = e.student_id
                JOIN   submissions s  ON e.enrollment_id  = s.enrollment_id
                GROUP  BY st.student_id, full_name, d.name
            )
            SELECT * FROM ranked
            WHERE  avg_score IS NOT NULL
            ORDER  BY avg_score DESC
            LIMIT  200
        """)
        _LIVE_REFS.append(cur.fetchall())

    with measure("db_assignment_difficulty"):
        cur = conn.cursor()
        cur.execute("""
            SELECT a.title, a.type, a.max_score,
                   COUNT(s.submission_id)  AS attempts,
                   AVG(s.score)            AS avg_raw,
                   STDDEV(s.score)         AS stddev_raw,
                   MIN(s.score)            AS min_score,
                   MAX(s.score)            AS max_score,
                   SUM(s.is_late::int)     AS late_count
            FROM   assignments a
            JOIN   submissions s ON a.assignment_id = s.assignment_id
            GROUP  BY a.assignment_id, a.title, a.type, a.max_score
            HAVING COUNT(s.submission_id) > 5
            ORDER  BY AVG(s.score) / NULLIF(a.max_score,0) ASC
            LIMIT  50
        """)
        _LIVE_REFS.append(cur.fetchall())

    with measure("db_window_func_running_avg"):
        cur = conn.cursor()
        cur.execute("""
            SELECT student_id,
                   submitted_at,
                   score,
                   AVG(score) OVER (
                       PARTITION BY student_id
                       ORDER BY submitted_at
                       ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
                   ) AS rolling_avg_5
            FROM (
                SELECT e.student_id, s.submitted_at, s.score
                FROM   submissions s
                JOIN   enrollments e ON s.enrollment_id = e.enrollment_id
                WHERE  s.submitted_at IS NOT NULL
            ) t
            ORDER BY student_id, submitted_at
            LIMIT 50000
        """)
        _LIVE_REFS.append(cur.fetchall())


# ── scenario 2: pandas ────────────────────────────────────────────────────────

def run_pandas_scenarios(conn) -> pd.DataFrame:
    print("\n=== PANDAS ===")
    df = pd.DataFrame()

    with measure("pandas_load_100k_join"):
        cur = conn.cursor()
        cur.execute("""
            SELECT s.submission_id,
                   s.score, s.max_score_snapshot,
                   s.is_late, s.submitted_at,
                   a.type AS assign_type, a.weight,
                   e.final_score, e.status AS enroll_status,
                   st.year_level, st.gpa,
                   d.name AS dept,
                   c.credits
            FROM   submissions s
            JOIN   enrollments e  ON s.enrollment_id  = e.enrollment_id
            JOIN   students    st ON e.student_id      = st.student_id
            JOIN   departments d  ON st.department_id  = d.department_id
            JOIN   assignments a  ON s.assignment_id   = a.assignment_id
            JOIN   courses     c  ON a.course_id       = c.course_id
            LIMIT  100000
        """)
        cols = [desc[0] for desc in cur.description]
        df = pd.DataFrame(cur.fetchall(), columns=cols)
        _LIVE_REFS.append(df)

    with measure("pandas_feature_engineering"):
        df["score_pct"] = df["score"] / df["max_score_snapshot"].replace(0, np.nan) * 100
        df["submitted_at"] = pd.to_datetime(df["submitted_at"])
        df["submit_hour"]  = df["submitted_at"].dt.hour
        df["submit_dow"]   = df["submitted_at"].dt.dayofweek
        # df is already in _LIVE_REFS — mutations are reflected automatically

    with measure("pandas_groupby_agg"):
        grouped = df.groupby(["dept", "assign_type"]).agg(
            avg_score  =("score_pct",    "mean"),
            median     =("score_pct",    "median"),
            std        =("score_pct",    "std"),
            count      =("submission_id","count"),
            late_rate  =("is_late",      "mean"),
            avg_gpa    =("gpa",          "mean"),
        ).reset_index()
        _LIVE_REFS.append(grouped)

    with measure("pandas_pivot_table"):
        pivot = df.pivot_table(
            index="dept", columns="assign_type",
            values="score_pct", aggfunc="mean",
        )
        _LIVE_REFS.append(pivot)

    with measure("pandas_corr_matrix"):
        numeric_cols = ["score_pct", "final_score", "gpa", "year_level",
                        "weight", "credits", "submit_hour"]
        corr = df[numeric_cols].dropna().corr()
        _LIVE_REFS.append(corr)

    with measure("pandas_resample_timeseries"):
        ts = (
            df.set_index("submitted_at")["score_pct"]
            .dropna()
            .sort_index()
            .resample("1D")
            .agg(["mean", "count"])
        )
        _LIVE_REFS.append(ts)

    return df


# ── scenario 3: numpy ─────────────────────────────────────────────────────────

def run_numpy_scenarios(df: pd.DataFrame):
    print("\n=== NUMPY ===")
    scores = df["score_pct"].fillna(50).to_numpy(dtype=np.float64)
    _LIVE_REFS.append(scores)

    with measure("numpy_matmul_1000x1000"):
        A = np.random.randn(1_000, 1_000).astype(np.float64)
        B = np.random.randn(1_000, 1_000).astype(np.float64)
        C = A @ B
        _LIVE_REFS.extend([A, B, C])

    with measure("numpy_fft_100k"):
        fft_out = np.fft.fft(scores)
        _LIVE_REFS.append(fft_out)

    with measure("numpy_svd_500x200"):
        n = (min(len(scores), 100_000) // 200) * 200
        M = scores[:n].reshape(-1, 200)
        U, s, Vt = np.linalg.svd(M, full_matrices=False)
        _LIVE_REFS.extend([M, U, s, Vt])

    with measure("numpy_eig_500x500"):
        S = np.random.randn(500, 500)
        S = S @ S.T
        eigs = np.linalg.eigvalsh(S)
        _LIVE_REFS.extend([S, eigs])

    with measure("numpy_bootstrap_ci"):
        rng = np.random.default_rng(0)
        means = np.array([rng.choice(scores, size=10_000, replace=True).mean()
                          for _ in range(2_000)])
        ci = np.percentile(means, [2.5, 97.5])
        _LIVE_REFS.extend([means, ci])


# ── scenario 4: matplotlib ────────────────────────────────────────────────────

def run_matplotlib_scenarios(df: pd.DataFrame):
    print("\n=== MATPLOTLIB ===")

    with measure("matplotlib_6panel_plot"):
        fig, axes = plt.subplots(2, 3, figsize=(16, 10))

        axes[0, 0].hist(df["score_pct"].dropna(), bins=60,
                        color="steelblue", edgecolor="white", alpha=0.8)
        axes[0, 0].set_title("Score Distribution (%)")
        axes[0, 0].set_xlabel("Score (%)")

        dept_avg = df.groupby("dept")["score_pct"].mean().sort_values()
        axes[0, 1].barh(dept_avg.index, dept_avg.values, color="coral")
        axes[0, 1].set_title("Avg Score by Department")
        axes[0, 1].set_xlabel("Avg Score (%)")

        type_counts = df["assign_type"].value_counts()
        axes[0, 2].pie(type_counts.values, labels=type_counts.index,
                       autopct="%1.1f%%", startangle=90)
        axes[0, 2].set_title("Assignment Types")

        _pool  = df.dropna(subset=["gpa", "score_pct"])
        sample = _pool.sample(min(5_000, len(_pool)), random_state=0)
        axes[1, 0].scatter(sample["gpa"], sample["score_pct"],
                           alpha=0.2, s=4, color="teal")
        axes[1, 0].set_title("GPA vs Score")
        axes[1, 0].set_xlabel("GPA")
        axes[1, 0].set_ylabel("Score (%)")

        late_by_hour = df.groupby("submit_hour")["is_late"].mean()
        axes[1, 1].bar(late_by_hour.index, late_by_hour.values, color="salmon")
        axes[1, 1].set_title("Late Rate by Submit Hour")
        axes[1, 1].set_xlabel("Hour of Day")
        axes[1, 1].set_ylabel("Late Rate")

        numeric_cols = ["score_pct", "final_score", "gpa", "year_level", "weight"]
        corr = df[numeric_cols].dropna().corr()
        im = axes[1, 2].imshow(corr.values, cmap="coolwarm", vmin=-1, vmax=1)
        axes[1, 2].set_xticks(range(len(corr.columns)))
        axes[1, 2].set_yticks(range(len(corr.columns)))
        axes[1, 2].set_xticklabels(corr.columns, rotation=45, ha="right")
        axes[1, 2].set_yticklabels(corr.columns)
        axes[1, 2].set_title("Correlation Heatmap")
        fig.colorbar(im, ax=axes[1, 2])

        plt.tight_layout()
        plt.savefig("/tmp/stress_plot.png", dpi=150, bbox_inches="tight")
        # Keep figure alive — Jupyter inline display holds figure objects in kernel.
        _LIVE_REFS.append(fig)
        _LIVE_REFS.extend([axes, dept_avg, type_counts, sample, late_by_hour, corr])
        print("  Plot saved → /tmp/stress_plot.png")


# ── summary ───────────────────────────────────────────────────────────────────

def print_summary():
    print("\n" + "=" * 75)
    print(f"{'Operation':<38} {'Time(s)':>8} {'MemΔ(MB)':>10} {'CPU%':>8}")
    print("-" * 75)
    for r in RESULTS:
        print(
            f"{r['label']:<38} {r['elapsed_s']:>8.3f} "
            f"{r['mem_delta_mb']:>10.1f} {r.get('cpu_pct', 0):>8.1f}"
        )

    peak_mem = max(r["mem_end_mb"] for r in RESULTS)
    base_mem = RESULTS[0]["mem_start_mb"]
    total_t  = sum(r["elapsed_s"] for r in RESULTS)
    peak_cpu = max(r.get("cpu_pct", 0) for r in RESULTS)
    print("-" * 75)
    print(f"{'TOTAL':<38} {total_t:>8.3f}")
    print(
        f"\nBase RSS: {base_mem:.0f} MB  |  Peak RSS: {peak_mem:.0f} MB  |  "
        f"Δ: {peak_mem-base_mem:.0f} MB  |  Peak CPU: {peak_cpu:.1f}%"
    )
    print(f"Live refs held: {len(_LIVE_REFS)}  (Jupyter-style: none freed)")

    _save_utilization_chart()
    _save_utilization_chart(suffix="_latest")

    print("\nFor cluster-level metrics run:")
    print("  kubectl top pods -n jupyter-experiment")
    print("  kubectl top nodes")

    with open("/tmp/stress_results.json", "w") as f:
        json.dump(RESULTS, f, indent=2)
    print("\nJSON results → /tmp/stress_results.json")


# ── scenario 5: extreme memory stress ────────────────────────────────────────

def run_extreme_stress(df: pd.DataFrame):
    print("\n=== EXTREME MEMORY STRESS (target: OOM @ 4Gi) ===")
    # Reuses _LIVE_REFS — all prior allocations already pinned above.

    with measure("extreme_matmul_7000x7000"):
        A = np.random.randn(7_000, 7_000).astype(np.float64)
        B = np.random.randn(7_000, 7_000).astype(np.float64)
        C = A @ B
        _LIVE_REFS.extend([A, B, C])

    with measure("extreme_svd_6000x6000"):
        M = np.random.randn(6_000, 6_000).astype(np.float64)
        U, s, Vt = np.linalg.svd(M, full_matrices=True)
        _LIVE_REFS.extend([M, U, s, Vt])

    with measure("extreme_pandas_tile_40x"):
        big_df = pd.concat([df] * 40, ignore_index=True)
        _LIVE_REFS.append(big_df)
        print(f"    tiled df shape: {big_df.shape}")

    with measure("extreme_cross_join_4k"):
        chunk = df[["score_pct", "gpa"]].dropna().head(4_000).reset_index(drop=True)
        chunk["_key"] = 1
        exploded = chunk.merge(chunk, on="_key", suffixes=("_l", "_r")).drop(columns="_key")
        _LIVE_REFS.append(exploded)
        print(f"    cross-join shape: {exploded.shape}")

    with measure("extreme_oom_slab_accumulator"):
        SLAB_BYTES = 512 * 1024 * 1024
        SLAB_ELEMS = SLAB_BYTES // 8
        slab_n = 0
        while True:
            _LIVE_REFS.append(np.ones(SLAB_ELEMS, dtype=np.float64))
            slab_n += 1
            used_mb = psutil.Process().memory_info().rss / 1024 / 1024
            print(f"    slab {slab_n}: +512 MB  total RSS {used_mb:.0f} MB", flush=True)


# ── entrypoint ────────────────────────────────────────────────────────────────

def main():
    print(f"Connecting to: {DATABASE_URL.split('@')[-1]}")
    conn = _conn()

    # Checkpoint saved before each scenario so plots reflect state at entry.
    _save_checkpoint("db")
    run_db_scenarios(conn)

    _save_checkpoint("pandas")
    df = run_pandas_scenarios(conn)

    _save_checkpoint("numpy")
    run_numpy_scenarios(df)

    _save_checkpoint("matplotlib")
    run_matplotlib_scenarios(df)

    conn.close()
    # Summary + charts saved before extreme stress — in case OOM-kill happens mid-run.
    print_summary()

    _save_checkpoint("extreme")
    run_extreme_stress(df)


if __name__ == "__main__":
    main()
