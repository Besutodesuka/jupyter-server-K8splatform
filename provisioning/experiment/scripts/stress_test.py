#!/usr/bin/env python3
"""
K8s pod stress test — measures CPU & RAM during progressively heavy workloads.

Scenarios (in order):
  1. DB aggregate queries (join depth 4-5)
  2. pandas load + groupby + correlation
  3. NumPy matmul / FFT / SVD
  4. matplotlib multi-panel plot

Output: /tmp/stress_results.json + /tmp/stress_plot.png

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


# ── helpers ──────────────────────────────────────────────────────────────────

def _conn():
    p = urllib.parse.urlparse(DATABASE_URL)
    return psycopg2.connect(
        host=p.hostname, port=p.port or 5432,
        dbname=p.path.lstrip("/"), user=p.username, password=p.password,
    )


def measure(label: str):
    """Decorator / context manager that records elapsed time + RSS delta."""
    class _Ctx:
        def __enter__(self):
            self._proc = psutil.Process()
            self._t0   = time.perf_counter()
            self._mem0 = self._proc.memory_info().rss / 1024 / 1024
            return self

        def __exit__(self, *_):
            elapsed = time.perf_counter() - self._t0
            mem1    = self._proc.memory_info().rss / 1024 / 1024
            rec = {
                "label":       label,
                "elapsed_s":   round(elapsed, 3),
                "mem_start_mb": round(self._mem0, 1),
                "mem_end_mb":   round(mem1, 1),
                "mem_delta_mb": round(mem1 - self._mem0, 1),
            }
            RESULTS.append(rec)
            print(
                f"  [{label}]  {elapsed:.3f}s  |  "
                f"RAM {self._mem0:.0f}→{mem1:.0f} MB  (Δ{mem1-self._mem0:+.1f})"
            )
            return False  # don't suppress exceptions
    return _Ctx()


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
        cur.fetchall()

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
        cur.fetchall()

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
        cur.fetchall()

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
            ORDER  BY avg_raw / NULLIF(a.max_score,0) ASC
            LIMIT  50
        """)
        cur.fetchall()

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
        cur.fetchall()


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

    with measure("pandas_feature_engineering"):
        df["score_pct"] = df["score"] / df["max_score_snapshot"].replace(0, np.nan) * 100
        df["submitted_at"] = pd.to_datetime(df["submitted_at"])
        df["submit_hour"]  = df["submitted_at"].dt.hour
        df["submit_dow"]   = df["submitted_at"].dt.dayofweek

    with measure("pandas_groupby_agg"):
        _ = df.groupby(["dept", "assign_type"]).agg(
            avg_score  =("score_pct",   "mean"),
            median     =("score_pct",   "median"),
            std        =("score_pct",   "std"),
            count      =("submission_id","count"),
            late_rate  =("is_late",     "mean"),
            avg_gpa    =("gpa",         "mean"),
        ).reset_index()

    with measure("pandas_pivot_table"):
        _ = df.pivot_table(
            index="dept", columns="assign_type",
            values="score_pct", aggfunc="mean",
        )

    with measure("pandas_corr_matrix"):
        numeric_cols = ["score_pct", "final_score", "gpa", "year_level",
                        "weight", "credits", "submit_hour"]
        corr = df[numeric_cols].dropna().corr()

    with measure("pandas_resample_timeseries"):
        ts = (
            df.set_index("submitted_at")["score_pct"]
            .dropna()
            .sort_index()
            .resample("1D")
            .agg(["mean", "count"])
        )

    return df


# ── scenario 3: numpy ─────────────────────────────────────────────────────────

def run_numpy_scenarios(df: pd.DataFrame):
    print("\n=== NUMPY ===")
    scores = df["score_pct"].fillna(50).values

    with measure("numpy_matmul_1000x1000"):
        A = np.random.randn(1_000, 1_000).astype(np.float64)
        B = np.random.randn(1_000, 1_000).astype(np.float64)
        _ = A @ B

    with measure("numpy_fft_100k"):
        _ = np.fft.fft(scores)

    with measure("numpy_svd_500x200"):
        M = scores[:100_000].reshape(500, 200)
        _ = np.linalg.svd(M, full_matrices=False)

    with measure("numpy_eig_500x500"):
        S = np.random.randn(500, 500)
        S = S @ S.T  # symmetric
        _ = np.linalg.eigvalsh(S)

    with measure("numpy_bootstrap_ci"):
        rng = np.random.default_rng(0)
        means = [rng.choice(scores, size=10_000, replace=True).mean()
                 for _ in range(2_000)]
        ci = np.percentile(means, [2.5, 97.5])


# ── scenario 4: matplotlib ────────────────────────────────────────────────────

def run_matplotlib_scenarios(df: pd.DataFrame):
    print("\n=== MATPLOTLIB ===")

    with measure("matplotlib_6panel_plot"):
        fig, axes = plt.subplots(2, 3, figsize=(16, 10))

        # 1. score distribution
        axes[0, 0].hist(df["score_pct"].dropna(), bins=60,
                        color="steelblue", edgecolor="white", alpha=0.8)
        axes[0, 0].set_title("Score Distribution (%)")
        axes[0, 0].set_xlabel("Score (%)")

        # 2. avg score by dept
        dept_avg = df.groupby("dept")["score_pct"].mean().sort_values()
        axes[0, 1].barh(dept_avg.index, dept_avg.values, color="coral")
        axes[0, 1].set_title("Avg Score by Department")
        axes[0, 1].set_xlabel("Avg Score (%)")

        # 3. assignment type distribution
        type_counts = df["assign_type"].value_counts()
        axes[0, 2].pie(type_counts.values, labels=type_counts.index,
                       autopct="%1.1f%%", startangle=90)
        axes[0, 2].set_title("Assignment Types")

        # 4. GPA vs score scatter (sample 5k)
        sample = df.dropna(subset=["gpa", "score_pct"]).sample(5_000, random_state=0)
        axes[1, 0].scatter(sample["gpa"], sample["score_pct"],
                           alpha=0.2, s=4, color="teal")
        axes[1, 0].set_title("GPA vs Score")
        axes[1, 0].set_xlabel("GPA")
        axes[1, 0].set_ylabel("Score (%)")

        # 5. late submission rate by hour
        late_by_hour = df.groupby("submit_hour")["is_late"].mean()
        axes[1, 1].bar(late_by_hour.index, late_by_hour.values, color="salmon")
        axes[1, 1].set_title("Late Rate by Submit Hour")
        axes[1, 1].set_xlabel("Hour of Day")
        axes[1, 1].set_ylabel("Late Rate")

        # 6. correlation heatmap
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
        plt.close()
        print("  Plot saved → /tmp/stress_plot.png")


# ── summary ───────────────────────────────────────────────────────────────────

def print_summary():
    print("\n" + "=" * 65)
    print(f"{'Operation':<38} {'Time(s)':>8} {'MemΔ(MB)':>10}")
    print("-" * 65)
    for r in RESULTS:
        print(f"{r['label']:<38} {r['elapsed_s']:>8.3f} {r['mem_delta_mb']:>10.1f}")

    peak_mem = max(r["mem_end_mb"] for r in RESULTS)
    base_mem = RESULTS[0]["mem_start_mb"]
    total_t  = sum(r["elapsed_s"] for r in RESULTS)
    print("-" * 65)
    print(f"{'TOTAL':<38} {total_t:>8.3f}")
    print(f"\nBase RSS: {base_mem:.0f} MB  |  Peak RSS: {peak_mem:.0f} MB  |  Δ: {peak_mem-base_mem:.0f} MB")
    print("\nFor cluster-level metrics run:")
    print("  kubectl top pods -n jupyter-experiment")
    print("  kubectl top nodes")

    with open("/tmp/stress_results.json", "w") as f:
        json.dump(RESULTS, f, indent=2)
    print("\nJSON results → /tmp/stress_results.json")


# ── entrypoint ────────────────────────────────────────────────────────────────

def main():
    print(f"Connecting to: {DATABASE_URL.split('@')[-1]}")
    conn = _conn()

    run_db_scenarios(conn)
    df = run_pandas_scenarios(conn)
    run_numpy_scenarios(df)
    run_matplotlib_scenarios(df)

    conn.close()
    print_summary()


if __name__ == "__main__":
    main()
