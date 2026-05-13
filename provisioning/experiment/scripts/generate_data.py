#!/usr/bin/env python3
"""
Coursework dataset generator — targets ~100k rows in submissions table.

Usage:
  pip install psycopg2-binary faker
  python generate_data.py [--host HOST] [--port PORT] [--db DB] [--user USER] [--password PASS]

Run inside cluster:
  kubectl port-forward -n jupyter-experiment svc/postgres-service 5432:5432
  python generate_data.py  # defaults hit localhost:5432
"""

import argparse
import random
import time
from datetime import datetime
import psycopg2
from psycopg2.extras import execute_values
from faker import Faker

fake = Faker()
random.seed(42)
Faker.seed(42)

DEPARTMENTS = [
    ("Computer Science",   "CS",   "Faculty of Engineering"),
    ("Mathematics",        "MATH", "Faculty of Science"),
    ("Physics",            "PHYS", "Faculty of Science"),
    ("Biology",            "BIO",  "Faculty of Science"),
    ("Chemistry",          "CHEM", "Faculty of Science"),
    ("Economics",          "ECON", "Faculty of Business"),
    ("Psychology",         "PSYC", "Faculty of Social Sciences"),
    ("History",            "HIST", "Faculty of Humanities"),
    ("Literature",         "LIT",  "Faculty of Humanities"),
    ("Statistics",         "STAT", "Faculty of Science"),
]

ASSIGNMENT_TYPES = ["homework", "quiz", "midterm", "final", "project", "lab"]
GRADE_MAP = [(90,"A+"),(85,"A"),(80,"A-"),(75,"B+"),(70,"B"),(65,"B-"),(60,"C+"),(55,"C"),(50,"C-"),(0,"F")]

N_STUDENTS    = 2_000
N_INSTRUCTORS = 50
N_COURSES     = 200
AVG_ENROLL    = 5    # enrollments per student
AVG_ASSIGN    = 5    # assignments per course
TARGET_SUBS   = 100_000
BATCH         = 1_000


def score_to_grade(score: float) -> str:
    for threshold, grade in GRADE_MAP:
        if score >= threshold:
            return grade
    return "F"


def connect(args) -> psycopg2.extensions.connection:
    return psycopg2.connect(
        host=args.host, port=args.port,
        dbname=args.db, user=args.user, password=args.password,
    )


def truncate_all(cur):
    cur.execute("""
        TRUNCATE TABLE submissions, assignments, enrollments,
                       courses, students, instructors, departments
        RESTART IDENTITY CASCADE
    """)


def seed_departments(cur):
    rows = [(n, c, f) for n, c, f in DEPARTMENTS]
    execute_values(cur, "INSERT INTO departments (name, code, faculty) VALUES %s", rows)
    cur.execute("SELECT department_id FROM departments ORDER BY department_id")
    return [r[0] for r in cur.fetchall()]


def seed_instructors(cur, dept_ids):
    rows = [
        (fake.first_name(), fake.last_name(), fake.unique.email(), random.choice(dept_ids),
         random.choice(["Prof.", "Dr.", "Assoc. Prof.", "Asst. Prof.", "Lecturer"]))
        for _ in range(N_INSTRUCTORS)
    ]
    execute_values(cur, """
        INSERT INTO instructors (first_name, last_name, email, department_id, title)
        VALUES %s RETURNING instructor_id
    """, rows)
    return [r[0] for r in cur.fetchall()]


def seed_students(cur, dept_ids):
    rows = []
    for _ in range(N_STUDENTS):
        rows.append((
            fake.first_name(),
            fake.last_name(),
            fake.unique.email(),
            fake.date_of_birth(minimum_age=17, maximum_age=32),
            fake.date_between(start_date="-4y", end_date="today"),
            random.choice(dept_ids),
            random.randint(1, 4),
            round(random.uniform(1.5, 4.0), 2),
            random.choices(
                ["active", "graduated", "withdrawn", "suspended"],
                weights=[70, 20, 7, 3]
            )[0],
        ))
    execute_values(cur, """
        INSERT INTO students
            (first_name, last_name, email, date_of_birth, enrollment_date,
             department_id, year_level, gpa, status)
        VALUES %s RETURNING student_id
    """, rows)
    return [r[0] for r in cur.fetchall()]


def seed_courses(cur, dept_ids, inst_ids):
    rows = []
    for i in range(N_COURSES):
        di = random.randrange(len(DEPARTMENTS))
        code = f"{DEPARTMENTS[di][1]}{random.randint(100,499):03d}-{i}"
        rows.append((
            code,
            fake.catch_phrase()[:100],
            dept_ids[di],
            random.randint(1, 4),
            random.choice(inst_ids),
            random.randint(20, 60),
            fake.text(max_nb_chars=200),
            random.choice(["Spring", "Summer", "Fall"]),
            random.randint(2021, 2025),
        ))
    execute_values(cur, """
        INSERT INTO courses
            (course_code, course_name, department_id, credits, instructor_id,
             max_students, description, semester, academic_year)
        VALUES %s RETURNING course_id
    """, rows)
    return [r[0] for r in cur.fetchall()]


def seed_enrollments(cur, conn, student_ids, course_ids):
    seen = set()
    rows = []
    for sid in student_ids:
        n = max(1, round(random.gauss(AVG_ENROLL, 2)))
        for cid in random.sample(course_ids, min(n, len(course_ids))):
            if (sid, cid) in seen:
                continue
            seen.add((sid, cid))
            score = round(random.betavariate(5, 2) * 100, 2)
            rows.append((
                sid, cid,
                fake.date_time_between(start_date="-2y", end_date="now"),
                score_to_grade(score),
                score,
                random.choices(
                    ["enrolled", "completed", "dropped", "failed"],
                    weights=[30, 50, 15, 5]
                )[0],
            ))

    ids = []
    for i in range(0, len(rows), BATCH):
        execute_values(cur, """
            INSERT INTO enrollments
                (student_id, course_id, enrolled_at, final_grade, final_score, status)
            VALUES %s RETURNING enrollment_id
        """, rows[i:i+BATCH])
        ids.extend(r[0] for r in cur.fetchall())
    conn.commit()
    return ids


def seed_assignments(cur, conn, course_ids):
    rows = []
    for cid in course_ids:
        n = max(2, round(random.gauss(AVG_ASSIGN, 2)))
        for j in range(n):
            atype = random.choice(ASSIGNMENT_TYPES)
            max_score = 100 if atype in ("midterm", "final") else random.choice([10, 20, 25, 50, 100])
            rows.append((
                cid,
                f"{atype.title()} {j+1} — {fake.bs()[:50]}",
                fake.text(max_nb_chars=300),
                atype,
                fake.date_time_between(start_date="-1y", end_date="+3m"),
                max_score,
                round(random.uniform(5, 30), 2),
            ))

    ids = []
    for i in range(0, len(rows), BATCH):
        execute_values(cur, """
            INSERT INTO assignments
                (course_id, title, description, type, due_date, max_score, weight)
            VALUES %s RETURNING assignment_id
        """, rows[i:i+BATCH])
        ids.extend(r[0] for r in cur.fetchall())
    conn.commit()
    return ids


def seed_submissions(cur, conn, enroll_ids):
    cur.execute("SELECT assignment_id, course_id, max_score FROM assignments")
    assign_info = {r[0]: (r[1], float(r[2])) for r in cur.fetchall()}

    cur.execute("SELECT enrollment_id, course_id FROM enrollments")
    enroll_course = {r[0]: r[1] for r in cur.fetchall()}

    course_assigns: dict[int, list] = {}
    for aid, (cid, ms) in assign_info.items():
        course_assigns.setdefault(cid, []).append((aid, ms))

    seen = set()
    batch = []
    total = 0

    for eid in enroll_ids:
        if total >= TARGET_SUBS:
            break
        cid = enroll_course.get(eid)
        assigns = course_assigns.get(cid, [])
        if not assigns:
            continue

        n_submit = max(1, round(random.gauss(len(assigns) * 0.85, 1)))
        for aid, ms in random.sample(assigns, min(n_submit, len(assigns))):
            if total >= TARGET_SUBS:
                break
            key = (eid, aid)
            if key in seen:
                continue
            seen.add(key)

            score = round(random.betavariate(5, 2) * ms, 2)
            batch.append((
                eid, aid,
                fake.date_time_between(start_date="-1y", end_date="now"),
                score, ms,
                fake.sentence() if random.random() < 0.3 else None,
                random.random() < 0.1,
                1,
            ))
            total += 1

            if len(batch) >= BATCH:
                execute_values(cur, """
                    INSERT INTO submissions
                        (enrollment_id, assignment_id, submitted_at, score,
                         max_score_snapshot, feedback, is_late, attempt_number)
                    VALUES %s ON CONFLICT DO NOTHING
                """, batch)
                conn.commit()
                print(f"  {total:>7,} / {TARGET_SUBS:,} submissions", end="\r")
                batch = []

    if batch:
        execute_values(cur, """
            INSERT INTO submissions
                (enrollment_id, assignment_id, submitted_at, score,
                 max_score_snapshot, feedback, is_late, attempt_number)
            VALUES %s ON CONFLICT DO NOTHING
        """, batch)
        conn.commit()

    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host",     default="localhost")
    parser.add_argument("--port",     type=int, default=5432)
    parser.add_argument("--db",       default="coursedb")
    parser.add_argument("--user",     default="courseuser")
    parser.add_argument("--password", default="coursepass123")
    args = parser.parse_args()

    t0 = time.time()
    print(f"Connecting to {args.host}:{args.port}/{args.db} ...")
    conn = connect(args)
    cur = conn.cursor()

    print("Truncating existing data ...")
    truncate_all(cur)
    conn.commit()

    steps = [
        ("departments",  lambda: seed_departments(cur)),
        ("instructors",  lambda: seed_instructors(cur, dept_ids)),
        ("students",     lambda: seed_students(cur, dept_ids)),
        ("courses",      lambda: seed_courses(cur, dept_ids, inst_ids)),
    ]

    print("Seeding departments ...")
    dept_ids = seed_departments(cur); conn.commit()
    print(f"  {len(dept_ids)} departments")

    print("Seeding instructors ...")
    inst_ids = seed_instructors(cur, dept_ids); conn.commit()
    print(f"  {len(inst_ids)} instructors")

    print("Seeding students ...")
    student_ids = seed_students(cur, dept_ids); conn.commit()
    print(f"  {len(student_ids)} students")

    print("Seeding courses ...")
    course_ids = seed_courses(cur, dept_ids, inst_ids); conn.commit()
    print(f"  {len(course_ids)} courses")

    print("Seeding enrollments ...")
    enroll_ids = seed_enrollments(cur, conn, student_ids, course_ids)
    print(f"  {len(enroll_ids):,} enrollments")

    print("Seeding assignments ...")
    assign_ids = seed_assignments(cur, conn, course_ids)
    print(f"  {len(assign_ids):,} assignments")

    print(f"Seeding submissions (target {TARGET_SUBS:,}) ...")
    total = seed_submissions(cur, conn, enroll_ids)
    print(f"\n  {total:,} submissions inserted")

    # Row counts
    cur.execute("""
        SELECT relname, n_live_tup
        FROM pg_stat_user_tables
        ORDER BY n_live_tup DESC
    """)
    print("\nRow counts (from pg_stat):")
    for row in cur.fetchall():
        print(f"  {row[0]:<25} {row[1]:>10,}")

    cur.close()
    conn.close()
    print(f"\nDone in {time.time()-t0:.1f}s")


if __name__ == "__main__":
    main()
