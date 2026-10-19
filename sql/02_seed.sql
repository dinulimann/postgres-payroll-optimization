-- Synthetic data. All names and numbers are generated; nothing comes from a
-- real company.
--
-- Usage: psql -v n_employees=5000 -f 02_seed.sql
-- Period being processed: September 2026.

\if :{?n_employees}
\else
  \set n_employees 5000
\endif

SET search_path TO payroll;
SELECT setseed(0.42);

INSERT INTO params (key, value) VALUES
    ('bpjs_health_rate',  0.01),
    ('bpjs_health_cap',   12000000),
    ('pension_rate',      0.02),
    ('min_take_home',     50000);

-- 20 grades, base salary 3.0M .. 12.5M
INSERT INTO grades (id, code, base_salary)
SELECT g, 'G' || lpad(g::text, 2, '0'), 3000000 + (g - 1) * 500000
FROM generate_series(1, 20) g;

-- 18 job classes
INSERT INTO job_classes (job_class, fixed_allowance, incentive)
SELECT c, 750000 + c * 250000, 500000 + c * 300000
FROM generate_series(1, 18) c;

-- 400 positions spread over the job classes
INSERT INTO positions (id, code, job_class)
SELECT p, 'POS-' || lpad(p::text, 4, '0'), 1 + (p % 18)
FROM generate_series(1, 400) p;

INSERT INTO employees (id, emp_no, full_name, location_type, hire_date, end_date)
SELECT e,
       'EMP' || lpad(e::text, 6, '0'),
       'Employee ' || e,
       CASE WHEN random() < 0.3 THEN 'HQ' ELSE 'BRANCH' END,
       date '2005-01-01' + (random() * 7500)::int,
       NULL
FROM generate_series(1, :n_employees) e;

-- About 2% leave the company in the middle of the period
UPDATE employees
SET end_date = date '2026-09-01' + (random() * 28)::int
WHERE random() < 0.02;

-- About 2% join in the middle of the period
UPDATE employees
SET hire_date = date '2026-09-02' + (random() * 27)::int
WHERE end_date IS NULL AND random() < 0.02;

-- Assignment history: one current assignment, and for ~20% of staff a
-- mutation (new grade and/or position) in the middle of September.
WITH base AS (
    SELECT e.id AS employee_id,
           e.hire_date,
           1 + (random() * 19)::int  AS grade_id,
           1 + (random() * 399)::int AS position_id,
           random() < 0.20           AS has_mutation,
           date '2026-09-05' + (random() * 20)::int AS mutation_date
    FROM employees e
), rows AS (
    SELECT employee_id, hire_date AS start_date,
           CASE WHEN has_mutation AND mutation_date > hire_date THEN mutation_date - 1 END AS end_date,
           grade_id, position_id
    FROM base
    UNION ALL
    SELECT employee_id, mutation_date, NULL,
           LEAST(grade_id + 1, 20),
           1 + ((position_id + 37) % 400)
    FROM base
    WHERE has_mutation AND mutation_date > hire_date
)
INSERT INTO assignments (id, employee_id, start_date, end_date, grade_id, position_id)
SELECT row_number() OVER (ORDER BY employee_id, start_date), *
FROM rows;

-- Daily attendance for the whole month (only days the person was employed)
INSERT INTO attendance (employee_id, work_date, status)
SELECT e.id, d::date,
       CASE WHEN r < 0.03 THEN 'A' WHEN r < 0.10 THEN 'L' ELSE 'P' END
FROM employees e
CROSS JOIN generate_series(date '2026-09-01', date '2026-09-30', interval '1 day') d
CROSS JOIN LATERAL (SELECT random() AS r) x
WHERE d::date >= e.hire_date
  AND (e.end_date IS NULL OR d::date <= e.end_date);

-- 60% are cooperative members
INSERT INTO coop_members (employee_id, mandatory, voluntary)
SELECT id, 100000, (random() * 10)::int * 50000
FROM employees
WHERE random() < 0.6;

-- 25% have an active loan; a few have an old, inactive one too
INSERT INTO loans (id, employee_id, monthly_installment, active)
SELECT row_number() OVER (), employee_id, installment, active
FROM (
    SELECT id AS employee_id, (1 + (random() * 40)::int) * 100000 AS installment, true AS active
    FROM employees WHERE random() < 0.25
    UNION ALL
    SELECT id, 250000, false
    FROM employees WHERE random() < 0.10
) l;

ANALYZE;
