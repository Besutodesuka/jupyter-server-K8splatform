# Database — Coursework Dataset

## Overview

PostgreSQL 15 pod in namespace `jupyter-experiment`.
Schema models a university coursework system with ~100k rows in the `submissions` table for stress-testing purposes.

**Connection string (cluster-internal):**
```
postgresql://courseuser:coursepass123@postgres-service:5432/coursedb
```

**Local access via port-forward:**
```bash
kubectl port-forward -n jupyter-experiment svc/postgres-service 5432:5432
psql -h localhost -U courseuser -d coursedb
```

---

## Schema

### Entity Relationship

```
departments ──< instructors
departments ──< students
departments ──< courses
instructors ──< courses
students    ──< enrollments >── courses
courses     ──< assignments
enrollments ──< submissions >── assignments
```

### Tables

#### `departments`
| Column | Type | Notes |
|---|---|---|
| `department_id` | SERIAL PK | |
| `name` | VARCHAR(100) UNIQUE | |
| `code` | VARCHAR(10) UNIQUE | e.g. `CS`, `MATH` |
| `faculty` | VARCHAR(100) | e.g. `Faculty of Engineering` |

Seeded with 10 departments across Engineering, Science, Business, Social Sciences, Humanities.

---

#### `instructors`
| Column | Type | Notes |
|---|---|---|
| `instructor_id` | SERIAL PK | |
| `first_name` | VARCHAR(50) | |
| `last_name` | VARCHAR(50) | |
| `email` | VARCHAR(100) UNIQUE | |
| `department_id` | INT FK → departments | |
| `title` | VARCHAR(50) | Prof. / Dr. / Assoc. Prof. / etc. |

50 rows.

---

#### `students`
| Column | Type | Notes |
|---|---|---|
| `student_id` | SERIAL PK | |
| `uuid` | UUID | unique, auto-generated |
| `first_name` | VARCHAR(50) | |
| `last_name` | VARCHAR(50) | |
| `email` | VARCHAR(100) UNIQUE | |
| `date_of_birth` | DATE | age 17–32 |
| `enrollment_date` | DATE | within last 4 years |
| `department_id` | INT FK → departments | |
| `year_level` | SMALLINT | 1–4 CHECK |
| `gpa` | NUMERIC(3,2) | 0–4 CHECK |
| `status` | VARCHAR(20) | `active` / `graduated` / `withdrawn` / `suspended` |

2,000 rows. Status distribution: 70% active, 20% graduated, 7% withdrawn, 3% suspended.

---

#### `courses`
| Column | Type | Notes |
|---|---|---|
| `course_id` | SERIAL PK | |
| `course_code` | VARCHAR(20) UNIQUE | e.g. `CS301-42` |
| `course_name` | VARCHAR(200) | |
| `department_id` | INT FK → departments | |
| `credits` | SMALLINT | 1–4 CHECK |
| `instructor_id` | INT FK → instructors | |
| `max_students` | INT | 20–60 |
| `description` | TEXT | |
| `semester` | VARCHAR(20) | Spring / Summer / Fall |
| `academic_year` | INT | 2021–2025 |

200 rows.

---

#### `enrollments`
| Column | Type | Notes |
|---|---|---|
| `enrollment_id` | SERIAL PK | |
| `student_id` | INT FK → students CASCADE | |
| `course_id` | INT FK → courses CASCADE | |
| `enrolled_at` | TIMESTAMP | |
| `final_grade` | CHAR(2) | A+ / A / B+ … / F |
| `final_score` | NUMERIC(5,2) | 0–100 CHECK |
| `status` | VARCHAR(20) | `enrolled` / `completed` / `dropped` / `failed` |

UNIQUE(student_id, course_id).
~10,000 rows. Avg 5 enrollments per student (Gaussian, σ=2).
Distribution: 50% completed, 30% enrolled, 15% dropped, 5% failed.

---

#### `assignments`
| Column | Type | Notes |
|---|---|---|
| `assignment_id` | SERIAL PK | |
| `course_id` | INT FK → courses CASCADE | |
| `title` | VARCHAR(200) | |
| `description` | TEXT | |
| `type` | VARCHAR(50) | `homework` / `quiz` / `midterm` / `final` / `project` / `lab` |
| `due_date` | TIMESTAMP | |
| `max_score` | NUMERIC(5,2) | 10 / 20 / 25 / 50 / 100 (midterm/final always 100) |
| `weight` | NUMERIC(4,2) | 5–30% CHECK |
| `created_at` | TIMESTAMP | |

~1,000 rows. Avg 5 assignments per course (Gaussian, σ=2).

---

#### `submissions` — main stress table
| Column | Type | Notes |
|---|---|---|
| `submission_id` | SERIAL PK | |
| `enrollment_id` | INT FK → enrollments CASCADE | |
| `assignment_id` | INT FK → assignments CASCADE | |
| `submitted_at` | TIMESTAMP | within last year |
| `score` | NUMERIC(5,2) | ≥ 0 CHECK |
| `max_score_snapshot` | NUMERIC(5,2) | denormalized from assignment at submit time |
| `feedback` | TEXT | nullable, 30% populated |
| `is_late` | BOOLEAN | 10% rate |
| `attempt_number` | SMALLINT | default 1 |

UNIQUE(enrollment_id, assignment_id, attempt_number).
**~100,000 rows** (hard target in generator). Score distribution: Beta(5,2) skewed toward higher scores.

---

## Indexes

```sql
idx_enrollments_student    ON enrollments(student_id)
idx_enrollments_course     ON enrollments(course_id)
idx_submissions_enrollment ON submissions(enrollment_id)
idx_submissions_assignment ON submissions(assignment_id)
idx_submissions_submitted  ON submissions(submitted_at)
idx_students_dept          ON students(department_id)
idx_courses_dept           ON courses(department_id)
```

---

## Data Generation

**Script:** `provisioning/experiment/scripts/generate_data.py`

**Dependencies:**
```bash
pip install psycopg2-binary faker
```

**Run:**
```bash
# port-forward first
kubectl port-forward -n jupyter-experiment svc/postgres-service 5432:5432

python provisioning/experiment/scripts/generate_data.py \
  --host localhost --port 5432 \
  --db coursedb --user courseuser --password coursepass123
```

Behavior:
- Truncates all tables (`RESTART IDENTITY CASCADE`) before inserting — safe to re-run
- Inserts in batches of 1,000 rows with mid-run progress output
- Score distributions use `Beta(5,2)` to mimic real grade curves (skewed high)
- Runtime: ~2–3 min on a local machine

**Row counts after generation:**

| Table | Target rows |
|---|---|
| departments | 10 |
| instructors | 50 |
| students | 2,000 |
| courses | 200 |
| enrollments | ~10,000 |
| assignments | ~1,000 |
| submissions | **100,000** |

---

## Useful Queries

```sql
-- row counts
SELECT relname, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;

-- avg score % by department
SELECT d.name,
       AVG(s.score / NULLIF(s.max_score_snapshot,0)*100) AS avg_pct,
       COUNT(*) AS submissions
FROM submissions s
JOIN enrollments e ON s.enrollment_id = e.enrollment_id
JOIN students st   ON e.student_id = st.student_id
JOIN departments d ON st.department_id = d.department_id
GROUP BY d.name ORDER BY avg_pct DESC;

-- table sizes on disk
SELECT relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC;
```
